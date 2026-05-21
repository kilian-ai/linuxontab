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
 *      state=Rewinding(2): calls asyncify_stop_rewind(), returns m32[retPtr>>2]=0.
 *      Child's fork() returns 0.
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

/* syscall() is in <unistd.h> but guarded by #ifndef __wasm__ in the musl sysroot.
 * Declare it directly so we can call the WASM linux.syscall import. */
extern long syscall(long nr, ...);

/* pid_t fork(void) and pid_t vfork(void) are also guarded by #ifndef __wasm__
 * in the musl sysroot.  Our definitions here are the only declarations needed. */

#define SYS_WASM_FORK   9999L
#define SYS_WASM_VFORK  10000L

/* 128 KB asyncify stack buffer, 8-byte aligned, per-thread */
#define FORK_BUF_SIZE   (128 * 1024)

static _Thread_local uint8_t  __fork_buf[FORK_BUF_SIZE] __attribute__((aligned(8)));

/*
 * Fork return value slot.  JS writes the child PID (parent side) or 0
 * (child side) here before asyncify_start_rewind.  We read it after
 * asyncify_stop_rewind (triggered inside the JS syscall handler on
 * state=Rewinding).
 */
static _Thread_local int32_t  __fork_return_val;

/*
 * Declare the raw WASM syscall — musl provides this via its own syscall()
 * wrapper but we want to guarantee the call reaches the WASM import.
 */
extern long syscall(long nr, ...);

static pid_t __wasm_fork_impl(long syscall_nr)
{
	int32_t *h = (int32_t *)__fork_buf;

	/*
	 * Asyncify buffer header (two i32 words at offset 0 and 4):
	 *   h[0] = data cursor — initial: first byte after header (bufPtr+8)
	 *   h[1] = data end   — initial: last byte of buffer
	 * After unwind, JS leaves h[0] at writtenEnd; we must NOT reset it
	 * before rewind.
	 */
	h[0] = (int32_t)(uintptr_t)(__fork_buf + 8);
	h[1] = (int32_t)(uintptr_t)(__fork_buf + FORK_BUF_SIZE);

	/*
	 * JS intercepts this syscall:
	 *  state=Normal(0):   start_unwind(bufPtr), return 0 — stack unwinds
	 *  state=Rewinding(2): stop_rewind(), return __fork_return_val
	 *
	 * The actual return value is read from __fork_return_val, NOT from
	 * the syscall() return value (which is 0 for both phases).
	 */
	syscall(syscall_nr,
		(long)(uintptr_t)__fork_buf,
		(long)(uintptr_t)&__fork_return_val,
		0L, 0L, 0L, 0L);

	return (pid_t)__fork_return_val;
}

pid_t fork(void)
{
	return __wasm_fork_impl(SYS_WASM_FORK);
}

pid_t vfork(void)
{
	return __wasm_fork_impl(SYS_WASM_VFORK);
}
