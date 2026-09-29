/*
 * sigchld-info.c — SA_SIGINFO delivery for binaries built with the pre-7.1
 * LinuxOnTab musl sysroot (toolchain/musl-sysroot-fixed). That musl has no
 * siginfo trampoline, so on the 7.1 kernel the page runtime calls the
 * three-argument handler itself (worker.ts call_siginfo_handler compat path).
 *   1. SIGCHLD SA_SIGINFO handler after fork + _exit(42): si_code CLD_EXITED,
 *      si_pid = child, si_status = 42, non-NULL ucontext
 *   2. raise(SIGUSR1) SA_SIGINFO: si_code SI_TKILL, si_pid = getpid()
 *   3. nested: SIGUSR1 handler raises SIGUSR2 (SA_SIGINFO); the outer siginfo
 *      and a stack canary must survive the inner delivery (frame placement)
 *   4. plain sa_handler still works
 * Output via raw write(2). Exit status = number of failures.
 *
 * Linked with --table-base=2 (build.sh): a handler at function-table index 1
 * equals SIG_IGN to the kernel, so SIGCHLD would be ignored and the child
 * auto-reaped — a separate sysroot/linker issue this test must not trip on.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <errno.h>
#include <unistd.h>

extern pid_t fork(void); /* provided by sysroot/wasm_fork.c */

static int failures;
static void say(const char *s) { write(1, s, strlen(s)); }
static void sayn(const char *s, long n)
{
	char b[24]; int i = sizeof b;
	int neg = n < 0;
	unsigned long u = neg ? -n : n;
	say(s);
	do b[--i] = '0' + u % 10; while (u /= 10);
	if (neg) b[--i] = '-';
	write(1, b + i, sizeof b - i);
}
static void check(const char *what, int ok)
{
	say(ok ? "  ok   " : "  FAIL "); say(what); say("\n");
	if (!ok) failures++;
}

static volatile sig_atomic_t chld_seen, chld_code, chld_pid, chld_status, chld_ctx;
static void on_chld(int sig, siginfo_t *si, void *ctx)
{
	chld_seen = sig;
	chld_code = si ? si->si_code : -1;
	chld_pid = si ? si->si_pid : -1;
	chld_status = si ? si->si_status : -1;
	chld_ctx = ctx != 0;
}

static volatile sig_atomic_t usr1_seen, usr1_code, usr1_pid, usr2_seen, usr2_code, nest_ok;
static void on_usr2(int sig, siginfo_t *si, void *ctx)
{
	(void)ctx;
	usr2_seen = sig;
	usr2_code = si->si_code;
}
static void on_usr1(int sig, siginfo_t *si, void *ctx)
{
	volatile char canary[64];
	(void)ctx;
	memset((char *)canary, 0x5a, sizeof canary);
	usr1_seen = sig;
	usr1_code = si->si_code;
	usr1_pid = si->si_pid;
	raise(SIGUSR2);
	nest_ok = si->si_signo == SIGUSR1 && si->si_code == usr1_code;
	for (unsigned i = 0; i < sizeof canary; i++)
		if (canary[i] != 0x5a) nest_ok = 0;
}

static volatile sig_atomic_t plain_seen;
static void on_plain(int sig) { plain_seen = sig; }

static int install(int sig, void (*fn)(int, siginfo_t *, void *))
{
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = fn;
	sa.sa_flags = SA_SIGINFO | SA_RESTART;
	sigemptyset(&sa.sa_mask);
	return sigaction(sig, &sa, 0);
}

int main(void)
{
	pid_t child, got;
	int status = 0, i;

	say("[1] SIGCHLD SA_SIGINFO after fork\n");
	check("sigaction(SIGCHLD)", install(SIGCHLD, on_chld) == 0);
	child = fork();
	if (child == 0) _exit(42);
	check("fork", child > 0);
	for (i = 0; i < 200 && !chld_seen; i++) usleep(10000);
	got = waitpid(child, &status, 0);
	if (got != child) {
		sayn("      waitpid=", got); sayn(" errno=", errno);
		sayn(" status=", status); sayn(" loops=", i); say("\n");
	}
	check("waitpid", got == child && WIFEXITED(status) && WEXITSTATUS(status) == 42);
	check("handler ran", chld_seen == SIGCHLD);
	sayn("      si_code=", chld_code); sayn(" si_pid=", chld_pid);
	sayn(" (child ", child); sayn(") si_status=", chld_status); say("\n");
	check("si_code == CLD_EXITED", chld_code == CLD_EXITED);
	check("si_pid == child", chld_pid == child);
	check("si_status == 42", chld_status == 42);
	check("ucontext non-NULL", chld_ctx);

	say("[2+3] raise(SIGUSR1) with nested SIGUSR2\n");
	check("sigaction(SIGUSR1)", install(SIGUSR1, on_usr1) == 0);
	check("sigaction(SIGUSR2)", install(SIGUSR2, on_usr2) == 0);
	raise(SIGUSR1);
	check("SIGUSR1 handler ran", usr1_seen == SIGUSR1);
	check("SIGUSR1 si_code == SI_TKILL", usr1_code == SI_TKILL);
	check("SIGUSR1 si_pid == getpid()", usr1_pid == getpid());
	check("nested SIGUSR2 ran with SI_TKILL", usr2_seen == SIGUSR2 && usr2_code == SI_TKILL);
	check("outer siginfo + stack survived nesting", nest_ok);

	say("[4] plain handler\n");
	signal(SIGUSR1, on_plain);
	raise(SIGUSR1);
	check("plain SIGUSR1 handler ran", plain_seen == SIGUSR1);

	sayn(failures ? "sigchld-info: FAILED " : "sigchld-info: PASS ", failures);
	say("\n");
	return failures;
}
