#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
  printf("memsize=%lu MB sbrk0=%p\n", (unsigned long)__builtin_wasm_memory_size(0) * 64 / 1024, sbrk(0));
  size_t tot = 0; void *p;
  while ((p = NULL, posix_memalign(&p, 4096, 256 * 1024) == 0) && p) {
    tot += 256 * 1024;
    if (tot % (16 << 20) == 0) printf("  %zu MB at %p\n", tot >> 20, p);
  }
  printf("failed after %zu MB, memsize=%lu MB sbrk=%p\n", tot >> 20, (unsigned long)__builtin_wasm_memory_size(0) * 64 / 1024, sbrk(0));
  return 0;
}
