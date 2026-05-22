/* tcplisten.c — minimal inetd: bind TCP port, fork+exec prog per connection.
 *
 * Compiled for @tombl/linux WASM kernel.  fork() uses the kernel's custom
 * asyncify protocol (syscall 9999) because musl hides the standard fork()
 * wrapper behind #ifndef __wasm__.  wasm-opt --asyncify (applied by
 * build-rootfs.sh) instruments all functions so the unwind/rewind works.
 *
 * Usage: tcplisten PORT PROG [ARGS...]
 */

#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>

/* ---- @tombl/linux WASM syscall import ---- */
__attribute__((import_module("linux"), import_name("syscall")))
long __wasm_syscall(long n, long a, long b, long c, long d, long e, long f);

/* ---- Asyncify-based fork() for the WASM kernel ----
 *
 * The kernel intercepts syscall 9999 (WASM_SYS_FORK):
 *   arg0 = asyncify data buffer pointer (must have header set up first)
 *   arg1 = pointer to i32 where the fork return value will be written
 *
 * Phase 1 (asyncify state == 0 / Normal):
 *   kernel calls asyncify_start_unwind(arg0) => WASM unwinds, syscall "returns 0"
 * Phase 3 (asyncify state == 2 / Rewinding):
 *   kernel calls asyncify_stop_rewind(); returns memory[arg1]
 *   (= 0 in child, = childPid in parent, < 0 on error)
 *
 * The asyncify buffer header layout (binaryen convention):
 *   i32 @ offset 0: pointer to current top of stack data  (= buf+8 initially)
 *   i32 @ offset 4: pointer to end of buffer              (= buf+BUFSZ)
 */
#define ASYNCIFY_BUF_SIZE 8192

static char   _asyncify_buf[ASYNCIFY_BUF_SIZE] __attribute__((aligned(8)));
static int    _fork_ret;

static int wasm_fork(void)
{
    /* Initialise asyncify buffer header */
    ((int *)_asyncify_buf)[0] = (int)(long)(_asyncify_buf + 8);
    ((int *)_asyncify_buf)[1] = (int)(long)(_asyncify_buf + ASYNCIFY_BUF_SIZE);
    _fork_ret = -1;
    return (int)__wasm_syscall(9999,
                               (long)(int)(long)_asyncify_buf,
                               (long)(int)(long)&_fork_ret,
                               0, 0, 0, 0);
}

int main(int argc, char *argv[])
{
    if (argc < 3) {
        fprintf(stderr, "usage: tcplisten PORT PROG [ARGS...]\n");
        return 1;
    }
    int port = atoi(argv[1]);
    char **prog = argv + 2;

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }

    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = 0; /* INADDR_ANY */
    /* htons inline */
    addr.sin_port = (unsigned short)(((port & 0xff) << 8) | ((port >> 8) & 0xff));

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    if (listen(srv, 16) < 0) { perror("listen"); return 1; }

    for (;;) {
        /* reap zombies */
        while (waitpid(-1, NULL, WNOHANG) > 0) {}

        int cli = accept(srv, NULL, NULL);
        if (cli < 0) {
            if (errno == EINTR) continue;
            perror("accept"); break;
        }

        int pid = wasm_fork();
        if (pid < 0) {
            close(cli);
            continue;
        }
        if (pid == 0) {
            /* child: wire stdio to the socket, then exec dropbear -i */
            dup2(cli, 0);
            dup2(cli, 1);
            close(cli);
            close(srv);
            execv(prog[0], prog);
            _exit(127);
        }
        /* parent */
        close(cli);
    }
    return 0;
}
