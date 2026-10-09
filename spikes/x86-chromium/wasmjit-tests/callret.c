/* differential test for wasmjit's call/ret and 0xFF call/jmp/push:
   same hash under old and new Blink */
#include <stdint.h>
#include <stdio.h>
typedef uint64_t u64;
static u64 s = 0xa4093822299f31d0ull;
static u64 rnd(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static u64 H = 1469598103934665603ull;
static void mix(u64 v) { H = (H ^ v) * 1099511628211ull; }
__attribute__((noinline)) static u64 f0(u64 x) { return x * 3 + 1; }
__attribute__((noinline)) static u64 f1(u64 x) { return x ^ (x >> 7); }
__attribute__((noinline)) static u64 f2(u64 x) { return x + 0x9e37; }
__attribute__((noinline)) static u64 f3(u64 x) { return ~x; }
static u64 (*const tbl[4])(u64) = {f0, f1, f2, f3};
static u64 (*vt[4])(u64);
__attribute__((noinline)) static u64 rec(u64 x, int d) { return d ? rec(x * 5 + d, d - 1) ^ d : x; }
__attribute__((noinline)) static u64 sw(u64 x, int k) {
  switch (k & 15) {               /* jump table: jmp *tbl(,%rax,8) */
    case 0: return x + 1; case 1: return x * 2; case 2: return x ^ 0x55; case 3: return x - 9;
    case 4: return x << 3; case 5: return x >> 2; case 6: return ~x; case 7: return x * 7;
    case 8: return x + 100; case 9: return x | 1; case 10: return x & 0xfff; case 11: return x - 1;
    case 12: return x * x; case 13: return x ^ (x << 5); case 14: return 42; default: return x;
  }
}
int main(void) {
  for (int k = 0; k < 4; k++) vt[k] = tbl[3 - k];
  for (int i = 0; i < 200000; i++) {
    u64 x = rnd();
    u64 (*volatile fp)(u64) = tbl[i & 3];
    mix(fp(x));                                 /* call *%reg */
    mix(vt[(i >> 2) & 3](x));                   /* call *mem (via table) */
    mix(sw(x, i));
    if ((i & 63) == 0) mix(rec(x, 40));
    { u64 r; __asm__ volatile("call *%1" : "=a"(r) : "m"(vt[i & 3]), "D"(x) : "rcx", "rdx", "rsi", "r8", "r9", "r10", "r11", "memory"); mix(r); }
    { u64 v = x, got;                           /* push (mem) / pop */
      __asm__ volatile("pushq %1\n\tpopq %0" : "=r"(got) : "m"(v)); mix(got); }
    { u64 got; __asm__ volatile("pushq %1\n\tpopq %0" : "=r"(got) : "r"(x ^ i)); mix(got); }
    { u64 r = 0;                                /* jmp *%reg */
      __asm__ volatile("leaq 1f(%%rip),%%rax\n\tjmp *%%rax\n\tmovq $1,%0\n1:\taddq $2,%0" : "+r"(r) : : "rax"); mix(r); }
  }
  printf("callret hash %016llx\n", (unsigned long long)H);
  return 0;
}
