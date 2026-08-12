/* futexpp.c — minimal raw-futex ping-pong to reproduce the lost-wake / CPU-token
 * wedge on the wasm kernel, with NO CPython/GIL noise. Uses pthread for a
 * properly-TLS'd worker thread, raw FUTEX_WAIT/WAKE for the ping-pong.
 *
 * Progress survives a console wedge via a per-step marker syscall:
 *   getpriority(PRIO_PROCESS, step) -> host trace shows nr=141 a0=0 a1=<step>.
 *   Legend: main round i -> mark(i)=pre-wake-work, mark(10+i)=wait-done,
 *   mark(20+i)=round-done. worker i -> mark(100+i)=pre-wait-work,
 *   mark(110+i)=got-work-signal-done. So a stall's exact point is visible.
 */
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <sys/syscall.h>
#define FUTEX_WAIT 0
#define FUTEX_WAKE 1
#define FUTEX_PRIVATE_FLAG 128

#define FWAIT (FUTEX_WAIT | FUTEX_PRIVATE_FLAG)
#define FWAKE (FUTEX_WAKE | FUTEX_PRIVATE_FLAG)

static volatile int work = 0;   /* main -> worker */
static volatile int done = 0;   /* worker -> main */

static long futex(volatile int *u, int op, int val) {
    return syscall(SYS_futex, (int *)u, op, val, 0, 0, 0);
}
static void mark(int step) { syscall(SYS_getpriority, 0, step); }
static void emit(const char *s) { write(2, s, strlen(s)); }

static void *worker_fn(void *arg) {
    (void)arg;
    for (int i = 0; i < 5; i++) {
        mark(100 + i);
        while (__atomic_load_n(&work, __ATOMIC_SEQ_CST) == 0)
            futex(&work, FWAIT, 0);
        __atomic_store_n(&work, 0, __ATOMIC_SEQ_CST);
        mark(110 + i);
        __atomic_store_n(&done, 1, __ATOMIC_SEQ_CST);
        futex(&done, FWAKE, 1);
    }
    emit("WORKER_DONE\n");
    return 0;
}

int main(void) {
    emit("REPRO_START\n");
    pthread_t t;
    if (pthread_create(&t, 0, worker_fn, 0) != 0) { emit("CREATE_FAIL\n"); return 1; }
    emit("WORKER_SPAWNED\n");
    for (int i = 0; i < 5; i++) {
        struct timespec ts = { 0, 200 * 1000 * 1000 };
        nanosleep(&ts, 0);
        mark(i);
        __atomic_store_n(&work, 1, __ATOMIC_SEQ_CST);
        futex(&work, FWAKE, 1);
        mark(10 + i);
        while (__atomic_load_n(&done, __ATOMIC_SEQ_CST) == 0)
            futex(&done, FWAIT, 0);
        __atomic_store_n(&done, 0, __ATOMIC_SEQ_CST);
        char b[8]; int n=0; b[n++]='R';b[n++]='O';b[n++]='K';b[n++]=' ';b[n++]='0'+i;b[n++]='\n';
        write(2, b, n);
        mark(20 + i);
    }
    pthread_join(t, 0);
    emit("MAIN_DONE_ALL\n");
    return 0;
}
