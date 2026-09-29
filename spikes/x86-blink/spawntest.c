/* spawntest.c — what libuv's uv_spawn does, from a threaded x86 process:
 * 1) the vfork() probe: a write by the child before _exit() must be visible
 *    to the parent (proves CLONE_VM really shares memory)
 * 2) posix_spawn() with a dup2 file action into a pipe, for a WASM target
 *    and for an x86 target */
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static volatile int stop;
static void *idle(void *a) { (void)a; while (!stop) usleep(2000); return 0; }

static int spawn_capture(const char *path, char *const argv[], char *out, int n) {
  int fds[2]; pid_t pid; int st;
  posix_spawn_file_actions_t fa;
  pipe(fds);
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
  posix_spawn_file_actions_addclose(&fa, fds[0]);
  int rc = posix_spawn(&pid, path, &fa, 0, argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  close(fds[1]);
  if (rc) { close(fds[0]); snprintf(out, n, "posix_spawn error %d", rc); return -1; }
  int got = 0, r;
  while ((r = read(fds[0], out + got, n - 1 - got)) > 0) got += r;  /* drain: no SIGPIPE */
  close(fds[0]);
  out[got] = 0;
  char *nl = strchr(out, '\n');
  if (nl) *nl = 0;   /* compare the first line */
  waitpid(pid, &st, 0);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 128;
}

/* argv[1] picks the steps (default "tvwx"): t=threads v=vfork probe
 * w=posix_spawn a WASM program x=posix_spawn an x86 program */
int main(int argc, char **argv) {
  const char *steps = argc > 1 ? argv[1] : "tvwx";
  pthread_t t[2]; int ok = 1; char buf[256];
  int threads = !!strchr(steps, 't');
  if (threads) for (int i = 0; i < 2; i++) pthread_create(&t[i], 0, idle, 0);

  if (strchr(steps, 'v')) {
    volatile int shared = 0; int st;
    pid_t pid = vfork();
    if (pid == 0) { shared = 1; _exit(0); }
    waitpid(pid, &st, 0);
    printf("vfork probe: child write %s to parent (pid %d)\n", shared ? "VISIBLE" : "not visible", pid);
    ok &= shared == 1;
  }

  if (strchr(steps, 'w')) {
    char *wa[] = {"echo", "wasm-echo-ok", 0};
    int rc = spawn_capture("/bin/echo", wa, buf, sizeof buf);
    printf("posix_spawn wasm /bin/echo: rc=%d out='%s'\n", rc, buf);
    ok &= rc == 0 && !strcmp(buf, "wasm-echo-ok");
  }
  if (strchr(steps, 'x')) {
    char *xa[] = {"hello", "via-posix-spawn", 0};
    int rc = spawn_capture("x86/hello", xa, buf, sizeof buf);
    printf("posix_spawn x86 hello: rc=%d first line='%.60s'\n", rc, buf);
    ok &= rc == 0 && !strncmp(buf, "hello from x86-64!", 18);
  }

  stop = 1;
  if (threads) for (int i = 0; i < 2; i++) pthread_join(t[i], 0);
  printf("%s\n", ok ? "SPAWN OK" : "SPAWN FAIL");
  fflush(stdout);
  return !ok;
}
