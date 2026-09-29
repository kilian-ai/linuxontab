/* wasm-native TLS check: does each guest thread get its own _Thread_local? */
#include <pthread.h>
#include <stdio.h>
static _Thread_local long v = -1;
static pthread_barrier_t bar;
static void *f(void *a) { v = (long)a; pthread_barrier_wait(&bar); return (void *)(long)(v != (long)a); }
int main(void) {
  pthread_t t[4]; long bad = 0; void *r;
  pthread_barrier_init(&bar, 0, 4);
  for (long i = 0; i < 4; i++) pthread_create(&t[i], 0, f, (void *)i);
  for (int i = 0; i < 4; i++) { pthread_join(t[i], &r); bad += (long)r; }
  printf("wasm TLS: %ld of 4 threads saw another thread's value, &v=%p\n", bad, (void *)&v);
  return 0;
}
