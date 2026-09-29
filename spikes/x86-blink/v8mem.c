/* v8mem.c — the exact memory-syscall sequence V8's page allocator did right
 * before Node died with SEGV_ACCERR under Blink (from blink -s):
 *   mmap(hint, 0x7f000, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE)
 *   madvise(p, 0x7f000, 10)          (MADV_DONTFORK)
 *   munmap(p + 0x40000, 0x3f000)     (trim to the aligned part)
 *   mprotect(p, 0x40000, PROT_READ|PROT_WRITE)
 *   then read/write inside [p, p + 0x40000) */
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main(int argc, char **argv) {
  int step = argc > 1 ? argv[1][0] - '0' : 9;
  char *p = mmap(0, 0x7f000, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) { perror("mmap"); return 1; }
  if (step >= 1 && madvise(p, 0x7f000, 10)) perror("madvise");
  if (step >= 2 && munmap(p + 0x40000, 0x3f000)) perror("munmap");
  if (mprotect(p, 0x40000, PROT_READ | PROT_WRITE)) { perror("mprotect"); return 1; }
  p[0x2a809] = 42;
  memset(p, 7, 0x40000);
  printf("v8mem step %d: ok %d\n", step, p[0x2a809]);
  return 0;
}
