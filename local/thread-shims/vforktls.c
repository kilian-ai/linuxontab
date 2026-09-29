/* vforktls — a CLONE_VM|CLONE_VFORK child with its own stack (Blink's guest
 * vfork, musl posix_spawn) must get a fresh TLS block: its _Thread_local
 * writes must not land in the suspended parent thread's block. Also checks
 * that posix_spawn still works. Expect "vforktls: OK". */
#define _GNU_SOURCE
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
int __clone(int (*)(void *), void *, int, void *, ...);
extern char **environ;

static _Thread_local long t = 42;
static volatile long child_saw = -1, child_wrote_ok;
static char stk[65536] __attribute__((aligned(16)));

static int child(void *a)
{
  (void)a;
  child_saw = t;                 /* 42 = fresh image, 99 = parent's block */
  t = 7;
  child_wrote_ok = (t == 7);
  _exit(0);
}

int main(void)
{
  int bad = 0, st;
  t = 99;
  int pid = __clone(child, stk + sizeof stk, 0x100 /* CLONE_VM */ | 0x4000 /* CLONE_VFORK */ | SIGCHLD, 0);
  if (pid < 0) { printf("clone failed: %d\n", pid); return 1; }
  waitpid(pid, &st, 0);
  if (child_saw != 42) { printf("vfork child saw t=%ld (want 42: fresh block)\n", child_saw); bad = 1; }
  if (!child_wrote_ok) { printf("vfork child TLS write failed\n"); bad = 1; }
  if (t != 99) { printf("parent t=%ld after vfork child (want 99)\n", t); bad = 1; }

  pid_t p;
  char *argv[] = { "echo", "posix_spawn child ran", 0 };
  int e = posix_spawn(&p, "/bin/echo", 0, 0, argv, environ);
  if (e || waitpid(p, &st, 0) != p || !WIFEXITED(st) || WEXITSTATUS(st)) {
    printf("posix_spawn failed (err %d, status %#x)\n", e, st); bad = 1;
  }
  printf("vforktls: %s\n", bad ? "FAIL" : "OK");
  return bad;
}
