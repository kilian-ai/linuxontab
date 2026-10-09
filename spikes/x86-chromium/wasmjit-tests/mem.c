/* differential test for wasmjit's inline memory operands: the hash must be
   the same under the old and the new Blink */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
typedef uint64_t u64; typedef uint8_t u8;
static u64 s = 0x243f6a8885a308d3ull;
static u64 rnd(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static u64 H = 1469598103934665603ull;
static void mix(u64 v) { H = (H ^ v) * 1099511628211ull; }
#define FL 0x8d5ull
static __thread u64 tls[8];
__attribute__((noinline)) static u64 deep(u64 a, u64 b, u64 c, u64 d, int k) {
  u64 loc[4] = {a, b, c, d};                       /* stack traffic + push/pop */
  if (k) return deep(b ^ loc[k & 3], c + 1, d, a, k - 1) + loc[(k + 1) & 3];
  return a * 3 + b - c ^ d;
}
int main(void) {
  /* two pages, the second one boundary-crossing target */
  u8 *pg = mmap(0, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  u64 *arr = malloc(64 * sizeof(u64));
  for (int i = 0; i < 64; i++) arr[i] = rnd();
  for (int i = 0; i < 200000; i++) {
    u64 y = rnd(), f; int k = i & 63;
    u64 *p = &arr[k];
    __asm__ volatile("addq %2,%0\n\tpushfq\n\tpopq %1" : "+m"(*p), "=r"(f) : "r"(y) : "cc"); mix(*p); mix(f & FL);
    __asm__ volatile("subl %k2,%0\n\tpushfq\n\tpopq %1" : "+m"(*(uint32_t *)p), "=r"(f) : "r"(y) : "cc"); mix(*p); mix(f & FL);
    __asm__ volatile("xorq %1,%0" : "+m"(*p) : "r"(y)); mix(*p);
    { u64 a = y; __asm__ volatile("andq %2,%0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : "m"(*p) : "cc"); mix(a); mix(f & FL); }
    { u64 a = y; __asm__ volatile("orl %1,%k0" : "+r"(a) : "m"(*(uint32_t *)p)); mix(a); }
    __asm__ volatile("cmpq %1,%2\n\tpushfq\n\tpopq %0" : "=r"(f) : "r"(y), "m"(*p) : "cc"); mix(f & FL);
    __asm__ volatile("cmpq %2,%1\n\tpushfq\n\tpopq %0" : "=r"(f) : "r"(y), "m"(*p) : "cc"); mix(f & FL);
    __asm__ volatile("testl %k1,%2\n\tpushfq\n\tpopq %0" : "=r"(f) : "r"(y), "m"(*(uint32_t *)p) : "cc"); mix(f & FL);
    __asm__ volatile("cmpq $7,%1\n\tpushfq\n\tpopq %0" : "=r"(f) : "m"(*p) : "cc"); mix(f & FL);
    __asm__ volatile("addq $-3,%0" : "+m"(*p)); mix(*p);
    __asm__ volatile("movq $0x7fff0001,%0" : "=m"(arr[(k + 1) & 63])); mix(arr[(k + 1) & 63]);
    __asm__ volatile("movl $0xfffffff0,%0" : "=m"(*(uint32_t *)&arr[(k + 2) & 63])); mix(arr[(k + 2) & 63]);
    { u64 a; __asm__ volatile("movq %1,%0" : "=r"(a) : "m"(arr[(k * 7) & 63])); mix(a); }
    { uint32_t a; __asm__ volatile("movl %1,%0" : "=r"(a) : "m"(*(uint32_t *)&arr[(k * 5) & 63])); mix(a); }
    /* page-crossing loads/stores: the inline path must fall back */
    u64 *x = (u64 *)(pg + 4096 - 4 + (i & 3));
    __asm__ volatile("movq %1,%0" : "=m"(*x) : "r"(y)); mix(*x);
    { u64 a; __asm__ volatile("movq %1,%0" : "=r"(a) : "m"(*x)); mix(a); }
    __asm__ volatile("addq %1,%0" : "+m"(*x) : "r"(y)); mix(*x);
    /* fs-relative (TLS) */
    tls[k & 7] += y; mix(tls[(k + 3) & 7]);
    if ((i & 255) == 0) mix(deep(y, y >> 3, ~y, y * 5, 20));
  }
  printf("mem hash %016llx\n", (unsigned long long)H);
  return 0;
}
