/* threads.c — x86-64 pthread stress for Blink-in-wasm.
 * 1) N threads bump a shared atomic and a mutex-guarded counter
 * 2) two threads ping-pong through a condvar ROUNDS times
 * 3) thread-local storage stays per-thread
 * 4) a sleeping thread and a joining main thread */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define N 4
#define ITERS 20000
static atomic_long acount;
static long mcount;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static __thread long tls = -1;
static pthread_barrier_t bar;

static void *bump(void *arg) {
  long id = (long)arg;
  tls = id;
  pthread_barrier_wait(&bar);   /* every thread holds its TLS value at once */
  for (int i = 0; i < ITERS; i++) {
    atomic_fetch_add(&acount, 1);
    pthread_mutex_lock(&mu); mcount++; pthread_mutex_unlock(&mu);
  }
  return (void *)(tls == id ? 0L : 1L);
}

static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int turn, rounds;
static void *pong(void *arg) {
  long me = (long)arg;
  for (int i = 0; i < rounds; i++) {
    pthread_mutex_lock(&mu);
    while (turn != me) pthread_cond_wait(&cv, &mu);
    turn = !me;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
  }
  return 0;
}

static void *sleeper(void *arg) {
  (void)arg;
  struct timespec ts = {0, 200 * 1000 * 1000};
  nanosleep(&ts, 0);
  return (void *)42L;
}

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv) {
  rounds = argc > 1 ? atoi(argv[1]) : 1000;
  double t0 = now();
  pthread_t t[N];
  pthread_barrier_init(&bar, 0, N);
  for (long i = 0; i < N; i++) pthread_create(&t[i], 0, bump, (void *)i);
  long bad = 0; void *r;
  for (int i = 0; i < N; i++) { pthread_join(t[i], &r); bad += (long)r; }
  printf("counters: atomic=%ld mutex=%ld expect=%d tls_bad=%ld\n", (long)acount, mcount, N * ITERS, bad);
  double t1 = now();
  pthread_t a, b;
  pthread_create(&a, 0, pong, (void *)0L);
  pthread_create(&b, 0, pong, (void *)1L);
  pthread_join(a, 0); pthread_join(b, 0);
  double t2 = now();
  printf("condvar ping-pong: %d rounds ok\n", rounds);
  pthread_t s; pthread_create(&s, 0, sleeper, 0); pthread_join(s, &r);
  printf("sleeper returned %ld\n", (long)r);
  printf("times: counters %.3f s, pingpong %.3f s (%.0f us/handoff)\n", t1 - t0, t2 - t1, (t2 - t1) / (2.0 * rounds) * 1e6);
  int ok = acount == N * ITERS && mcount == N * ITERS && !bad && (long)r == 42;
  printf("%s\n", ok ? "THREADS OK" : "THREADS FAIL");
  return !ok;
}
