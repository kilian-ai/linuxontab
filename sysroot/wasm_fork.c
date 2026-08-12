/*
 * wasm_fork.c — asyncify-based fork() and vfork() for @tombl/linux WASM target
 *
 * How it works:
 *   1. Calls a JS-intercepted sentinel syscall (SYS_WASM_FORK=9999 or
 *      SYS_WASM_VFORK=10000) with an asyncify buffer and return-value slot.
 *   2. JS handler sees state=Normal: calls asyncify_start_unwind(bufPtr).
 *      The WASM stack unwinds; this syscall appears to return 0.
 *   3. In user.call(), JS detects asyncify state=Unwinding (1):
 *      a. Copies user memory into a new SharedArrayBuffer (fork) or
 *         shares it (vfork — approximate, parent resumes immediately).
 *      b. Calls kernel's sys_clone(220, fn=0, fn_arg=0, SIGCHLD, ...)
 *         from JS to create a real child task_struct (proper fd/cred
 *         inheritance). The kernel calls spawn_worker with share_user_memory=1
 *         (always true for sys_clone in @tombl/linux). JS overrides
 *         get_user_memory() to return childMem during that spawn.
 *      c. Rewrites parent's retPtr = childPid, calls asyncify_start_rewind.
 *   4. Child worker: switch_entry is called with fn=0 by wasm_call_clone_fn.
 *      JS switch_entry sees forkRewindState != null (from message) and
 *      sets up a one-shot call_entry that writes retPtr=0 and calls
 *      asyncify_start_rewind(bufPtr), then call_start() → _start().
 *   5. On the next call_entry() call in the child's call() loop:
 *      asyncify rewinds back to this syscall return → JS handler sees
 *      state=Rewinding(2): calls asyncify_stop_rewind(), returns *retPtr.
 *      Child's fork() returns 0.
 *
 * THUNK BUFFER — DYNAMIC ALLOCATION (see [[wasm-kernel-async-fixes]]):
 *   Earlier this used a fixed 128 KB _Thread_local buffer, which the JS handler
 *   then OVERRODE with a fixed 4 MB region at memory.byteLength-4MB. That was
 *   simultaneously collision-prone (the heap grows into that region),
 *   non-reentrant (one address for every, incl. nested, fork), and both
 *   wasteful (4 MB for a shallow fork+exec) and unsafe (a hard ceiling a deep
 *   $() nest could silently overrun — asyncify does not bounds-check).
 *
 *   Now fork() malloc()s its own thunk per call, sized from the LIVE stack depth
 *   (asyncify frame data scales with call depth; the shadow-stack span is a good
 *   proxy). It tags the syscall with WASM_FORK_MAGIC in arg2 so the JS handler
 *   uses THIS buffer verbatim instead of the fixed override. The buffer is
 *   ordinary heap memory, so it (a) can't collide with the heap — it's IN the
 *   heap, (b) is unique per (nested) call → reentrant, (c) is copied into the
 *   child for free, (d) is right-sized. Binaries built before this change (no
 *   magic tag) still get the legacy 4 MB JS override, so the handler is
 *   backward-compatible across a staged rebuild.
 *
 * LIMITATION: requires the user binary to be transformed with:
 *   wasm-opt --asyncify -O1 input.wasm -o input.wasm
 * Binaries without asyncify exports (asyncify_get_state, asyncify_start_unwind,
 * asyncify_start_rewind, asyncify_stop_rewind, asyncify_stop_unwind) will
 * receive ENOSYS from fork()/vfork().
 *
 * Link this file BEFORE musl to override musl's fork()/vfork():
 *   clang ... wasm_fork.c musl_libs ...  -o output.wasm
 */

#include <sys/types.h>
#include <stdint.h>
#include <stdlib.h>
#include <errno.h>

/* syscall() is in <unistd.h> but guarded by #ifndef __wasm__ in the musl sysroot.
 * Declare it directly so we can call the WASM linux.syscall import. */
extern long syscall(long nr, ...);

