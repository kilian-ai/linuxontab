/* tlsprobe — does each wasm thread get its own _Thread_local block?
 * Expect "0 of 4". Each thread must also start from a fresh copy of the TLS
 * image (.tdata values, .tbss zeros), and see its own address for v.
 * Build with -DBIG to add an 8 KB TLS array, which takes wasm_clone.c's
 * heap-allocated path instead of the on-stack one; -DSTACK=<bytes> sets the
 * thread stack size (python3's sitecustomize uses 16 MB). */
#include <pthread.h>
#include <stdio.h>
#include <string.h>
static _Thread_local long v = -1;          /* .tdata */
static _Thread_local long z;               /* .tbss */
#ifdef BIG
static _Thread_local char big[8192];
#endif
static pthread_barrier_t bar;
static void *addr[4];
static void *f(void *a) {
  long i = (long)a, bad = 0;
  if (v != -1 || z != 0) bad |= 1;         /* not a fresh image */
#ifdef BIG
  for (int k = 0; k < (int)sizeof big; k++) if (big[k]) { bad |= 1; break; }
  memset(big, (int)i + 1, sizeof big);
#endif
  v = i; z = i * 10; addr[i] = (void *)&v;
  pthread_barrier_wait(&bar);
  if (v != i || z != i * 10) bad |= 2;     /* another thread's value */
#ifdef BIG
  for (int k = 0; k < (int)sizeof big; k++) if (big[k] != (char)(i + 1)) { bad |= 2; break; }
#endif
  return (void *)bad;
}
int main(void) {
  pthread_t t[4]; long fresh = 0, shared = 0, distinct = 0; void *r;
  v = 99; z = 99;                          /* main thread's copy is dirty */
  pthread_attr_t at, *atp = 0;
#ifdef STACK
  pthread_attr_init(&at); pthread_attr_setstacksize(&at, STACK); atp = &at;
#endif
  pthread_barrier_init(&bar, 0, 4);
  for (long i = 0; i < 4; i++)
    if (pthread_create(&t[i], atp, f, (void *)i)) { printf("pthread_create failed\n"); return 1; }
  for (int i = 0; i < 4; i++) {
    pthread_join(t[i], &r);
    fresh += ((long)r & 1) != 0; shared += ((long)r & 2) != 0;
  }
  for (int i = 0; i < 4; i++) {
    int dup = 0;
    for (int j = 0; j < i; j++) dup |= addr[i] == addr[j];
    distinct += !dup;
  }
  printf("wasm TLS: %ld of 4 threads saw another thread's value, %ld did not start "
         "from a fresh image, %ld distinct &v (main &v=%p, v=%ld)\n",
         shared, fresh, distinct, (void *)&v, v);
  return shared || fresh || distinct != 4 || v != 99;
}
