#include <stdio.h>
#include <time.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
int main(void){
  double t0=now(); long n=0;
  for (long i=2;i<200000;i++){ int p=1; for(long d=2; d*d<=i; d++) if(i%d==0){p=0;break;} n+=p; }
  double t1=now();
  printf("primes<200000: %ld in %.3f s\n", n, t1-t0);
  return 0;
}
