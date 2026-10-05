// C++ wasm exceptions + asyncify fork (sysroot/wasm_fork.c) in one module.
#include <cstdio>
#include <stdexcept>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
extern "C" pid_t fork(void);
static int depth(int n) { if (n == 0) throw std::runtime_error("deep"); return depth(n - 1) + 1; }
int main() {
    int ok = 0;
    try { depth(10); } catch (const std::exception &e) { ok += std::string(e.what()) == "deep"; }
    std::fflush(stdout);
    pid_t p = fork();
    if (p == 0) {
        int c = 0;
        try { depth(5); } catch (const std::runtime_error &) { c = 1; }
        _exit(c ? 7 : 1);
    }
    int st = 0;
    waitpid(p, &st, 0);
    ok += WIFEXITED(st) && WEXITSTATUS(st) == 7;
    try { throw 42; } catch (int v) { ok += v == 42; }
    std::printf("forkeh: %d/3 %s (child status %d)\n", ok, ok == 3 ? "OK" : "FAIL", WEXITSTATUS(st));
    return ok != 3;
}
