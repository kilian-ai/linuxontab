/* wasm_clone.c — fix the wasm32-musl __clone so every pthread gets its own stack.
 *
 * The tombl/musl wasm32 port (src/thread/wasm32/clone.c) builds a `clone_entry`
 * trampoline whose whole job is to `global.set __stack_pointer` to the new
 * thread's stack — then passes the ORIGINAL func/arg to SYS_clone, so the
 * trampoline is never called: every thread runs on the parent's shadow stack
 * (each thread worker's wasm instance boots with the module's default
 * __stack_pointer). Two threads parked in pthread_cond_wait then place their
 * on-stack `struct waiter` nodes ~32 bytes apart on the SAME stack and corrupt
 * musl's condvar waiter list — the "cond ping-pong wedges at round 2" hang that
 * took out CPython threading and the ffmpeg 7 CLI on this kernel.
 *
 * This reimplements __clone correctly and, linked before -lc, overrides the
 * libc.a copy (its clone.o member is then never pulled). Self-contained: the
 * only externals are the port's raw syscall import and malloc. SYS_clone=220.
 * Verified with local/sched-debug/condpp.c (0/10 -> 10/10, 5/5 runs).
 */
#include <stdarg.h>
#include <stdlib.h>

#define LOT_SYS_clone 220

__attribute__((import_module("linux"), import_name("syscall")))
long __wasm_syscall(long n, long a, long b, long c, long d, long e, long f);

__asm__(".globaltype __stack_pointer, i32\n");
static inline void set_stack_pointer(void *ptr)
{
    __asm__ volatile("local.get %0\n"
                     "global.set __stack_pointer" ::"r"(ptr));
}

struct lot_clone_arg { void *stack; int (*func)(void *); void *arg; };

__attribute__((__noinline__))
static int clone_entry_inner(struct lot_clone_arg *a)
{
    void *user_arg = a->arg;
    int (*user_func)(void *) = a->func;
    free(a);
    user_func(user_arg);
    return 0;
}

static int clone_entry(void *arg_)
{
    struct lot_clone_arg *a = arg_;
    set_stack_pointer(a->stack);
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

    struct lot_clone_arg *a = malloc(sizeof *a);
    if (!a) return -12; /* ENOMEM */
    a->stack = stack;
    a->func = func;
    a->arg = arg;

    return __wasm_syscall(LOT_SYS_clone, (long)clone_entry, (long)a, flags,
                          (long)parent_tid, (long)child_tid, (long)tls);
}
