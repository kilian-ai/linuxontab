/* wasm_fork_enosys.c — fork() for wasm programs that cannot be asyncified
 * (those using C++ wasm exceptions in try/catch on the fork path, such as
 * LibreOffice): fails with ENOSYS, so callers take their error path instead
 * of the link failing. Programs that can be asyncified link wasm_fork.c. */
#include <errno.h>
#include <sys/types.h>
pid_t fork(void) { errno = ENOSYS; return -1; }
