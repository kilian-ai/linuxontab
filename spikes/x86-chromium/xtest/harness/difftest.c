// Differential test for Blink: hash the results of many x86 SSE/integer
// operations over pseudo-random inputs. Run under two Blink builds (native
// 64-bit host vs wasm32 host) and diff the per-op lines.
//   gcc -O1 -mssse3 -msse4.1 -mpopcnt -static -o difftest difftest.c
#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) {
  rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs;
}
static uint64_t H;
static void mix(const void *p, size_t n) {
  const unsigned char *b = p;
  for (size_t i = 0; i < n; i++) { H ^= b[i]; H *= 0x100000001b3ull; }
}
static __m128i ri(void) { return _mm_set_epi64x(rnd(), rnd()); }
static float rf(void) {
  uint64_t r = rnd();
  switch (r & 7) {
    case 0: return (float)(int32_t)(r >> 32);
    case 1: return ((int32_t)(r >> 32)) / 65536.0f;
    case 2: return (float)((r >> 40) & 0xfff) - 2048.0f + ((r >> 8) & 255) / 256.0f;
    case 3: { uint32_t u = r >> 32; float f; memcpy(&f, &u, 4); return isnan(f) ? 1.5f : f; }
    default: return ((int32_t)(r >> 32)) / 1048576.0f;
  }
}
static double rd(void) { return (double)rf() * (1 + (rnd() & 0xff) / 1e3); }
static __m128 rps(void) { return _mm_set_ps(rf(), rf(), rf(), rf()); }
static __m128d rpd(void) { return _mm_set_pd(rd(), rd()); }

#define N 4000
#define T(name, expr, type)                                  \
  do {                                                       \
    H = 0xcbf29ce484222325ull; rs = 0x9E3779B97F4A7C15ull;   \
    for (int i = 0; i < N; i++) { type r_ = (expr); mix(&r_, sizeof r_); } \
    printf("%-28s %016llx\n", name, (unsigned long long)H); fflush(stdout); \
  } while (0)
#define TI(name, expr) T(name, expr, __m128i)
#define TP(name, expr) T(name, expr, __m128)
#define TD(name, expr) T(name, expr, __m128d)

