/*
 * wasm-load-test — exercise the runtime's code-loading call (#14):
 * syscall(10001, ptr, len) compiles a wasm module from our own memory and
 * appends its exported functions to this thread's function table.
 *
 * The module below is hand-assembled and exports, in order:
 *   add(a, b)   = a + b
 *   peek(p)     = *(int *)p             (reads OUR memory: env.memory import)
 *   apply(f, x) = f(x)                  (calls back into OUR code through
 *                                        the shared table: call_indirect)
 * Build: tools/build-wasm-load-test.sh (needs --growable-table).
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>

#define NR_LOT_WASM_LOAD 10001

static const unsigned char mod[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    /* type: 0 = (i32,i32)->i32, 1 = (i32)->i32 */
    0x01, 0x0c, 0x02, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x01, 0x7f,
    /* import: env.memory (shared, min 0, max 65536), env.__indirect_function_table */
    0x02, 0x34, 0x02,
    0x03, 'e', 'n', 'v', 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x03, 0x00, 0x80, 0x80, 0x04,
    0x03, 'e', 'n', 'v', 0x19, '_', '_', 'i', 'n', 'd', 'i', 'r', 'e', 'c', 't', '_',
    'f', 'u', 'n', 'c', 't', 'i', 'o', 'n', '_', 't', 'a', 'b', 'l', 'e', 0x01, 0x70, 0x00, 0x00,
    /* function: add:0 peek:1 apply:0 */
    0x03, 0x04, 0x03, 0x00, 0x01, 0x00,
    /* export */
    0x07, 0x16, 0x03,
    0x03, 'a', 'd', 'd', 0x00, 0x00,
    0x04, 'p', 'e', 'e', 'k', 0x00, 0x01,
    0x05, 'a', 'p', 'p', 'l', 'y', 0x00, 0x02,
    /* code */
    0x0a, 0x1b, 0x03,
    0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,               /* a + b */
    0x07, 0x00, 0x20, 0x00, 0x28, 0x02, 0x00, 0x0b,               /* i32.load p */
    0x09, 0x00, 0x20, 0x01, 0x20, 0x00, 0x11, 0x01, 0x00, 0x0b,   /* call_indirect t1 */
};

typedef int (*fn2)(int, int);
typedef int (*fn1)(int);

static int twice(int x) { return 2 * x; }

static int fails, passes;
static void check(const char *what, long long got, long long want) {
    if (got == want) { passes++; printf("ok   %s = %lld\n", what, got); }
    else { fails++; printf("FAIL %s = %lld (want %lld)\n", what, got, want); }
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(void) {
    long base = syscall(NR_LOT_WASM_LOAD, mod, sizeof mod);
    if (base == -1 && errno == ENOSYS) {
        printf("runtime has no code loading (ENOSYS)\n");
        return 2;
    }
    if (base < 0) { printf("FAIL load: %ld errno %d\n", base, errno); return 1; }
    printf("loaded 3 functions at table slot %ld\n", base);

    fn2 add = (fn2)(uintptr_t)base;
    fn1 peek = (fn1)(uintptr_t)(base + 1);
    fn2 apply = (fn2)(uintptr_t)(base + 2);
    check("add(2, 40)", add(2, 40), 42);
    volatile int cell = 1234;
    check("peek(&cell)", peek((int)(uintptr_t)&cell), 1234);
    cell = -7;
    check("peek(&cell) after a store", peek((int)(uintptr_t)&cell), -7);
    check("apply(twice, 21)", apply((int)(uintptr_t)twice, 21), 42);

    long base2 = syscall(NR_LOT_WASM_LOAD, mod, sizeof mod);
    check("second load lands after the first", base2, base + 3);
    check("second add(1, 1)", ((fn2)(uintptr_t)base2)(1, 1), 2);

    unsigned char bad[sizeof mod];
    memcpy(bad, mod, sizeof mod);
    bad[1] = 0;                         /* \0asm -> \0\0sm */
    errno = 0;
    check("bad magic -> ENOEXEC", syscall(NR_LOT_WASM_LOAD, bad, sizeof bad) == -1 ? errno : 0, ENOEXEC);
    errno = 0;
    check("empty -> EINVAL", syscall(NR_LOT_WASM_LOAD, mod, 0) == -1 ? errno : 0, EINVAL);
    errno = 0;
    check("past memory end -> EFAULT", syscall(NR_LOT_WASM_LOAD, (void *)0x7ffffff0, 64) == -1 ? errno : 0, EFAULT);

    /* the call into loaded code is a plain call_indirect: no JS in between */
    volatile long long acc = 0;
    double t = now();
    for (int i = 0; i < 10000000; i++) acc += add(i, 1);
    double dt = now() - t;
    printf("10M calls into loaded code: %.0f ms (%.1f ns/call)\n", dt * 1e3, dt * 1e2);
    check("loop sum", acc, 50000005000000LL);

    printf("%d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
