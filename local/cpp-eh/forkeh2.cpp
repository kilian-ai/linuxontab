// Like forkeh.cpp, but no try/catch in any function that is on the stack at
// fork(): exceptions are thrown and caught in helpers only.
#include <cstdio>
#include <stdexcept>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
extern "C" pid_t fork(void);
static int depth(int n) { if (n == 0) throw std::runtime_error("deep"); return depth(n - 1) + 1; }
__attribute__((noinline)) static int catches(int n) {
    try { depth(n); } catch (const std::exception &e) { return std::string(e.what()) == "deep"; }
    return 0;
}
__attribute__((noinline)) static pid_t do_fork(void) { return fork(); }
int main() {
    int ok = catches(10);
    std::fflush(stdout);
    pid_t p = do_fork();
    if (p == 0) _exit(catches(5) ? 7 : 1);
    int st = 0;
    waitpid(p, &st, 0);
    ok += WIFEXITED(st) && WEXITSTATUS(st) == 7;
    ok += catches(3);
    std::printf("forkeh2: %d/3 %s (child status %d)\n", ok, ok == 3 ? "OK" : "FAIL", WEXITSTATUS(st));
    return ok != 3;
}
