#!/bin/sh
# Recipe: redis — the key/value database, compiled to wasm32 for the guest.
#
# Why Redis and not DynamoDB: DynamoDB is closed AWS service software, and
# "DynamoDB Local" is a Java application (no JVM here). Redis is the canonical
# open-source key/value store and, unusually for a database, a good fit for
# this guest: one process, one event loop, no mmap'd storage engine (its
# persistence is a plain sequential file), and it needs exactly the two things
# this kernel gained recently — real fork() and epoll.
#
#   redis-server --port 6379 &
#   redis-cli set k v ; redis-cli get k
#
# Build notes for this target:
#   - MALLOC=libc: jemalloc assumes mmap/MAP_ANONYMOUS semantics this guest
#     does not have (musl's wasm32 mmap is a memory.grow shim).
#   - -Dlinux/-D__linux__: `-target wasm32` predefines neither, and Redis picks
#     its event backend from them — without them it falls back from epoll to
#     select. Same trap as the xterm port.
#   - wasm-EH setjmp/longjmp: bundled Lua does error handling with longjmp,
#     which only composes with fork on this kernel under wasm-EH.
#   - Explicit 8 MB stack: the wasm-ld default is 64 KB.

NAME="redis"
VERSION="7.2.5"
DESCRIPTION="Redis key/value database server + CLI"
SOURCE_URL="https://download.redis.io/releases/redis-${VERSION}.tar.gz"
SOURCE_SHA256=""

build() {
    cd "$SRC"

    # fork()/vfork() via the kernel's asyncify thunk (musl omits them on wasm32)
    printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n' \
        > "$SRC/redis-fork.h"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_fork.c" -o "$SRC/wasm_fork.o"

    # musl's pthread_cancel needs asm cancellation points (__cp_begin/__cp_end/
    # __syscall_cp_asm) that don't exist on wasm32. Redis only cancels bio/io
    # threads at shutdown and skips the join when cancel fails, so a stub that
    # reports ESRCH is honest and safe. Linked before -lc, it keeps wasm-ld
    # from ever pulling libc's pthread_cancel.o.
    cat > "$SRC/wasm_nocancel.c" <<'NOCANCELEOF'
#include <pthread.h>
#include <errno.h>
#include <math.h>
int pthread_cancel(pthread_t t) { (void)t; return ESRCH; }

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
NOCANCELEOF
    $CC $CFLAGS -c "$SRC/wasm_nocancel.c" -o "$SRC/wasm_nocancel.o"
    # the sjlj runtime MUST itself be built with the sjlj pass
    $CC $CFLAGS -mexception-handling -mllvm -wasm-enable-sjlj \
        -c "$REPO_ROOT/sysroot/sjlj_rt_wasmeh.c" -o "$SRC/sjlj_rt.o"

    # DEBUG SEGFAULT maps a read-only page and writes to it — but the wasm32
    # sysroot has no mmap at all (sys/mman.h guards everything behind
    # #ifndef __wasm__). It's a crash-on-purpose test command, so abort().
    perl -0777 -i -pe 's{char\* p = mmap\(NULL, 4096, PROT_READ, MAP_PRIVATE \| MAP_ANON, -1, 0\);\n\s*\*p = .x.;}{abort(); /* wasm32: no mmap; DEBUG SEGFAULT crashes via abort */}' src/debug.c
    grep -q "wasm32: no mmap" src/debug.c || { echo "debug.c patch failed" >&2; exit 1; }

    LOTDEFS="-Dlinux=1 -D__linux__=1 -D_GNU_SOURCE=1"
    SJLJ="-mexception-handling -mllvm -wasm-enable-sjlj"
    # -Qunused-arguments: hiredis compiles with -Werror, and the driver warns
    # that -fuse-ld=lld is unused when only compiling. That warning is not a
    # code defect, so silence it rather than dropping -Werror.
    CC_FULL="$CC $LOTDEFS $SJLJ -Qunused-arguments -include $SRC/redis-fork.h"

    STACK="-Wl,-z,stack-size=8388608"
    LDF="$LDFLAGS $STACK"
    LIBS_ALL="$SRC/wasm_fork.o $SRC/sjlj_rt.o $SRC/wasm_nocancel.o $CRT1 -lc -lm $BUILTINS"

    # Build each dep to the exact artifact src/Makefile links, rather than via
    # deps/Makefile: its "lua" target also links the lua/luac INTERPRETERS,
    # which are host tools we neither need nor can link (no _start for a
    # wasm reactor object).
    DEPCC="$CC_FULL"
    DEPCFLAGS="$CFLAGS $LOTDEFS"
    make -C deps/hiredis -j4 static CC="$DEPCC" CFLAGS="$DEPCFLAGS" \
        AR="$AR" RANLIB="$RANLIB"
    make -C deps/lua/src -j4 liblua.a CC="$DEPCC" \
        CFLAGS="$DEPCFLAGS -DLUA_ANSI" AR="$AR rcu" RANLIB="$RANLIB"
    make -C deps/fpconv -j4 CC="$DEPCC" CFLAGS="$DEPCFLAGS" \
        AR="$AR" RANLIB="$RANLIB"
    make -C deps/hdr_histogram -j4 CC="$DEPCC" CFLAGS="$DEPCFLAGS" \
        AR="$AR" RANLIB="$RANLIB"
    $DEPCC $DEPCFLAGS -c deps/linenoise/linenoise.c -o deps/linenoise/linenoise.o
    for a in deps/hiredis/libhiredis.a deps/lua/src/liblua.a \
             deps/fpconv/libfpconv.a deps/hdr_histogram/libhdrhistogram.a \
             deps/linenoise/linenoise.o; do
        [ -f "$a" ] || { echo "dep missing after build: $a" >&2; exit 1; }
    done
    echo "==> deps ok"

    make -C src -j4 redis-server redis-cli \
        MALLOC=libc BUILD_TLS=no USE_JEMALLOC=no \
        CC="$CC_FULL" \
        CFLAGS="$CFLAGS $LOTDEFS" \
        LDFLAGS="$LDF" \
        FINAL_LIBS="$LIBS_ALL" \
        AR="$AR" RANLIB="$RANLIB"

    mkdir -p "$STAGE/usr/bin" "$STAGE/etc"
    cp -f src/redis-server "$STAGE/usr/bin/redis-server"
    cp -f src/redis-cli    "$STAGE/usr/bin/redis-cli"
    # A config tuned for the guest: no daemonize (no setsid dance), no
    # background save (fork is expensive here), modest memory.
    cat > "$STAGE/etc/redis.conf" <<'CONFEOF'
# LinuxOnTab guest defaults. Foreground, no RDB snapshots (a background save
# forks a 512 MB-address-space child on a single-CPU guest), append-only off.
port 6379
bind 127.0.0.1
daemonize no
save ""
appendonly no
maxmemory 64mb
maxmemory-policy allkeys-lru
logfile ""
CONFEOF
}
