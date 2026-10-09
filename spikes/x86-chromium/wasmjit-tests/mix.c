/* mixed integer workload for the translator: hashing, sorting, string ops */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static unsigned fnv(const unsigned char *p, size_t n){unsigned h=2166136261u;while(n--)h=(h^*p++)*16777619u;return h;}
static int cmp(const void *a,const void *b){unsigned x=*(const unsigned*)a,y=*(const unsigned*)b;return x<y?-1:x>y;}
int main(void){
  double t0=now();
  static unsigned char buf[1<<16]; unsigned s=1;
  for(int i=0;i<(int)sizeof buf;i++){s=s*1103515245u+12345u;buf[i]=s>>16;}
  unsigned h=0; for(int r=0;r<40;r++) h^=fnv(buf,sizeof buf)+r;
  static unsigned a[20000]; for(int i=0;i<20000;i++){s=s*1103515245u+12345u;a[i]=s;}
  qsort(a,20000,sizeof a[0],cmp);
  char str[256]; size_t tot=0; for(int i=0;i<20000;i++){snprintf(str,sizeof str,"item-%d-%u",i,a[i%20000]);tot+=strlen(str);}
  double t1=now();
  printf("mix: h=%08x a0=%u amid=%u tot=%zu in %.3f s\n",h,a[0],a[10000],tot,t1-t0);
  return 0;
}
