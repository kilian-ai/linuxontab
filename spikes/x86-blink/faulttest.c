// Guest faults under Blink must reach the guest's handlers: SIGSEGV (unmapped
// read, write to a read-only page), SIGFPE (divide by zero), SIGILL (ud2),
// each caught and left with siglongjmp; then an unhandled fault in a fork
// child must kill only that child, with WTERMSIG = SIGSEGV.
// Build: x86_64-linux-musl-gcc -static -O1 -o faulttest faulttest.c
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

static sigjmp_buf jb;
static volatile int got_sig;
static void *volatile got_addr;
static int pass, fail;

static void on_fault(int sig, siginfo_t *si, void *uc) {
  (void)uc;
  got_sig = sig;
  got_addr = si->si_addr;
  siglongjmp(jb, 1);
}

static void check(const char *name, int want, void (*fn)(void)) {
  got_sig = 0;
  if (!sigsetjmp(jb, 1)) {
    fn();
    printf("FAIL %s: no signal\n", name), fail++;
  } else if (got_sig == want) {
    printf("PASS %s: sig %d addr %p\n", name, got_sig, got_addr), pass++;
  } else {
    printf("FAIL %s: sig %d, want %d\n", name, got_sig, want), fail++;
  }
}

static void rd_unmapped(void) { (void)*(volatile char *)0x100000360; }
static char *ro;
static void wr_readonly(void) { *(volatile char *)ro = 1; }
static volatile int zero, seven = 7;
static void div_zero(void) { volatile int x = seven / zero; (void)x; }
static void ud2(void) { __asm__ volatile("ud2"); }

int main(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = on_fault;
  sa.sa_flags = SA_SIGINFO;
  sigaction(SIGSEGV, &sa, 0);
  sigaction(SIGBUS, &sa, 0);
  sigaction(SIGFPE, &sa, 0);
  sigaction(SIGILL, &sa, 0);
  ro = mmap(0, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  check("read unmapped", SIGSEGV, rd_unmapped);
  check("write read-only", SIGSEGV, wr_readonly);
  check("divide by zero", SIGFPE, div_zero);
  check("ud2", SIGILL, ud2);
  check("read unmapped again", SIGSEGV, rd_unmapped);
  // the mask saved by sigsetjmp(jb, 1) is back: SIGSEGV not blocked
  sigset_t cur;
  sigprocmask(SIG_BLOCK, 0, &cur);
  if (sigismember(&cur, SIGSEGV)) printf("FAIL mask: SIGSEGV still blocked\n"), fail++;
  else printf("PASS mask restored\n"), pass++;
  pid_t p = fork();
  if (!p) {
    signal(SIGSEGV, SIG_DFL);
    rd_unmapped();
    _exit(0);
  }
  int st = 0;
  waitpid(p, &st, 0);
  if (WIFSIGNALED(st) && WTERMSIG(st) == SIGSEGV) printf("PASS unhandled fault kills child\n"), pass++;
  else printf("FAIL unhandled fault: status 0x%x\n", st), fail++;
  printf("faulttest: %d pass, %d fail\n", pass, fail);
  return fail != 0;
}
