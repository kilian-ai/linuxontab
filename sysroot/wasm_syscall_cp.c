/* wasm_syscall_cp.c — the pieces of musl's thread cancellation the wasm32
 * port leaves out.
 *
 * Linking pthread_cancel() (FOX's FXThread::cancel does) swaps musl's
 * __syscall_cp for a version that calls the per-arch assembly entry
 * __syscall_cp_asm and compares addresses against the __cp_begin /
 * __cp_end / __cp_cancel labels inside it; wasm32 musl has none of them, so
 * the link fails. This C version honours deferred cancellation at every
 * cancellation point (a pending cancel exits the thread before the syscall)
 * and does the syscall itself. Asynchronous cancellation of a thread blocked
 * inside the syscall is not supported: the labels exist only so that the
 * cancel signal handler's range check never matches. Link before -lc. */
#include <errno.h>
#include <pthread.h>
#include <unistd.h>

const char __cp_begin[1], __cp_end[1], __cp_cancel[1];

long __syscall_cp_asm(volatile int *cancel, long nr, long u, long v, long w, long x, long y, long z)
{
    if (*cancel) pthread_exit(PTHREAD_CANCELED);
    long r = syscall(nr, u, v, w, x, y, z);
    return r == -1 ? -errno : r;     /* musl's __syscall convention: -errno */
}