/* pid_t fork(void) and pid_t vfork(void) are also guarded by #ifndef __wasm__
 * in the musl sysroot.  Our definitions here are the only declarations needed. */

#define SYS_WASM_FORK    9999L
#define SYS_WASM_VFORK   10000L
/* arg2 sentinel: tells the JS handler "arg0 is a caller-provided, correctly
 * sized asyncify buffer of arg3 bytes with its header already written — use it
 * directly, do NOT override with the fixed top-of-memory region." */
#define WASM_FORK_MAGIC  0x464f524bL   /* 'FORK' */

/* Read the wasm shadow-stack pointer (the __stack_pointer global). */
static inline uintptr_t __wasm_sp(void)
{
	uintptr_t p;
	__asm__ volatile("global.get __stack_pointer\n local.set %0" : "=r"(p));
	return p;
}

/* Captured near the stack top at process start so we can measure how much stack
 * a given fork() call is using. A constructor runs inside __wasm_call_ctors
 * during _start — a few frames below the true top, which only makes the size
 * estimate slightly conservative-low; the slack below covers it. */
static uintptr_t __wasm_stack_top_at_start;
__attribute__((constructor)) static void __wasm_capture_stack_top(void)
{
	__wasm_stack_top_at_start = __wasm_sp();
}

static pid_t __wasm_fork_impl(long syscall_nr)
{
	/* Size the asyncify thunk from the LIVE stack depth: scale off the
	 * shadow-stack span used so far (3x) with 64 KB slack, floored at 128 KB
	 * for a shallow fork+exec. This right-sizes shallow forks and grows for a
	 * deep $() nest, rather than betting a single fixed size is both enough
	 * and not wasteful. */
	uintptr_t sp   = __wasm_sp();
	uintptr_t used = (__wasm_stack_top_at_start > sp)
			 ? (__wasm_stack_top_at_start - sp) : 0;
	size_t    sz   = (size_t)used * 3 + (64u << 10);
	if (sz < (128u << 10))
		sz = 128u << 10;

	uint8_t *buf = (uint8_t *)malloc(sz);
	if (!buf) {
		errno = ENOMEM;
		return -1;
	}

	/* Return slot is a stack local: naturally reentrant, and its shadow-stack
	 * slot survives the unwind/rewind (asyncify saves wasm locals, not shadow
	 * memory; nothing touches this region between unwind and rewind). JS writes
	 * the child PID (parent side) or 0 (child side) here before start_rewind. */
	volatile int32_t retval = -1;

	/*
	 * Asyncify buffer header (two i32 words at offset 0 and 4):
	 *   h[0] = data cursor — initial: first byte after header (buf+8)
	 *   h[1] = data end   — initial: last byte of buffer
	 * After unwind, JS leaves h[0] at writtenEnd; we must NOT reset it
	 * before rewind (each fork() call has its own fresh buffer anyway).
	 */
	int32_t *h = (int32_t *)buf;
	h[0] = (int32_t)(uintptr_t)(buf + 8);
	h[1] = (int32_t)(uintptr_t)(buf + sz);

	/*
	 * JS intercepts this syscall:
	 *  state=Normal(0):   arg2==MAGIC → use buf; start_unwind(buf), return 0
	 *  state=Rewinding(2): stop_rewind(), return *retPtr
	 *
	 * The actual return value is read from retval, NOT from the syscall()
	 * return value (which is 0 for both phases).
	 */
	syscall(syscall_nr,
		(long)(uintptr_t)buf,
		(long)(uintptr_t)&retval,
		WASM_FORK_MAGIC,
		(long)sz,
		0L, 0L);

	int32_t r = retval;
	free(buf);
	if (r < 0) {
		errno = -r;
		return -1;
	}
	return (pid_t)r;
}

pid_t fork(void)
{
	return __wasm_fork_impl(SYS_WASM_FORK);
}

pid_t vfork(void)
{
	return __wasm_fork_impl(SYS_WASM_VFORK);
}
