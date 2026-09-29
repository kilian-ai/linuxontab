/* lot_sbrk.c — sbrk that grows wasm memory in the right units.
 *
 * The sysroot's musl _brk counts its increment in 16 KiB musl pages and
 * passes that count to memory.grow (64 KiB pages): linear memory grows 4x
 * faster than the heap, hits the 256 MiB maximum, and every dlmalloc port
 * tops out at ~54 MiB of heap. toolchain/patches/musl-brk-wasm-page-units.patch
 * fixes it; toolchain/musl-sysroot-fixed includes it since 2026-09-29, so this
 * is only needed against an older sysroot. Linked before -lc, it replaces
 * musl's sbrk for dlmalloc (the only caller). */
#include <errno.h>
#include <stdint.h>
#include <unistd.h>

extern unsigned char __heap_base;
static uintptr_t cur;

void *sbrk(intptr_t inc) {
  if (!cur) cur = ((uintptr_t)&__heap_base + 15) & ~(uintptr_t)15;
  uintptr_t old = cur, end = old + inc;
  if (inc < 0 || end < old) { errno = ENOMEM; return (void *)-1; }
  uintptr_t memend = (uintptr_t)__builtin_wasm_memory_size(0) * 65536;
  if (end > memend) {
    size_t pages = (end - memend + 65535) / 65536;
    if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) {
      errno = ENOMEM;
      return (void *)-1;
    }
  }
  cur = end;
  return (void *)old;
}
