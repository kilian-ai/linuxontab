/* forkthreads.c — fork+exec while other threads are running (what Node's
 * child_process does from a process full of V8/libuv threads). */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static atomic_int stop;
static atomic_long spins;
static void *spin(void *a) {
  (void)a;
  while (!atomic_load(&stop)) { atomic_fetch_add(&spins, 1); usleep(1000); }
  return 0;
}

int main(void) {
  pthread_t t[3];
  for (int i = 0; i < 3; i++) pthread_create(&t[i], 0, spin, 0);
  int ok = 1;
  for (int round = 0; round < 3; round++) {
    int fds[2]; pipe(fds);
    pid_t pid = fork();
    if (pid == 0) {
      dup2(fds[1], 1); close(fds[0]); close(fds[1]);
      execl("/bin/echo", "echo", "child-says-hi", (char *)0);   /* a WASM binary */
      _exit(127);
    }
    close(fds[1]);
    char buf[64] = {0}; ssize_t n = read(fds[0], buf, sizeof buf - 1); close(fds[0]);
    int st; waitpid(pid, &st, 0);
    printf("round %d: child %d said '%.*s' exit=%d\n", round, pid, (int)(n > 0 ? n - 1 : 0), buf, WEXITSTATUS(st));
    if (n <= 0 || WEXITSTATUS(st)) ok = 0;
  }
  atomic_store(&stop, 1);
  for (int i = 0; i < 3; i++) pthread_join(t[i], 0);
  printf("spinner iterations while forking: %ld\n%s\n", (long)spins, ok && spins > 0 ? "FORK+THREADS OK" : "FORK+THREADS FAIL");
  return !ok;
}
