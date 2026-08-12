/*
 * forktest.c — validate dynamic-buffer fork()/vfork() (wasm_fork_dyn.c) in the
 * guest WITHOUT touching busybox. Exercises the three cases the fixed sizing +
 * per-call malloc must handle:
 *   1. shallow fork + wait          (128 KB floor path)
 *   2. DEEP-stack fork              (large __stack_top - sp → large thunk)
 *   3. nested fork (child forks)    (reentrancy: two live thunks at once)
 *   4. vfork + _exit               (vfork share-then-resume path)
 *
 * Output goes via raw write(2) so a broken stdio path can't mask a pass/fail.
 * Build/install exactly like futexpp (see build-forktest.sh).
 */
#define _GNU_SOURCE
#include <unistd.h>
#include <sys/wait.h>
#include <string.h>
#include <stdlib.h>

/* This musl/wasm unistd.h guards out fork/vfork; they're provided by
 * wasm_fork_dyn.c, so declare them explicitly. */
extern pid_t fork(void);
extern pid_t vfork(void);

static void say(const char *s) { write(1, s, strlen(s)); }
static void sayn(const char *s, long n)
{
	char b[32]; int i = 0; char t[32]; int j = 0;
	say(s);
	if (n == 0) { write(1, "0", 1); write(1, "\n", 1); return; }
	if (n < 0) { write(1, "-", 1); n = -n; }
	while (n > 0) { t[j++] = '0' + (n % 10); n /= 10; }
	while (j > 0) b[i++] = t[--j];
	b[i++] = '\n';
	write(1, b, i);
}

/* Consume ~1 KB of shadow stack per frame; recurse `depth` deep, then fork at
 * the bottom so the asyncify thunk must capture a deep call chain. The volatile
 * touch keeps the array from being optimized away. */
static int deep_fork(int depth)
{
	volatile char pad[1024];
	pad[0] = (char)depth;
	pad[1023] = (char)~depth;
	if (depth > 0)
		return deep_fork(depth - 1) + (pad[0] ? 0 : 1);

	pid_t p = fork();
	if (p == 0) {
		say("  [deep child] alive, exiting 0\n");
		_exit(0);
	}
	if (p < 0) { say("  [deep] fork FAILED\n"); return -1; }
	int st = 0;
	waitpid(p, &st, 0);
	sayn("  [deep] child reaped, status=", WEXITSTATUS(st));
	return 0;
}

int main(void)
{
	say("=== forktest: dynamic-buffer fork/vfork ===\n");

	/* 1. shallow fork */
	say("[1] shallow fork\n");
	pid_t p = fork();
	if (p == 0) { say("  [child] pid ok, exit 7\n"); _exit(7); }
	if (p < 0) { say("  shallow fork FAILED\n"); return 1; }
	int st = 0; waitpid(p, &st, 0);
	sayn("  parent reaped status=", WEXITSTATUS(st));
	if (WEXITSTATUS(st) != 7) { say("  FAIL: bad status\n"); return 1; }

	/* 2. deep-stack fork (drives large dynamic thunk) */
	say("[2] deep-stack fork (depth 200 ~= 200KB stack)\n");
	if (deep_fork(200) != 0) return 1;

	/* 3. nested fork: child forks a grandchild (two live thunks) */
	say("[3] nested fork\n");
	p = fork();
	if (p == 0) {
		pid_t g = fork();
		if (g == 0) { say("    [grandchild] exit 3\n"); _exit(3); }
		int gs = 0; waitpid(g, &gs, 0);
		sayn("    [child] grandchild status=", WEXITSTATUS(gs));
		_exit(WEXITSTATUS(gs) == 3 ? 0 : 1);
	}
	if (p < 0) { say("  nested fork FAILED\n"); return 1; }
	waitpid(p, &st, 0);
	sayn("  [parent] child status=", WEXITSTATUS(st));
	if (WEXITSTATUS(st) != 0) { say("  FAIL: nested\n"); return 1; }

	/* 4. vfork + _exit */
	say("[4] vfork + _exit\n");
	p = vfork();
	if (p == 0) { _exit(11); }
	if (p < 0) { say("  vfork FAILED\n"); return 1; }
	waitpid(p, &st, 0);
	sayn("  vfork child status=", WEXITSTATUS(st));
	if (WEXITSTATUS(st) != 11) { say("  FAIL: vfork\n"); return 1; }

	/* 5. rapid loop — stress the malloc/free churn + repeated unwind/rewind */
	say("[5] rapid fork x50\n");
	for (int i = 0; i < 50; i++) {
		p = fork();
		if (p == 0) _exit(0);
		if (p < 0) { sayn("  loop fork FAILED at i=", i); return 1; }
		waitpid(p, &st, 0);
	}
	say("  50/50 ok\n");

	say("=== ALL FORKTESTS PASSED ===\n");
	return 0;
}
