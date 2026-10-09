/* code that changes under translation: a generated function is called hot
   (translated, chained to), then rewritten through mprotect RW -> RX; the
   new code must run. Also munmap + mmap of new code at the same address. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
typedef int (*fn)(int);
static void emit(uint8_t *p, int k) {     /* lea eax,[rdi+k]; ret */
  uint8_t c[] = {0x8d, 0x87, (uint8_t)k, (uint8_t)(k >> 8), (uint8_t)(k >> 16), (uint8_t)(k >> 24), 0xc3};
  memcpy(p, c, sizeof c);
}
__attribute__((noinline)) static long hot(fn f, int n) {   /* the chained caller */
  long s = 0;
  for (int i = 0; i < n; i++) s += f(i);
  return s;
}
int main(void) {
  long total = 0;
  uint8_t *p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  for (int round = 1; round <= 6; round++) {
    mprotect(p, 4096, PROT_READ | PROT_WRITE);
    emit(p, round * 1000);
    mprotect(p, 4096, PROT_READ | PROT_EXEC);
    long s = hot((fn)p, 20000);
    long want = 20000L * round * 1000 + 20000L * 19999 / 2;
    printf("round %d %s\n", round, s == want ? "ok" : "WRONG");
    total += s != want;
  }
  for (int round = 1; round <= 3; round++) {          /* unmap, map new code */
    munmap(p, 4096);
    p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    emit(p, -round);
    mprotect(p, 4096, PROT_READ | PROT_EXEC);
    long s = hot((fn)p, 20000);
    long want = 20000L * -round + 20000L * 19999 / 2;
    printf("remap %d %s\n", round, s == want ? "ok" : "WRONG");
    total += s != want;
  }
  printf("smc %s\n", total ? "FAIL" : "OK");
  return total != 0;
}
