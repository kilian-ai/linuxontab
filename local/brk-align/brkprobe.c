/* brkprobe — the program break must stay PAGE_SIZE (16 KiB) aligned on the
 * wasm musl port (toolchain/patches/musl-brk-wasm-page-units.patch): mallocng
 * works in whole pages off sbrk, and zsh's nested $(...) broke when it did
 * not. Prints FAIL lines and exits 1 on any misaligned break.
 *   build: packages/build-package.sh-style link against musl-sysroot-fixed
 *   run in the guest: ./brkprobe   -> "brkprobe: OK" */
#define _BSD_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define PAGE 16384u
int main(void) {
    int bad = 0;
    static const intptr_t steps[] = { 1, 100, 4095, 16383, 16385, 70000, 3 };
    for (unsigned i = 0; i < sizeof steps / sizeof *steps; i++) {
        void *old = sbrk(steps[i]);
        void *now = sbrk(0);
        if (old == (void *)-1) { printf("FAIL sbrk(%ld) failed\n", (long)steps[i]); bad = 1; continue; }
        if ((uintptr_t)old % PAGE || (uintptr_t)now % PAGE) {
            printf("FAIL sbrk(%ld): old=%p now=%p not %u-aligned\n", (long)steps[i], old, now, PAGE); bad = 1;
        }
        memset(old, 0xa5, steps[i]);      /* the region must be writable */
    }
    /* malloc still works after odd sbrks, and does not hand out sbrk'd bytes */
    void *brk_lo = sbrk(0);
    char *p = malloc(200000), *q = malloc(37);
    if (!p || !q) { printf("FAIL malloc\n"); bad = 1; }
    else { memset(p, 1, 200000); memset(q, 2, 37); }
    printf("brkprobe: %s (break %p)\n", bad ? "FAIL" : "OK", brk_lo);
    return bad;
}
