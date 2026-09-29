#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/utsname.h>
int main(int argc, char **argv) {
  struct utsname u; uname(&u);
  printf("hello from x86-64! machine=%s pid=%d argc=%d\n", u.machine, getpid(), argc);
  for (int i = 1; i < argc; i++) printf("  argv[%d]=%s\n", i, argv[i]);
  char *p = malloc(64 << 20); memset(p, 7, 64 << 20);
  unsigned long s = 0; for (long i = 0; i < (64 << 20); i += 4096) s += p[i];
  printf("64MB heap ok, sum=%lu\n", s);
  return 0;
}
