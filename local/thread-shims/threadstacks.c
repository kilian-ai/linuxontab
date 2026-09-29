#define _GNU_SOURCE
/* threadstacks — pthread_create with DEFAULT attributes (musl's 128 KB stack,
 * allocated through __libc_malloc) under wasm_dlmalloc_mt, in rounds so the
 * stacks are freed again at join (the mallocng large-free path that trapped),
 * plus detached threads, malloc churn from every thread and per-thread TLS.
 * Expect "threadstacks: OK". */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define NT 6
#define ROUNDS 4
static _Thread_local unsigned id;
static int detached_done;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

__attribute__((noinline)) static unsigned use_stack(int n)
{
  volatile unsigned char buf[8192];        /* 8 x 8 KB = 64 KB of the 128 KB */
  for (int i = 0; i < (int)sizeof buf; i++) buf[i] = (unsigned char)(i ^ n);
  return n ? use_stack(n - 1) + buf[n] : buf[1];
}

static void *worker(void *a)
{
  id = (unsigned)(long)a;
  unsigned long bad = 0;
  for (int i = 0; i < 2000; i++) {
    size_t n = 16 + (size_t)((i * 7919u + id * 104729u) % 70000);
    unsigned char *p = malloc(n);
    if (!p) { bad++; break; }
    memset(p, (int)id, n);
    if (i % 3 == 0) p = realloc(p, n * 2);
    if (!p || p[n - 1] != (unsigned char)id) bad++;
    free(p);
  }
  use_stack(7);
  if (id != (unsigned)(long)a) bad++;      /* TLS still ours */
  return (void *)bad;
}

static void *detached(void *a)
{
  (void)a;
  use_stack(7);
  pthread_mutex_lock(&mu); detached_done++; pthread_mutex_unlock(&mu);
  return 0;
}

int main(void)
{
  unsigned long bad = 0; void *r;
  size_t stk = 0; pthread_attr_t at;
  pthread_getattr_default_np(&at); pthread_attr_getstacksize(&at, &stk);
  for (int round = 0; round < ROUNDS; round++) {
    pthread_t t[NT];
    for (long i = 0; i < NT; i++)
      if (pthread_create(&t[i], 0, worker, (void *)(i + 1 + round * NT))) { printf("create failed\n"); return 1; }
    for (int i = 0; i < NT; i++) { pthread_join(t[i], &r); bad += (unsigned long)r; }
    pthread_t d;
    if (pthread_create(&d, 0, detached, 0) || pthread_detach(d)) { printf("detached create failed\n"); return 1; }
  }
  for (int i = 0; i < 200; i++) {
    pthread_mutex_lock(&mu); int n = detached_done; pthread_mutex_unlock(&mu);
    if (n == ROUNDS) break;
    usleep(10000);
  }
  printf("threadstacks: default stack %zu, %d threads joined, %d detached done, %lu errors: %s\n",
         stk, NT * ROUNDS, detached_done, bad, bad || detached_done != ROUNDS ? "FAIL" : "OK");
  return bad != 0;
}