__attribute__((noinline)) static uint64_t mulhi(uint64_t a, uint64_t b) {
  return (uint64_t)(((unsigned __int128)a * b) >> 64);
}
__attribute__((noinline)) static int64_t smulhi(int64_t a, int64_t b) {
  return (int64_t)(((__int128)a * b) >> 64);
}
__attribute__((noinline)) static uint64_t udiv128(uint64_t hi, uint64_t lo, uint64_t d) {
  uint64_t q, r;
  hi %= d ? d : 1;
  if (!d) d = 1;
  __asm__("divq %4" : "=a"(q), "=d"(r) : "a"(lo), "d"(hi), "rm"(d));
  return q ^ r;
}
__attribute__((noinline)) static int64_t sdiv128(int64_t a, int64_t d) {
  int64_t q, r;
  if (!d || (d == -1)) d = 7;
  __asm__("cqo; idivq %3" : "=a"(q), "=d"(r) : "a"(a), "rm"(d));
  return q ^ r;
}
__attribute__((noinline)) static uint64_t shld64(uint64_t a, uint64_t b, uint8_t c) {
  __asm__("shldq %%cl, %2, %0" : "+r"(a) : "c"(c), "r"(b)); return a;
}
__attribute__((noinline)) static uint64_t shrd64(uint64_t a, uint64_t b, uint8_t c) {
  __asm__("shrdq %%cl, %2, %0" : "+r"(a) : "c"(c), "r"(b)); return a;
}
__attribute__((noinline)) static uint64_t lockops(uint64_t a, uint64_t b) {
  uint64_t v = a, old;
  __asm__ volatile("lock btsq %1, %0" : "+m"(v) : "r"(b & 63));
  __asm__ volatile("lock btrq $5, %0" : "+m"(v));
  __asm__ volatile("lock btcq %1, %0" : "+m"(v) : "r"((b >> 8) & 63));
  __asm__ volatile("lock xaddq %1, %0" : "+m"(v), "=r"(old) : "1"(b));
  __asm__ volatile("lock andq %1, %0" : "+m"(v) : "r"(a | 1));
  __asm__ volatile("lock orq %1, %0" : "+m"(v) : "r"(b >> 3));
  __asm__ volatile("lock xorq %1, %0" : "+m"(v) : "r"(a));
  __asm__ volatile("lock incq %0" : "+m"(v));
  __asm__ volatile("lock negq %0" : "+m"(v));
  uint64_t exp = v, nv = v ^ b;
  __atomic_compare_exchange_n(&v, &exp, nv, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  return v ^ old;
}
__attribute__((noinline)) static uint32_t lockops32(uint32_t a, uint32_t b) {
  uint32_t v = a;
  __asm__ volatile("lock btsl %1, %0" : "+m"(v) : "r"(b & 31));
  __asm__ volatile("lock btrl $3, %0" : "+m"(v));
  __asm__ volatile("lock addl %1, %0" : "+m"(v) : "r"(b));
  return v;
}

__attribute__((target("sse4.1"))) static void sse41(void);
__attribute__((target("bmi,bmi2,pclmul,adx,lzcnt"))) static void bmi(void) {
  T("shlx64", ({ uint64_t x = rnd(), c = rnd(), r; __asm__("shlxq %2, %1, %0" : "=r"(r) : "r"(x), "r"(c)); r; }), uint64_t);
  T("shrx64", ({ uint64_t x = rnd(), c = rnd(), r; __asm__("shrxq %2, %1, %0" : "=r"(r) : "r"(x), "r"(c)); r; }), uint64_t);
  T("sarx64", (int64_t)({ int64_t x = rnd(); uint64_t c = rnd(); int64_t r; __asm__("sarxq %2, %1, %0" : "=r"(r) : "r"(x), "r"(c)); r; }), int64_t);
  T("shlx32", ({ uint32_t x = rnd(), c = rnd(), r; __asm__("shlxl %2, %1, %0" : "=r"(r) : "r"(x), "r"(c)); r; }), uint32_t);
  T("shrx32", ({ uint32_t x = rnd(), c = rnd(), r; __asm__("shrxl %2, %1, %0" : "=r"(r) : "r"(x), "r"(c)); r; }), uint32_t);
  T("rorx64", ({ uint64_t x = rnd(), r; __asm__("rorxq $13, %1, %0" : "=r"(r) : "r"(x)); r; }), uint64_t);
  T("rorx32", ({ uint32_t x = rnd(), r; __asm__("rorxl $7, %1, %0" : "=r"(r) : "r"(x)); r; }), uint32_t);
  T("pdep64", _pdep_u64(rnd(), rnd()), uint64_t);
  T("pext64", _pext_u64(rnd(), rnd()), uint64_t);
  T("pdep32", _pdep_u32(rnd(), rnd()), uint32_t);
  T("pext32", _pext_u32(rnd(), rnd()), uint32_t);
  T("bzhi64", _bzhi_u64(rnd(), rnd() & 127), uint64_t);
  T("bzhi32", _bzhi_u32(rnd(), rnd() & 63), uint32_t);
  T("mulx64", ({ unsigned long long hi; unsigned long long lo = _mulx_u64(rnd(), rnd(), &hi); lo ^ hi * 3; }), unsigned long long);
  T("adcx64", ({ unsigned long long o; unsigned char c = _addcarryx_u64(rnd() & 1, rnd(), rnd(), &o); o ^ c; }), unsigned long long);
  TI("pclmul00", _mm_clmulepi64_si128(ri(), ri(), 0x00));
  TI("pclmul11", _mm_clmulepi64_si128(ri(), ri(), 0x11));
  TI("pclmul01", _mm_clmulepi64_si128(ri(), ri(), 0x01));
}
int main(void) {
  bmi();
  // --- integer scalar ---
  T("mulhi64", mulhi(rnd(), rnd()), uint64_t);
  T("smulhi64", smulhi(rnd(), rnd()), int64_t);
  T("udiv128", udiv128(rnd(), rnd(), rnd() >> (rnd() & 63)), uint64_t);
  T("sdiv128", sdiv128(rnd(), (int64_t)rnd() >> (rnd() & 63)), int64_t);
  T("shld64", shld64(rnd(), rnd(), rnd()), uint64_t);
  T("shrd64", shrd64(rnd(), rnd(), rnd()), uint64_t);
  T("ctz64", __builtin_ctzll(rnd() | 1ull << 63), int);
  T("clz64", __builtin_clzll(rnd() | 1), int);
  T("popcnt64", __builtin_popcountll(rnd()), int);
  T("bswap64", __builtin_bswap64(rnd()), uint64_t);
  T("rotl64", ({ uint64_t x = rnd(); int c = rnd() & 63; (x << c) | (x >> ((64 - c) & 63)); }), uint64_t);
  T("sar64", ({ int64_t x = rnd(); x >> (rnd() & 63); }), int64_t);
  T("imul64", (int64_t)rnd() * (int64_t)rnd(), int64_t);
  T("lockops64", lockops(rnd(), rnd()), uint64_t);
  T("lockops32", lockops32(rnd(), rnd()), uint32_t);
  // --- scalar float conversions ---
  T("cvtsi64_ss", _mm_cvtss_f32(_mm_cvtsi64_ss(_mm_setzero_ps(), (int64_t)rnd() >> (rnd() & 63))), float);
  T("cvtsi32_ss", _mm_cvtss_f32(_mm_cvtsi32_ss(_mm_setzero_ps(), (int32_t)rnd())), float);
  T("cvtsi64_sd", _mm_cvtsd_f64(_mm_cvtsi64_sd(_mm_setzero_pd(), (int64_t)rnd() >> (rnd() & 63))), double);
  T("cvtss_si32", _mm_cvtss_si32(_mm_set_ss(rf())), int);
  T("cvttss_si32", _mm_cvttss_si32(_mm_set_ss(rf())), int);
  T("cvtss_si64", _mm_cvtss_si64(_mm_set_ss(rf())), long long);
  T("cvttss_si64", _mm_cvttss_si64(_mm_set_ss(rf())), long long);
  T("cvtsd_si32", _mm_cvtsd_si32(_mm_set_sd(rd())), int);
  T("cvttsd_si32", _mm_cvttsd_si32(_mm_set_sd(rd())), int);
  T("cvtsd_si64", _mm_cvtsd_si64(_mm_set_sd(rd())), long long);
  T("cvttsd_si64", _mm_cvttsd_si64(_mm_set_sd(rd())), long long);
  T("cvtss_sd", _mm_cvtsd_f64(_mm_cvtss_sd(_mm_setzero_pd(), _mm_set_ss(rf()))), double);
  T("cvtsd_ss", _mm_cvtss_f32(_mm_cvtsd_ss(_mm_setzero_ps(), _mm_set_sd(rd()))), float);
  T("floorf", floorf(rf()), float);
  T("ceilf", ceilf(rf()), float);
  T("roundf", roundf(rf()), float);
  T("lrintf", lrintf(rf() / 65536), long);
  T("floor", floor(rd()), double);
  T("sqrtf", sqrtf(fabsf(rf())), float);
  // --- packed float ---
  TP("addps", _mm_add_ps(rps(), rps()));
  TP("subps", _mm_sub_ps(rps(), rps()));
  TP("mulps", _mm_mul_ps(rps(), rps()));
  TP("divps", _mm_div_ps(rps(), rps()));
  TP("minps", _mm_min_ps(rps(), rps()));
  TP("maxps", _mm_max_ps(rps(), rps()));
  TP("sqrtps", _mm_sqrt_ps(_mm_andnot_ps(_mm_set1_ps(-0.f), rps())));
  TP("addss", _mm_add_ss(rps(), rps()));
  TP("mulss", _mm_mul_ss(rps(), rps()));
  TP("minss", _mm_min_ss(rps(), rps()));
  TP("cmpltps", _mm_cmplt_ps(rps(), rps()));
  TP("cmpleps", _mm_cmple_ps(rps(), rps()));
  TP("cmpeqps", _mm_cmpeq_ps(rps(), rps()));
  TP("cmpunordps", _mm_cmpunord_ps(rps(), rps()));
  TP("cmpnltps", _mm_cmpnlt_ps(rps(), rps()));
  TP("shufps", _mm_shuffle_ps(rps(), rps(), 0x9c));
  TP("unpcklps", _mm_unpacklo_ps(rps(), rps()));
  TP("unpckhps", _mm_unpackhi_ps(rps(), rps()));
  TP("movhlps", _mm_movehl_ps(rps(), rps()));
  TP("movlhps", _mm_movelh_ps(rps(), rps()));
  TP("andps", _mm_and_ps(rps(), rps()));
  TP("andnps", _mm_andnot_ps(rps(), rps()));
  T("movmskps", _mm_movemask_ps(rps()), int);
  TI("cvtps2dq", _mm_cvtps_epi32(_mm_mul_ps(rps(), _mm_set1_ps(0.001f))));
  TI("cvttps2dq", _mm_cvttps_epi32(_mm_mul_ps(rps(), _mm_set1_ps(0.001f))));
  TP("cvtdq2ps", _mm_cvtepi32_ps(ri()));
  TD("cvtps2pd", _mm_cvtps_pd(rps()));
  TP("cvtpd2ps", _mm_cvtpd_ps(rpd()));
  TI("cvtpd2dq", _mm_cvtpd_epi32(_mm_mul_pd(rpd(), _mm_set1_pd(0.001))));
  TI("cvttpd2dq", _mm_cvttpd_epi32(_mm_mul_pd(rpd(), _mm_set1_pd(0.001))));
  TD("cvtdq2pd", _mm_cvtepi32_pd(ri()));
  TD("addpd", _mm_add_pd(rpd(), rpd()));
  TD("mulpd", _mm_mul_pd(rpd(), rpd()));
  TD("divpd", _mm_div_pd(rpd(), rpd()));
  TD("minpd", _mm_min_pd(rpd(), rpd()));
  TD("maxpd", _mm_max_pd(rpd(), rpd()));
  TD("sqrtpd", _mm_sqrt_pd(_mm_andnot_pd(_mm_set1_pd(-0.), rpd())));
  TD("cmpltpd", _mm_cmplt_pd(rpd(), rpd()));
  TD("shufpd", _mm_shuffle_pd(rpd(), rpd(), 1));
  TD("unpcklpd", _mm_unpacklo_pd(rpd(), rpd()));
  TD("unpckhpd", _mm_unpackhi_pd(rpd(), rpd()));
  T("movmskpd", _mm_movemask_pd(rpd()), int);
  TD("addsd", _mm_add_sd(rpd(), rpd()));
  TD("minsd", _mm_min_sd(rpd(), rpd()));
  TD("sqrtsd", _mm_sqrt_sd(rpd(), _mm_andnot_pd(_mm_set1_pd(-0.), rpd())));
  // --- SSE2 integer ---
  TI("paddb", _mm_add_epi8(ri(), ri()));
  TI("paddw", _mm_add_epi16(ri(), ri()));
  TI("paddd", _mm_add_epi32(ri(), ri()));
  TI("paddq", _mm_add_epi64(ri(), ri()));
  TI("psubq", _mm_sub_epi64(ri(), ri()));
  TI("paddsb", _mm_adds_epi8(ri(), ri()));
  TI("paddusb", _mm_adds_epu8(ri(), ri()));
  TI("paddsw", _mm_adds_epi16(ri(), ri()));
  TI("paddusw", _mm_adds_epu16(ri(), ri()));
  TI("psubusb", _mm_subs_epu8(ri(), ri()));
  TI("psubsw", _mm_subs_epi16(ri(), ri()));
  TI("pmullw", _mm_mullo_epi16(ri(), ri()));
  TI("pmulhw", _mm_mulhi_epi16(ri(), ri()));
  TI("pmulhuw", _mm_mulhi_epu16(ri(), ri()));
  TI("pmuludq", _mm_mul_epu32(ri(), ri()));
  TI("pmaddwd", _mm_madd_epi16(ri(), ri()));
  TI("psadbw", _mm_sad_epu8(ri(), ri()));
  TI("pavgb", _mm_avg_epu8(ri(), ri()));
  TI("pavgw", _mm_avg_epu16(ri(), ri()));
  TI("pminub", _mm_min_epu8(ri(), ri()));
  TI("pmaxsw", _mm_max_epi16(ri(), ri()));
  TI("pcmpeqb", _mm_cmpeq_epi8(ri(), _mm_or_si128(ri(), _mm_set1_epi8(0x55))));
  TI("pcmpgtb", _mm_cmpgt_epi8(ri(), ri()));
  TI("pcmpgtw", _mm_cmpgt_epi16(ri(), ri()));
  TI("pcmpgtd", _mm_cmpgt_epi32(ri(), ri()));
  TI("pandn", _mm_andnot_si128(ri(), ri()));
  TI("psllw5", _mm_slli_epi16(ri(), 5));
  TI("psrlw3", _mm_srli_epi16(ri(), 3));
  TI("psraw15", _mm_srai_epi16(ri(), 15));
  TI("pslld7", _mm_slli_epi32(ri(), 7));
  TI("psrld9", _mm_srli_epi32(ri(), 9));
  TI("psrad31", _mm_srai_epi32(ri(), 31));
  TI("psllq13", _mm_slli_epi64(ri(), 13));
  TI("psrlq40", _mm_srli_epi64(ri(), 40));
  TI("psllw_reg", _mm_sll_epi16(ri(), _mm_cvtsi32_si128(rnd() & 31)));
  TI("psrad_reg", _mm_sra_epi32(ri(), _mm_cvtsi32_si128(rnd() & 63)));
  TI("psrlq_reg", _mm_srl_epi64(ri(), _mm_cvtsi32_si128(rnd() & 127)));
  TI("pslldq3", _mm_slli_si128(ri(), 3));
  TI("psrldq11", _mm_srli_si128(ri(), 11));
  TI("packsswb", _mm_packs_epi16(ri(), ri()));
  TI("packssdw", _mm_packs_epi32(ri(), ri()));
  TI("packuswb", _mm_packus_epi16(ri(), ri()));
  TI("punpcklbw", _mm_unpacklo_epi8(ri(), ri()));
  TI("punpckhbw", _mm_unpackhi_epi8(ri(), ri()));
  TI("punpcklwd", _mm_unpacklo_epi16(ri(), ri()));
  TI("punpckhwd", _mm_unpackhi_epi16(ri(), ri()));
  TI("punpckldq", _mm_unpacklo_epi32(ri(), ri()));
  TI("punpckhdq", _mm_unpackhi_epi32(ri(), ri()));
  TI("punpcklqdq", _mm_unpacklo_epi64(ri(), ri()));
  TI("punpckhqdq", _mm_unpackhi_epi64(ri(), ri()));
  TI("pshufd", _mm_shuffle_epi32(ri(), 0x4e));
  TI("pshuflw", _mm_shufflelo_epi16(ri(), 0x1b));
  TI("pshufhw", _mm_shufflehi_epi16(ri(), 0xb1));
  T("pmovmskb", _mm_movemask_epi8(ri()), int);
  T("pextrw", _mm_extract_epi16(ri(), 5), int);
  TI("movq", _mm_move_epi64(ri()));
  T("movd_r64", _mm_cvtsi128_si64(ri()), long long);
  // --- SSSE3 ---
  TI("pshufb", _mm_shuffle_epi8(ri(), ri()));
  TI("pabsb", _mm_abs_epi8(ri()));
  TI("pabsw", _mm_abs_epi16(ri()));
  TI("pabsd", _mm_abs_epi32(ri()));
  TI("phaddw", _mm_hadd_epi16(ri(), ri()));
  TI("phaddd", _mm_hadd_epi32(ri(), ri()));
  TI("phsubw", _mm_hsub_epi16(ri(), ri()));
  TI("pmaddubsw", _mm_maddubs_epi16(ri(), ri()));
  TI("pmulhrsw", _mm_mulhrs_epi16(ri(), ri()));
  TI("psignb", _mm_sign_epi8(ri(), ri()));
  TI("palignr5", _mm_alignr_epi8(ri(), ri(), 5));
  TI("palignr13", _mm_alignr_epi8(ri(), ri(), 13));
  sse41();
  puts("done");
  return 0;
}

__attribute__((target("sse4.1"))) static void sse41(void) {
  TI("pblendvb", _mm_blendv_epi8(ri(), ri(), ri()));
  TI("pblendw", _mm_blend_epi16(ri(), ri(), 0xa5));
  TP("blendps", _mm_blend_ps(rps(), rps(), 5));
  TP("blendvps", _mm_blendv_ps(rps(), rps(), rps()));
  TI("pminsb", _mm_min_epi8(ri(), ri()));
  TI("pmaxsd", _mm_max_epi32(ri(), ri()));
  TI("pminud", _mm_min_epu32(ri(), ri()));
  TI("pmaxuw", _mm_max_epu16(ri(), ri()));
  TI("pmulld", _mm_mullo_epi32(ri(), ri()));
  TI("pmuldq", _mm_mul_epi32(ri(), ri()));
  TI("packusdw", _mm_packus_epi32(ri(), ri()));
  TI("pmovzxbw", _mm_cvtepu8_epi16(ri()));
  TI("pmovzxbd", _mm_cvtepu8_epi32(ri()));
  TI("pmovsxwd", _mm_cvtepi16_epi32(ri()));
  TI("pmovsxbw", _mm_cvtepi8_epi16(ri()));
  TI("pmovzxdq", _mm_cvtepu32_epi64(ri()));
  TP("roundps_floor", _mm_floor_ps(rps()));
  TP("roundps_ceil", _mm_ceil_ps(rps()));
  TP("roundps_near", _mm_round_ps(rps(), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC));
  TP("roundps_trunc", _mm_round_ps(rps(), _MM_FROUND_TO_ZERO | _MM_FROUND_NO_EXC));
  TP("roundss_floor", _mm_floor_ss(rps(), rps()));
  TD("roundpd_floor", _mm_floor_pd(rpd()));
  TD("roundsd_floor", _mm_floor_sd(rpd(), rpd()));
  TP("dpps", _mm_dp_ps(rps(), rps(), 0xf1));
  T("pextrb", _mm_extract_epi8(ri(), 9), int);
  T("pextrd", _mm_extract_epi32(ri(), 2), int);
  T("pextrq", _mm_extract_epi64(ri(), 1), long long);
  TI("pinsrb", _mm_insert_epi8(ri(), (int)rnd(), 11));
  TI("pinsrd", _mm_insert_epi32(ri(), (int)rnd(), 1));
  TI("pinsrq", _mm_insert_epi64(ri(), (long long)rnd(), 1));
  T("ptestz", _mm_testz_si128(ri(), _mm_and_si128(ri(), ri())), int);
  TI("pcmpeqq", _mm_cmpeq_epi64(ri(), _mm_or_si128(ri(), ri())));
  TI("phminposuw", _mm_minpos_epu16(ri()));
}
