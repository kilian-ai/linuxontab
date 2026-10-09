/* differential test for wasmjit's inline ops: run under old and new Blink,
   the printed hashes must match. pushfq captures the full flags (PF/AF too). */
#include <stdint.h>
#include <stdio.h>
typedef uint64_t u64;
static u64 s = 0x9e3779b97f4a7c15ull;
static u64 rnd(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static u64 H = 1469598103934665603ull;
static void mix(u64 v) { H = (H ^ v) * 1099511628211ull; }
#define FL 0x8d5ull   /* CF PF AF ZF SF OF */
#define OP64(ins) { u64 a = x, f; __asm__ volatile(ins " %2,%0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : "r"(y) : "cc"); mix(a); mix(f & FL); }
#define OP32(ins) { uint32_t a = (uint32_t)x; u64 f; __asm__ volatile(ins " %k2,%k0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : "r"(y) : "cc"); mix(a); mix(f & FL); }
#define CMP64(ins) { u64 f; __asm__ volatile(ins " %1,%2\n\tpushfq\n\tpopq %0" : "=r"(f) : "r"(y), "r"(x) : "cc"); mix(f & FL); }
#define IMM64(ins, k) { u64 a = x, f; __asm__ volatile(ins " $" #k ",%0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
#define IMM32(ins, k) { uint32_t a = (uint32_t)x; u64 f; __asm__ volatile(ins " $" #k ",%k0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
static const char tbl[] = "rip-relative";
int main(void) {
  for (int i = 0; i < 300000; i++) {
    u64 x = rnd(), y = rnd();
    if (i & 1) y = x;                    /* zero results, equal compares */
    if (i % 3 == 0) y &= 0xff;
    if (i % 5 == 0) x = 0x8000000000000000ull + (i & 7);
    if (i % 7 == 0) x = 0x7fffffffu + (i & 3);
    OP64("addq") OP64("subq") OP64("andq") OP64("orq") OP64("xorq")
    OP32("addl") OP32("subl") OP32("andl") OP32("orl") OP32("xorl")
    CMP64("cmpq") CMP64("testq")
    { u64 f; __asm__ volatile("cmpl %k1,%k2\n\tpushfq\n\tpopq %0" : "=r"(f) : "r"(y), "r"(x) : "cc"); mix(f & FL); }
    IMM64("addq", 0x7f) IMM64("subq", -128) IMM64("andq", 0x7ff0) IMM64("xorq", -1) IMM64("cmpq", 100) IMM64("orq", 0x12345678)
    IMM32("addl", 0x7fffffff) IMM32("subl", 1) IMM32("cmpl", -5)
    { u64 a; __asm__ volatile("movq %1,%0" : "=r"(a) : "r"(x)); mix(a); }
    { uint32_t a; __asm__ volatile("movl %k1,%0" : "=r"(a) : "r"(x)); mix(a); }
    { u64 a = x; __asm__ volatile("movl $0x89abcdef,%k0" : "+r"(a)); mix(a); }   /* zero-extends */
    { u64 a; __asm__ volatile("movabsq $0x123456789abcdef0,%0" : "=r"(a)); mix(a); }
    { u64 a; __asm__ volatile("leaq 0x10(%1,%2,4),%0" : "=r"(a) : "r"(x), "r"(y)); mix(a); }
    { u64 a; __asm__ volatile("leaq -8(%1),%0" : "=r"(a) : "r"(x)); mix(a); }
    { uint32_t a; __asm__ volatile("leal 3(%q1,%q2,8),%0" : "=r"(a) : "r"(x), "r"(y)); mix(a); }
    { u64 a; __asm__ volatile("leaq (,%1,2),%0" : "=r"(a) : "r"(y)); mix(a); }
    { const char *p; __asm__ volatile("leaq %1,%0" : "=r"(p) : "m"(tbl)); mix(*p); }
    /* every jcc condition, signed and unsigned, through C compares */
    long long sx = (long long)x, sy = (long long)y;
    mix((sx < sy) | (sx <= sy) << 1 | (sx > sy) << 2 | (sx >= sy) << 3 | (x < y) << 4 |
        (x <= y) << 5 | (x > y) << 6 | (x >= y) << 7 | (x == y) << 8 | (sx < 0) << 9);
    if ((int)x < (int)y) mix(1); else mix(2);
    if (__builtin_add_overflow_p(sx, sy, (long long)0)) mix(3);
  }
  printf("alu hash %016llx\n", (unsigned long long)H);
  return 0;
}
