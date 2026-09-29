/* lot_sigaction.c — SA_SIGINFO handlers for pre-7.1 musl binaries.
 *
 * The 7.1 kernel delivers SA_SIGINFO signals by calling sa_restorer as a
 * two-argument trampoline(fn, sig) from the module's function table; the
 * LinuxOnTab sysroot's musl predates that and leaves sa_restorer unset, so
 * the worker rejects the delivery ("Invalid siginfo trampoline") and the
 * process dies on its first SIGCHLD. Plain sa_handler delivery works, so
 * install SA_SIGINFO handlers as plain handlers through a thunk that calls
 * the three-argument handler with a minimal siginfo (si_signo only).
 * Linked with -Wl,--wrap=sigaction. */
#include <signal.h>
#include <string.h>

typedef void (*sa3_t)(int, siginfo_t *, void *);
static sa3_t g_act[_NSIG];

int __real_sigaction(int, const struct sigaction *, struct sigaction *);

static void thunk(int sig) {
  siginfo_t si;
  memset(&si, 0, sizeof(si));
  si.si_signo = sig;
  if (sig > 0 && sig < _NSIG && g_act[sig]) g_act[sig](sig, &si, 0);
}

int __wrap_sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
  struct sigaction a;
  sa3_t prev = (sig > 0 && sig < _NSIG) ? g_act[sig] : 0;
  int rc;
  if (act && (act->sa_flags & SA_SIGINFO) && sig > 0 && sig < _NSIG) {
    a = *act;
    a.sa_flags &= ~SA_SIGINFO;
    a.sa_handler = thunk;
    rc = __real_sigaction(sig, &a, old);
    if (!rc) g_act[sig] = act->sa_sigaction;
  } else {
    rc = __real_sigaction(sig, act, old);
    if (!rc && act && sig > 0 && sig < _NSIG) g_act[sig] = 0;
  }
  /* report a wrapped handler back to the caller the way it installed it */
  if (!rc && old && old->sa_handler == thunk && prev) {
    old->sa_sigaction = prev;
    old->sa_flags |= SA_SIGINFO;
  }
  return rc;
}
