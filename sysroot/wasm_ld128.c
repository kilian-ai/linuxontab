/* wasm_ld128.c — binary128 long-double compat for the ld80-configured
 * musl sysroot. Link BEFORE -lc in any program that printfs floats
 * (%f/%Lg → frexpl infinite recursion → stack overflow "segfault").
 * Extracted from the redis recipe; see musl-longdouble-ABI notes. */
#include <math.h>

/* clang wasm32 long double = IEEE binary128, but this musl sysroot was built
 * with i386-style bits/float.h (LDBL_MANT_DIG 64 = x87 80-bit). libc's own
 * long-double bit-twiddling therefore reads the WRONG bits: frexpl takes the
 * exponent from the low 16 bits of the high word (ld80's se position), sees 0
 * for every normal value, treats it as subnormal, and recurses forever —
 * printf("%Lg", 1.5L) dies with a call-stack overflow (guest SIGSEGV).
 * Redis prints long doubles (ld2string's "%.17Lg"), so it trips this at boot.
 * Override the three bit-level primitives with correct binary128 versions,
 * linked before -lc. The arithmetic itself (__multf3 & co) is compiler-rt
 * and was always correct. */
union lot_f128 { long double f; struct { unsigned long long lo, hi; } i; };

int __fpclassifyl(long double x) {
    union lot_f128 u = { x };
    int e = (u.i.hi >> 48) & 0x7fff;
    unsigned long long m = (u.i.hi & 0xffffffffffffULL) | u.i.lo;
    if (!e) return m ? FP_SUBNORMAL : FP_ZERO;
    if (e == 0x7fff) return m ? FP_NAN : FP_INFINITE;
    return FP_NORMAL;
}
int __signbitl(long double x) {
    union lot_f128 u = { x };
    return (int)(u.i.hi >> 63);
}
long double frexpl(long double x, int *e) {
    union lot_f128 u = { x };
    int ee = (u.i.hi >> 48) & 0x7fff;
    if (!ee) {
        if (x) { x = frexpl(x * 0x1p120L, e); *e -= 120; }
        else *e = 0;
        return x;
    }
    if (ee == 0x7fff) return x;
    *e = ee - 0x3ffe;
    u.i.hi &= 0x8000ffffffffffffULL;
    u.i.hi |= 0x3ffeULL << 48;
    return u.f;
}
long double fabsl(long double x) {
    union lot_f128 u = { x };
    u.i.hi &= 0x7fffffffffffffffULL;
    return u.f;
}
long double copysignl(long double x, long double y) {
    union lot_f128 ux = { x }, uy = { y };
    ux.i.hi = (ux.i.hi & 0x7fffffffffffffffULL) | (uy.i.hi & 0x8000000000000000ULL);
    return ux.f;
}
/* strtold (__floatscan) scales its result with scalbnl, whose musl build
 * writes the exponent into the ld80 position — INCRBYFLOAT parsed "3.14159"
 * as 1.4e19 through it. Same clamp structure as musl, correct bits. */
long double scalbnl(long double x, int n) {
    union lot_f128 u;
    if (n > 16383) {
        x *= 0x1p16383L; n -= 16383;
        if (n > 16383) { x *= 0x1p16383L; n -= 16383; if (n > 16383) n = 16383; }
    } else if (n < -16382) {
        x *= 0x1p-16382L * 0x1p113L; n += 16382 - 113;
        if (n < -16382) {
            x *= 0x1p-16382L * 0x1p113L; n += 16382 - 113;
            if (n < -16382) n = -16382;
        }
    }
    u.i.lo = 0;
    u.i.hi = (unsigned long long)(0x3fff + n) << 48;
    return x * u.f;
}
long double ldexpl(long double x, int n) { return scalbnl(x, n); }
