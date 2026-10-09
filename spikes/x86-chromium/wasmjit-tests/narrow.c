/* differential test for wasmjit's 8/16-bit forms, movzx/movsx/movsxd,
   inc/dec and the al/eax-imm forms: same hash under old and new Blink */
#include <stdint.h>
#include <stdio.h>
typedef uint64_t u64;
static u64 s = 0x13198a2e03707344ull;
static u64 rnd(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static u64 H = 1469598103934665603ull;
static void mix(u64 v) { H = (H ^ v) * 1099511628211ull; }
#define FL 0x8d5ull
int main(void) {
  static u64 cell[16];
  for (int i = 0; i < 200000; i++) {
    u64 x = rnd(), y = rnd(), f;
    if (i & 1) y = x ^ (i & 0x81);
    if (i % 6 == 0) x |= 0xff;            /* byte overflow / carries */
    cell[i & 15] = y;
    /* byte ops on legacy high bytes (no REX): ah/bh via "Q" constraint */
    { u64 a = x, b = y; __asm__ volatile("addb %%bh,%%ah\n\tpushfq\n\tpopq %2" : "+a"(a), "+b"(b), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
    { u64 a = x, b = y; __asm__ volatile("subb %%bl,%%ah\n\tpushfq\n\tpopq %2" : "+a"(a), "+b"(b), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
    { u64 a = x, b = y; __asm__ volatile("xorb %%ah,%%bl\n\tcmpb %%bh,%%al\n\tpushfq\n\tpopq %2" : "+a"(a), "+b"(b), "=r"(f) : : "cc"); mix(a ^ b); mix(f & FL); }
    /* REX byte registers: sil/dil */
    { u64 a = x, b = y; __asm__ volatile("addb %%sil,%%dil\n\tpushfq\n\tpopq %2" : "+D"(a), "+S"(b), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
    { u64 a = x; __asm__ volatile("movb %%dl,%%sil" : "+S"(a) : "d"(y)); mix(a); }
    { u64 a = x; __asm__ volatile("movb $0x9c,%%ah" : "+a"(a)); mix(a); }
    { u64 a = x; __asm__ volatile("movb $0x5a,%%r9b" : "+r"(a)); mix(a); }
    /* 16-bit: upper bits preserved */
    { u64 a = x; __asm__ volatile("addw %w2,%w0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : "r"(y) : "cc"); mix(a); mix(f & FL); }
    { u64 a = x; __asm__ volatile("movw %w1,%w0" : "+r"(a) : "r"(y)); mix(a); }
    { u64 a = x; __asm__ volatile("movw $0x8001,%w0" : "+r"(a)); mix(a); }
    { u64 a = x; __asm__ volatile("cmpw $-2,%w1\n\tpushfq\n\tpopq %0" : "=r"(f) : "r"(a) : "cc"); mix(f & FL); }
    /* movzx / movsx / movsxd, register and memory */
    { u64 a; __asm__ volatile("movzbl %b1,%k0" : "=r"(a) : "r"(x)); mix(a); }
    { u64 a; __asm__ volatile("movzwl %w1,%k0" : "=r"(a) : "r"(x)); mix(a); }
    { u64 a; __asm__ volatile("movsbq %b1,%0" : "=r"(a) : "r"(x)); mix(a); }
    { u64 a; __asm__ volatile("movsbl %b1,%k0" : "=r"(a) : "r"(x)); mix(a); }
    { u64 a; __asm__ volatile("movswq %w1,%0" : "=r"(a) : "r"(x)); mix(a); }
    { u64 a; __asm__ volatile("movslq %k1,%0" : "=r"(a) : "r"(x)); mix(a); }
    { u64 a = x; __asm__ volatile("movsbw %b1,%w0" : "+r"(a) : "r"(y)); mix(a); }
    { u64 a, b = x; __asm__ volatile("movzbl %h1,%k0" : "=Q"(a) : "Q"(b)); mix(a); }    /* from ah..dh */
    { u64 a; __asm__ volatile("movzbl %1,%k0" : "=r"(a) : "m"(*(uint8_t *)&cell[(i * 3) & 15])); mix(a); }
    { u64 a; __asm__ volatile("movsbq %1,%0" : "=r"(a) : "m"(*(uint8_t *)&cell[(i * 5) & 15])); mix(a); }
    { u64 a; __asm__ volatile("movzwl %1,%k0" : "=r"(a) : "m"(*(uint16_t *)&cell[(i * 7) & 15])); mix(a); }
    { u64 a; __asm__ volatile("movswl %1,%k0" : "=r"(a) : "m"(*(uint16_t *)&cell[(i * 9) & 15])); mix(a); }
    { u64 a; __asm__ volatile("movslq %1,%0" : "=r"(a) : "m"(*(uint32_t *)&cell[(i * 11) & 15])); mix(a); }
    /* byte/word memory forms */
    __asm__ volatile("addb %1,%0" : "+m"(*(uint8_t *)&cell[i & 15]) : "q"((uint8_t)x)); mix(cell[i & 15]);
    __asm__ volatile("subw %1,%0\n\t" : "+m"(*(uint16_t *)&cell[(i + 1) & 15]) : "r"((uint16_t)x)); mix(cell[(i + 1) & 15]);
    __asm__ volatile("movb $0x7f,%0" : "=m"(*(uint8_t *)&cell[(i + 2) & 15])); mix(cell[(i + 2) & 15]);
    __asm__ volatile("movw %1,%0" : "=m"(*(uint16_t *)&cell[(i + 3) & 15]) : "r"((uint16_t)y)); mix(cell[(i + 3) & 15]);
    __asm__ volatile("cmpb $0x40,%1\n\tpushfq\n\tpopq %0" : "=r"(f) : "m"(*(uint8_t *)&cell[(i + 4) & 15]) : "cc"); mix(f & FL);
    __asm__ volatile("testb %1,%2\n\tpushfq\n\tpopq %0" : "=r"(f) : "q"((uint8_t)x), "m"(*(uint8_t *)&cell[(i + 5) & 15]) : "cc"); mix(f & FL);
    { uint8_t b; __asm__ volatile("movb %1,%0" : "=q"(b) : "m"(*(uint8_t *)&cell[(i + 6) & 15])); mix(b); }
    /* inc/dec: CF must survive */
    { u64 a = x; __asm__ volatile("stc\n\tincq %0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
    { u64 a = x; __asm__ volatile("clc\n\tdecl %k0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
    { u64 a = x; __asm__ volatile("incb %b0\n\tpushfq\n\tpopq %1" : "+q"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
    { u64 a = x; __asm__ volatile("decw %w0\n\tpushfq\n\tpopq %1" : "+r"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
    __asm__ volatile("incq %0" : "+m"(cell[(i + 7) & 15])); mix(cell[(i + 7) & 15]);
    __asm__ volatile("decb %0\n\tpushfq\n\tpopq %1" : "+m"(*(uint8_t *)&cell[(i + 8) & 15]), "=r"(f) : : "cc"); mix(cell[(i + 8) & 15]); mix(f & FL);
    /* al / eax / rax immediate forms */
    { u64 a = x; __asm__ volatile("addb $0x81,%%al\n\tpushfq\n\tpopq %1" : "+a"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
    { u64 a = x; __asm__ volatile("subl $0x12345,%%eax\n\tpushfq\n\tpopq %1" : "+a"(a), "=r"(f) : : "cc"); mix(a); mix(f & FL); }
    { u64 a = x; __asm__ volatile("andq $-256,%%rax" : "+a"(a)); mix(a); }
    { u64 a = x; __asm__ volatile("cmpl $1000,%%eax\n\tpushfq\n\tpopq %0" : "=r"(f) : "a"(a) : "cc"); mix(f & FL); }
    { u64 a = x; __asm__ volatile("testb $0x80,%%al\n\tpushfq\n\tpopq %0" : "=r"(f) : "a"(a) : "cc"); mix(f & FL); }
    { u64 a = x; __asm__ volatile("testl $0x10001,%%eax\n\tpushfq\n\tpopq %0" : "=r"(f) : "a"(a) : "cc"); mix(f & FL); }
    { u64 a = x; __asm__ volatile("cmpb $5,%%al\n\tpushfq\n\tpopq %0" : "=r"(f) : "a"(a) : "cc"); mix(f & FL); }
  }
  printf("narrow hash %016llx\n", (unsigned long long)H);
  return 0;
}
