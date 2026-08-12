/* sjljchain.c — 2-hop chained longjmp WITHOUT fork: is the swallow a plain
 * sjlj bug or specific to asyncify-rewound child frames?
 * Expected: LEAF → MID handler → TOP handler → exit 7.  */
#define _GNU_SOURCE
#include <unistd.h>
#include <setjmp.h>
#include <string.h>

static void say(const char *s) { write(1, s, strlen(s)); }
static jmp_buf jbTop, jbMid;

static void leaf(void)
{
	say("[1] leaf, longjmp->MID\n");
	longjmp(jbMid, 5);
	say("[!] FELL THROUGH mid longjmp\n");
	_exit(9);
}

static void mid(void)
{
	if (setjmp(jbMid) != 0) {
		say("[2] mid handler, re-longjmp->TOP\n");
		longjmp(jbTop, 6);
		say("[!] FELL THROUGH top longjmp\n");
		_exit(8);
	}
	leaf();
	say("[!] mid returned normally?!\n");
}

int main(void)
{
	if (setjmp(jbTop) != 0) {
		say("[3] TOP handler, PASS\n");
		_exit(7);
	}
	say("[0] armed\n");
	mid();
	say("[!] main fell through\n");
	return 1;
}
