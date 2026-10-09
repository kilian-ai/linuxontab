/* differential test for wasmjit's shifts/rotates, test/not/neg, imul32,
   setcc/cmovcc, cbw..cqo, push imm, leave: same hash under old and new Blink */
#include <stdint.h>
#include <stdio.h>
typedef uint64_t u64; typedef int64_t i64;
static u64 s = 0x082efa98ec4e6c89ull;
static u64 rnd(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static u64 H = 1469598103934665603ull;
static void mix(u64 v) { H = (H ^ v) * 1099511628211ull; }
#define FL 0x8d5ull
#define SH(ins, cnt) { u64 a = x, f; __asm__ volatile(ins " %b2,%0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : "c"(cnt) : "cc"); mix(a); mix(f & FL); }
#define SH32(ins, cnt) { u64 a = x, f; __asm__ volatile(ins " %b2,%k0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : "c"(cnt) : "cc"); mix(a); mix(f & FL); }
#define SHI(ins, k) { u64 a = x, f; __asm__ volatile(ins " $" #k ",%0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
#define SHI32(ins, k) { u64 a = x, f; __asm__ volatile(ins " $" #k ",%k0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
#define UN(ins) { u64 a = x, f; __asm__ volatile(ins " %0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
#define UN32(ins) { u64 a = x, f; __asm__ volatile(ins " %k0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
__attribute__((noinline, optimize("no-omit-frame-pointer"))) static u64 framed(u64 a, int d) {
  volatile u64 loc[3] = {a, a ^ d, a + d};          /* push rbp / leave */
  return d ? framed(loc[d % 3] * 3, d - 1) + loc[0] : a;
}
int main(void) {
  static u64 cell[8];
  for (int i = 0; i < 200000; i++) {
    u64 x = rnd(), y = rnd(), f;
    int c = (int)(y & 127);                            /* counts incl. 0, > width */
    if (i % 5 == 0) x = 0x8000000000000000ull >> (i & 3);
    if (i % 7 == 0) x = 0;
    SH("shlq", c) SH("shrq", c) SH("sarq", c) SH("rolq", c) SH("rorq", c)
    SH32("shll", c) SH32("shrl", c) SH32("sarl", c) SH32("roll", c) SH32("rorl", c)
    SHI("shlq", 1) SHI("shrq", 63) SHI("sarq", 7) SHI("rolq", 13) SHI("rorq", 1)
    SHI32("shll", 31) SHI32("shrl", 1) SHI32("sarl", 31) SHI32("roll", 1) SHI32("rorl", 5)
    SHI("shlq", 64) SHI32("sarl", 32)                  /* masked to 0: no flags */
    { u64 a = x; __asm__ volatile("salq %0" : "+r"(a) : : "cc"); mix(a); }
    UN("negq") UN32("negl") UN("notq") UN32("notl")
    { u64 a = x, f2; __asm__ volatile("negb %b0\n\tpushfq\n\tpopq %1" : "+q"(a), "=r"(f2) : : "cc"); mix(a); mix(f2 & FL); }
    { u64 a = x; __asm__ volatile("testq $0x10203,%1\n\tpushfq\n\tpopq %0" : "=r"(f) : "r"(a) : "cc"); mix(f & FL); }
    { u64 a = x; __asm__ volatile("testb $0x81,%b1\n\tpushfq\n\tpopq %0" : "=r"(f) : "q"(a) : "cc"); mix(f & FL); }
    __asm__ volatile("shlq $3,%0" : "+m"(cell[i & 7])); mix(cell[i & 7]);
    __asm__ volatile("negq %0" : "+m"(cell[(i + 1) & 7])); mix(cell[(i + 1) & 7]);
    __asm__ volatile("testl $0x8000,%1\n\tpushfq\n\tpopq %0" : "=r"(f) : "m"(*(uint32_t *)&cell[(i + 2) & 7]) : "cc"); mix(f & FL);
    cell[(i + 3) & 7] = x;
    /* imul 32 */
    { u64 a = x; __asm__ volatile("imull %k2,%k0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : "r"(y) : "cc"); mix(a); mix(f & 0x801); }
    { u64 a; __asm__ volatile("imull $-3,%k2,%k0\n\tpushfq\n\tpopq %1" : "=r"(a), "=r"(f) : "r"(x) : "cc"); mix(a); mix(f & 0x801); }
    { u64 a; __asm__ volatile("imull $100000,%2,%k0\n\tpushfq\n\tpopq %1" : "=r"(a), "=r"(f) : "m"(*(uint32_t *)&cell[(i + 4) & 7]) : "cc"); mix(a); mix(f & 0x801); }
    /* setcc / cmovcc through compares */
    i64 sx = (i64)x, sy = (i64)y;
    mix((sx < sy) + 2 * (x < y) + 4 * (sx >= sy) + 8 * (x == y) + 16 * (sx <= sy) + 32 * (x > y));
    mix(sx < sy ? x : y); mix((int)x > (int)y ? (u64)(uint32_t)x : y);
    { u64 a = x; __asm__ volatile("cmpq %2,%1\n\tcmovlq %2,%0" : "+r"(a) : "r"(x), "r"(y) : "cc"); mix(a); }
    { u64 a = x; __asm__ volatile("cmpl %k2,%k1\n\tcmovbel %k2,%k0" : "+r"(a) : "r"(x), "r"(y) : "cc"); mix(a); }  /* 32-bit: upper cleared either way */
    { uint8_t b; __asm__ volatile("cmpq %1,%2\n\tseto %0" : "=q"(b) : "r"(x), "r"(y) : "cc"); mix(b); }
    __asm__ volatile("cmpq %1,%2\n\tsetg %0" : "=m"(*(uint8_t *)&cell[(i + 5) & 7]) : "r"(x), "r"(y) : "cc"); mix(cell[(i + 5) & 7]);
    /* cbw..cqo */
    { u64 a = x; __asm__ volatile("cltq" : "+a"(a)); mix(a); }
    { u64 a = x; __asm__ volatile("cwtl" : "+a"(a)); mix(a); }
    { u64 a = x; __asm__ volatile("cbtw" : "+a"(a)); mix(a); }
    { u64 a = x, d = y; __asm__ volatile("cqto" : "+a"(a), "+d"(d)); mix(d); }
    { u64 a = x, d = y; __asm__ volatile("cltd" : "+a"(a), "+d"(d)); mix(d); }
    { u64 a = x, d = y; __asm__ volatile("cwtd" : "+a"(a), "+d"(d)); mix(d); }
    mix((u64)((i64)x / (i64)(y | 1)));                  /* cqo + idiv */
    /* push imm */
    { u64 g; __asm__ volatile("pushq $-5\n\tpopq %0" : "=r"(g)); mix(g); }
    { u64 g; __asm__ volatile("pushq $0x12345678\n\tpopq %0" : "=r"(g)); mix(g); }
    if ((i & 127) == 0) mix(framed(x, 12));
    __asm__ volatile("nopl 0x0(%%rax,%%rax,1)\n\tnopw 0x0(%%rax,%%rax,1)" : : : );
  }
  printf("ops2 hash %016llx\n", (unsigned long long)H);
  return 0;
}
