/* wasm_clone.c — fix the wasm32-musl __clone so every pthread gets its own
 * stack and its own TLS block.
 *
 * STACK. The tombl/musl wasm32 port (src/thread/wasm32/clone.c) builds a
 * `clone_entry` trampoline whose whole job is to `global.set __stack_pointer`
 * to the new thread's stack — then passes the ORIGINAL func/arg to SYS_clone,
 * so the trampoline is never called: every thread runs on the parent's shadow
 * stack (each thread worker's wasm instance boots with the module's default
 * __stack_pointer). Two threads parked in pthread_cond_wait then place their
 * on-stack `struct waiter` nodes ~32 bytes apart on the SAME stack and corrupt
 * musl's condvar waiter list — the "cond ping-pong wedges at round 2" hang that
 * took out CPython threading and the ffmpeg 7 CLI on this kernel.
 * Verified with local/sched-debug/condpp.c (0/10 -> 10/10, 5/5 runs).
 *
 * TLS. Every wasm thread is a new instance of the module and nothing calls
 * wasm-ld's __wasm_init_tls for it, so __tls_base stays at the static TLS
 * image in the data section: ALL threads shared one set of _Thread_local
 * variables (spikes/x86-blink/tlsprobe.c: 3 of 4 threads read another
 * thread's value, &v identical in every thread). For CLONE_SETTLS clones
 * (pthread_create) the child now gets its own block, initialised by
 * __wasm_init_tls before any user code runs.
 *
 * Where it lives: a block of up to LOT_TLS_ON_STACK_MAX bytes is carved from
 * the top of the new thread's stack, so musl frees it with the stack when the
 * thread is reaped. A larger one is aligned_alloc'd and never freed (musl
 * gives no thread-exit hook here). The trampoline's own argument block goes
 * on the child stack too, so the common path does not allocate at all.
 *
 * CLONE_VFORK children with their own stack (musl posix_spawn, Blink's guest
 * vfork) also get a fresh block, aligned_alloc'd: a vfork child can run a lot
 * of code — Blink runs a whole emulator — while the parent's OTHER threads
 * keep going, and its _Thread_local writes must not land in the suspended
 * parent thread's block. It is never carved from the child stack (posix_spawn
 * passes a ~5 KB buffer in the parent's frame), and the parent frees it when
 * __clone returns: by then the child has exec'd or exited. Other clones
 * without CLONE_SETTLS keep the instance's TLS.
 *
 * This reimplements __clone and, linked before -lc, overrides the libc.a copy
 * (its clone.o member is then never pulled). Self-contained: the only
 * externals are the port's raw syscall import, malloc/aligned_alloc and the
 * linker-synthesized __wasm_init_tls (every guest binary links with
 * --shared-memory, which is what makes wasm-ld emit it). SYS_clone=220.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>

#define LOT_SYS_clone      220
#define LOT_CLONE_VFORK    0x00004000
#define LOT_CLONE_SETTLS   0x00080000
#define LOT_TLS_ON_STACK_MAX 4096

__attribute__((import_module("linux"), import_name("syscall")))
long __wasm_syscall(long n, long a, long b, long c, long d, long e, long f);

/* copies the .tdata/.tbss image into the block and points __tls_base at it */
extern void __wasm_init_tls(void *block);

__asm__(".globaltype __stack_pointer, i32\n");
static inline void set_stack_pointer(void *ptr)
{
    __asm__ volatile("local.get %0\n"
                     "global.set __stack_pointer" ::"r"(ptr));
}

/* Marker export: binaries linked with this __clone set the child's stack
 * pointer, so the worker may run a CLONE_VM|CLONE_VFORK clone as a real
 * shared-memory vfork instead of turning it into a memory copy (which it must
 * do for the old libc __clone, whose child runs on the parent's stack). */
__attribute__((export_name("__lot_clone_sets_sp"))) void __lot_clone_sets_sp(void) {}

struct lot_clone_arg {
    void *stack;              /* child __stack_pointer, 0 = leave as is */
    int (*func)(void *);
    void *arg;
    void *tls;                /* child TLS block, 0 = keep the instance's */
    int on_heap;              /* this struct was malloc'd (no stack given) */
};

__attribute__((__noinline__))
static int clone_entry_inner(struct lot_clone_arg *a)
{
    void *user_arg = a->arg;
    int (*user_func)(void *) = a->func;
    if (a->on_heap) free(a);
    user_func(user_arg);
    return 0;
}

static int clone_entry(void *arg_)
{
    struct lot_clone_arg *a = arg_;
    if (a->stack) set_stack_pointer(a->stack);
    if (a->tls) __wasm_init_tls(a->tls);
    return clone_entry_inner(a);
}

int __clone(int (*func)(void *), void *stack, int flags, void *arg, ...)
{
    va_list ap;
    va_start(ap, arg);
    void *parent_tid = va_arg(ap, void *);
    void *tls        = va_arg(ap, void *);
    void *child_tid  = va_arg(ap, void *);
    va_end(ap);

    uintptr_t top = (uintptr_t)stack;
    void *block = 0, *heap_block = 0;
    int settls = flags & LOT_CLONE_SETTLS;
    int vfork_tls = !settls && (flags & LOT_CLONE_VFORK) && stack;
    if ((settls || vfork_tls) && __builtin_wasm_tls_size()) {
        size_t al = __builtin_wasm_tls_align(), sz = __builtin_wasm_tls_size();
        if (al < 16) al = 16;
        sz = (sz + al - 1) & ~(al - 1);
        if (settls && stack && sz <= LOT_TLS_ON_STACK_MAX) {
            top = (top - sz) & ~(uintptr_t)(al - 1);
            block = (void *)top;
        } else if (!(block = heap_block = aligned_alloc(al, sz))) {
            return -12; /* ENOMEM */
        }
    }

    struct lot_clone_arg *a;
    if (stack) {
        top = (top - sizeof *a) & ~(uintptr_t)15;
        a = (struct lot_clone_arg *)top;
        a->stack = a;         /* the child's frames start just below it */
        a->on_heap = 0;
    } else {
        a = malloc(sizeof *a);
        if (!a) { free(heap_block); return -12; /* ENOMEM */ }
        a->stack = 0;
        a->on_heap = 1;
    }
    a->func = func;
    a->arg = arg;
    a->tls = block;

    long ret = __wasm_syscall(LOT_SYS_clone, (long)clone_entry, (long)a, flags,
                              (long)parent_tid, (long)child_tid, (long)tls);
    if (ret < 0) {            /* no child: nobody else will free these */
        free(heap_block);
        if (a->on_heap) free(a);
    } else if (vfork_tls) {   /* the vfork child has exec'd or exited */
        free(heap_block);
    }
    return ret;
}
