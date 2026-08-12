/*
 * sjljfork2.c — ash-shaped repro: CHAINED exception handlers + fork child.
 * ash's EXEXIT longjmps to the innermost handler, which RE-RAISES to the
 * next handler, hop by hop, until the top handler _exits. Mimic that with
 * two handlers: main() arms jbTop; mid() arms jbMid; the fork child
 * longjmps to jbMid, whose handler re-longjmps to jbTop, which _exits(7).
 */
#define _GNU_SOURCE
#include <unistd.h>
#include <sys/wait.h>
#include <setjmp.h>
#include <string.h>

extern pid_t fork(void);
static void say(const char *s) { write(1, s, strlen(s)); }

static jmp_buf jbTop, jbMid;

static void leaf(void)
{
	pid_t p = fork();
	if (p == 0) {
		say("[c] child up, longjmp->MID\n");
		longjmp(jbMid, 5);
		say("[c] FELL THROUGH mid longjmp!\n");
		_exit(9);
	}
	if (p < 0) { say("[!] fork failed\n"); _exit(2); }
	int st = 0;
	waitpid(p, &st, 0);
	say(WIFEXITED(st) && WEXITSTATUS(st) == 7 ? "[p] child status=7 OK\n"
	                                          : "[p] child BAD status\n");
}

static void mid(void)
{
	volatile char pad[256]; pad[0] = 1;
	int v = setjmp(jbMid);
	if (v != 0) {
		/* child lands here first; re-raise to top (ash re-raise pattern) */
		say("[c] mid handler hit, re-longjmp->TOP\n");
		longjmp(jbTop, 6);
		say("[c] FELL THROUGH top longjmp!\n");
		_exit(8);
	}
	leaf();
	(void)pad[0];
}

int main(void)
{
	int v = setjmp(jbTop);
	if (v != 0) {
		say("[c] TOP handler hit, exiting 7\n");
		_exit(7);
	}
	say("[p] handlers armed\n");
	mid();
	say("[p] parent path intact\nPASS\n");
	return 0;
}
