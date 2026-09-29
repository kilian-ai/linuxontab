/* forktls — the fork child must come back with the parent's __stack_pointer
 * and __tls_base: it uses a _Thread_local and makes deep calls after fork,
 * then checks that the frames of fork()'s callers (a guarded buffer in each)
 * were not overwritten. Expect "forktls: OK". */
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
pid_t fork(void);

static _Thread_local long t = 42;
static _Thread_local char tbuf[256];

__attribute__((noinline)) static unsigned deep(int n, unsigned acc)
{
  volatile unsigned char pad[512];         /* ~0.5 KB of shadow stack a frame */
  for (int i = 0; i < (int)sizeof pad; i++) pad[i] = (unsigned char)(n + i);
  if (n == 0) return acc;
  unsigned r = deep(n - 1, acc * 31 + pad[n % sizeof pad]);
  return r + pad[(n * 7) % sizeof pad] - (unsigned char)(n + (n * 7) % sizeof pad);
}

static int check(volatile unsigned char *b, int len, unsigned char seed)
{
  for (int i = 0; i < len; i++) if (b[i] != (unsigned char)(seed + i)) return 0;
  return 1;
}

__attribute__((noinline)) static int child(void)
{
  int bad = 0;
  if (t != 42) { printf("child: t=%ld, want 42 (TLS base lost)\n", t); bad = 1; }
  t = 7; strcpy(tbuf, "child");
  unsigned want = deep(200, 1);            /* ~100 KB of frames */
  if (deep(200, 1) != want) bad = 1;
  if (t != 7 || strcmp(tbuf, "child")) { printf("child: TLS clobbered\n"); bad = 1; }
  return bad;
}

__attribute__((noinline)) static int level(int n)
{
  volatile unsigned char guard[2048];
  for (int i = 0; i < (int)sizeof guard; i++) guard[i] = (unsigned char)(n * 13 + i);
  int rc;
  if (n > 0) {
    rc = level(n - 1);
  } else {
    pid_t p = fork();
    if (p < 0) { perror("fork"); return 100; }
    if (p == 0) {
      int bad = child();
      _exit(bad ? 1 : 0);                  /* reached only if the caller frames survive: */
    }
    int st;
    if (waitpid(p, &st, 0) != p) { perror("waitpid"); return 100; }
    rc = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
  }
  if (!check(guard, sizeof guard, (unsigned char)(n * 13))) {
    printf("%s: frame %d clobbered\n", "parent", n);
    rc |= 64;
  }
  return rc;
}

/* The child checks its caller frames too: fork from level 0, then have the
 * child walk back up through level()'s guard checks before exiting. */
__attribute__((noinline)) static int level_child_returns(int n)
{
  volatile unsigned char guard[2048];
  for (int i = 0; i < (int)sizeof guard; i++) guard[i] = (unsigned char)(n * 17 + i);
  int rc;
  if (n > 0) {
    rc = level_child_returns(n - 1);
  } else {
    pid_t p = fork();
    if (p < 0) { perror("fork"); return -100; }
    if (p == 0) return child() ? -1 : -2; /* child returns through the frames */
    rc = p;
  }
  if (!check(guard, sizeof guard, (unsigned char)(n * 17))) {
    printf("frame %d clobbered (%s)\n", n, rc < 0 ? "child" : "parent");
    return rc < 0 ? -3 : -100;
  }
  return rc;
}

int main(void)
{
  int bad = 0;
  strcpy(tbuf, "parent");
  int rc = level(8);
  if (rc) { printf("forktls: child/frames failed (rc=%d)\n", rc); bad = 1; }

  rc = level_child_returns(8);
  if (rc < 0) {                            /* we are the child, back in main */
    if (rc == -1) printf("forktls: child TLS/deep-call check failed\n");
    if (rc == -3) printf("forktls: child saw clobbered caller frames\n");
    _exit(rc == -2 ? 0 : 1);
  }
  int st;
  if (waitpid(rc, &st, 0) != rc || !WIFEXITED(st) || WEXITSTATUS(st)) {
    printf("forktls: returning child failed (status %#x)\n", st); bad = 1;
  }
  if (t != 42 || strcmp(tbuf, "parent")) { printf("forktls: parent TLS changed\n"); bad = 1; }
  printf("forktls: %s\n", bad ? "FAIL" : "OK");
  return bad;
}
