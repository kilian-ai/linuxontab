/* sigchld.c — does SIGCHLD reach a handler, the way libuv waits for it?
 * argv[1]: t = add a worker thread that blocks every signal (like V8/libuv
 * workers); e = parent waits in epoll_wait(-1) on the handler's pipe
 * (libuv's signal pipe) instead of pause() */
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/wait.h>
#include <unistd.h>

static int sp[2];
static volatile int got;
static void on_chld(int s) { (void)s; got++; write(sp[1], "c", 1); }
static void *blocker(void *a) {
  sigset_t all; sigfillset(&all); pthread_sigmask(SIG_BLOCK, &all, 0);
  for (;;) pause();
  return a;
}

int main(int argc, char **argv) {
  const char *m = argc > 1 ? argv[1] : "";
  pipe(sp);
  struct sigaction sa; memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_chld; sigaction(SIGCHLD, &sa, 0);
  if (strchr(m, 't')) { pthread_t t; pthread_create(&t, 0, blocker, 0); usleep(100000); }
  pid_t pid = fork();
  if (pid == 0) { execl("/bin/true", "true", (char *)0); _exit(3); }
  if (strchr(m, 'e')) {
    int ep = epoll_create1(0);
    struct epoll_event ev = {.events = EPOLLIN, .data.fd = sp[0]}, out;
    epoll_ctl(ep, EPOLL_CTL_ADD, sp[0], &ev);
    int n = epoll_wait(ep, &out, 1, 5000);
    printf("[%s] epoll_wait -> %d, handler ran %d times\n", m, n, got);
  } else {
    for (int i = 0; i < 50 && !got; i++) usleep(100000);
    printf("[%s] handler ran %d times\n", m, got);
  }
  int st; pid_t w = waitpid(pid, &st, 0);
  printf("[%s] waitpid -> %d (child %d) %s\n", m, w, pid, got ? "SIGCHLD OK" : "SIGCHLD MISSING");
  return !got;
}
