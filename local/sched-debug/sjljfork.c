/*
 * sjljfork.c — does longjmp work in a FORK CHILD whose stack was rebuilt by
 * asyncify rewind? Repro for the ash $()-child-continues bug: ash's subshell
 * child exits via longjmp(EXEXIT) targeting a setjmp taken BEFORE the fork;
 * if that longjmp is swallowed/misrouted in the child, the child falls
 * through and keeps executing the parent's script.
 *
 * Build with: -mllvm --enable-emscripten-sjlj + sjlj_rt.c + wasm_fork.c,
 * asyncify -O1 (see build-sjljfork.sh).
 *
 * Expected output:
 *   [p] setjmp armed
 *   [c] child up, longjmping
 *   [c] LANDED val=42        <- child longjmp works
 *   [p] child status=7
 *   [p] parent setjmp not disturbed
 *   PASS
 * Bug behavior: child prints "FELL THROUGH" (longjmp swallowed) instead of
 * LANDED, or lands in the parent's copy weirdly.
 */
#define _GNU_SOURCE
#include <unistd.h>
#include <sys/wait.h>
#include <setjmp.h>
#include <string.h>

extern pid_t fork(void);

static void say(const char *s) { write(1, s, strlen(s)); }

static jmp_buf jb;

/* Some call depth between setjmp and fork so the rewind rebuilds frames. */
static int depth3(void)
{
	pid_t p = fork();
	if (p == 0) {
		say("[c] child up, longjmping\n");
		longjmp(jb, 42);
		say("[c] FELL THROUGH longjmp!\n");
		_exit(9);
	}
	if (p < 0) { say("[!] fork failed\n"); _exit(2); }
	int st = 0;
	waitpid(p, &st, 0);
	if (WIFEXITED(st) && WEXITSTATUS(st) == 7)
		say("[p] child status=7\n");
	else
		say("[p] child BAD status\n");
	return 0;
}
static int depth2(void) { volatile char pad[512]; pad[0]=1; return depth3()+ (pad[0]?0:1); }
static int depth1(void) { volatile char pad[512]; pad[0]=1; return depth2()+ (pad[0]?0:1); }

int main(void)
{
	int v = setjmp(jb);
	if (v != 0) {
		/* Only the CHILD longjmps here. */
		say("[c] LANDED val=");
		char c = '0' + (v % 10); write(1, &c, 1); write(1, "\n", 1);
		_exit(7);
	}
	say("[p] setjmp armed\n");
	depth1();
	say("[p] parent setjmp not disturbed\n");
	say("PASS\n");
	return 0;
}
