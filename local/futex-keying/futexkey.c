/* Cross-process futex keying check. Every wasm process has its own linear
 * memory with an identical layout, so `word` sits at the same address in two
 * instances of this program. A private futex must be keyed by (mm, address):
 *   ./futexkey wait &   # FUTEX_WAIT on its own `word`, 4 s timeout
 *   ./futexkey wake     # FUTEX_WAKE on ITS own `word`: nobody waits there
 * Correct kernel: wake reports 0 woken, the waiter times out (ETIMEDOUT).
 * Buggy kernel:   wake reports 1, the waiter returns 0 (woken by a stranger). */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>
#define FUTEX_WAIT_PRIVATE 128  /* FUTEX_WAIT | FUTEX_PRIVATE_FLAG */
#define FUTEX_WAKE_PRIVATE 129

static volatile int word;

int main(int argc, char **argv)
{
	if (argc > 1 && !strcmp(argv[1], "wait")) {
		struct timespec ts = { 4, 0 };
		printf("wait: pid %d futex @%p\n", getpid(), (void *)&word);
		fflush(stdout);
		long r = syscall(SYS_futex, &word, FUTEX_WAIT_PRIVATE, 0, &ts, 0, 0);
		int e = errno;
		if (r == -1 && e == ETIMEDOUT)
			printf("wait: timed out: OK\n");
		else
			printf("wait: returned %ld (%s): FAIL, woken by another process\n",
			       r, r ? strerror(e) : "woken");
		return !(r == -1 && e == ETIMEDOUT);
	}
	if (argc > 1 && !strcmp(argv[1], "wake")) {
		long r = syscall(SYS_futex, &word, FUTEX_WAKE_PRIVATE, 1, 0, 0, 0);
		printf("wake: pid %d futex @%p woke %ld: %s\n", getpid(),
		       (void *)&word, r, r == 0 ? "OK" : "FAIL, crossed processes");
		return r != 0;
	}
	fprintf(stderr, "usage: %s wait|wake\n", argv[0]);
	return 2;
}
