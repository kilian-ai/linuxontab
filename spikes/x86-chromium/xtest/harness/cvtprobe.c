#include <immintrin.h>
#include <stdio.h>
#include <math.h>
int main(void) {
  float in[] = {0.f, 1.5f, -1.5f, 2.5f, 255.9f, 256.f, 510.49f, -0.7f, 1e9f, 3e9f, -3e9f, 1e20f, -1e20f, NAN, INFINITY, 12345.678f};
  for (unsigned i = 0; i < sizeof in / sizeof *in; i++) {
    float f = in[i];
    __m128 v = _mm_set1_ps(f);
    __m128i a = _mm_cvtps_epi32(v), b = _mm_cvttps_epi32(v);
    printf("%-10g ss2si=%d tss2si=%d ss2si64=%lld tss2si64=%lld ps2dq=%d tps2dq=%d lrintf=%ld sd2si=%d tsd2si=%d\n",
           f, _mm_cvtss_si32(v), _mm_cvttss_si32(v), (long long)_mm_cvtss_si64(v),
           (long long)_mm_cvttss_si64(v), _mm_cvtsi128_si32(a), _mm_cvtsi128_si32(b),
           lrintf(f), _mm_cvtsd_si32(_mm_set_sd(f)), _mm_cvttsd_si32(_mm_set_sd(f)));
  }
  return 0;
}
