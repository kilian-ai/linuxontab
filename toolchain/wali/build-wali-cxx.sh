#!/usr/bin/env bash
# After build-wali-musl.sh: fix two ABI bugs in the wali-musl sysroot headers
# for C++ under WALI's LP64-on-wasm32 model, then build libc++/libc++abi/
# libunwind for the WALI target (needed by anything C++ — rustc's LLVM).
#
#   ./toolchain/wali/build-wali-cxx.sh     # -> /tmp/wali-libcxx, tools in /tmp/wali-tools
#
# Needs: /tmp/llvm22 (clang 22, from build-wali-musl.sh), /tmp/wali-sysroot,
# an LLVM source tree with runtimes/ (default: rust's src/llvm-project checkout).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SYS="${WALI_SYSROOT:-/tmp/wali-sysroot}"; LLVM="${LLVM_DIR:-/tmp/llvm22}"
SRC="${LLVM_RUNTIMES_SRC:-/tmp/rust-src/rust/src/llvm-project}"
OUT=/tmp/wali-libcxx-build; INST="${WALI_LIBCXX:-/tmp/wali-libcxx}"

# 1. sysroot header fixes (idempotent)
python3 - "$SYS" <<'PY'
import sys, os
sys_ = sys.argv[1]
p = os.path.join(sys_, 'include/bits/alltypes.h'); s = open(p).read()
old = '#ifdef __cplusplus\n#if defined(__NEED_pthread_t) && !defined(__DEFINED_pthread_t)\ntypedef unsigned long pthread_t;'
if old in s:  # C++ pthread_t was `unsigned long` = 64-bit, but the C library takes a 32-bit pointer: every C++ pthread_* call traps
    s = s.replace(old, '#ifdef __cplusplus\n#if defined(__NEED_pthread_t) && !defined(__DEFINED_pthread_t)\n/* LinuxOnTab/WALI: 32-bit pointers with 64-bit long: keep pthread_t pointer-sized so C++ and C agree */\ntypedef unsigned pthread_t;')
    open(p, 'w').write(s); print('patched pthread_t')
p = os.path.join(sys_, 'include/stdint.h'); s = open(p).read()
old = '#if UINTPTR_MAX == UINT64_MAX\n#define INT64_C(c) c ## L'
if old in s:  # INT64_C/UINT64_C picked the LL suffix by pointer width, but int64_t is `long` here: std::max(UINT64_C(1), x) fails to deduce
    s = s.replace(old, '/* LinuxOnTab/WALI: 32-bit pointers but 64-bit long (int64_t = long): pick the suffix by long width */\n#if __LONG_MAX__ == 0x7fffffffffffffffL\n#define INT64_C(c) c ## L')
    open(p, 'w').write(s); print('patched stdint.h')
PY
# clang's driver expects the compiler-rt builtins in its resource dir and a bare crt1.o
mkdir -p "$LLVM/lib/clang/22/lib/wasm32-unknown-linux-muslwali"
cp -n "$SYS/lib/libclang_rt.builtins-wasm32-wali.a" "$LLVM/lib/clang/22/lib/wasm32-unknown-linux-muslwali/libclang_rt.builtins.a" 2>/dev/null || true
cp -n "$SYS/lib/crt1.o" "$SYS/lib/rcrt1.o" 2>/dev/null || true      # rust's bootstrap copies rcrt1.o for musl targets

# 2. tool wrappers
mkdir -p /tmp/wali-tools; cp "$HERE"/tools/* /tmp/wali-tools/; chmod +x /tmp/wali-tools/*

# 3. libc++ / libc++abi / libunwind (WALI's own cmake recipe, Release)
CF="--target=wasm32-unknown-linux-muslwali --sysroot=$SYS -O2 -pthread -fdeclspec -fwasm-exceptions -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types -Wno-nullability-completeness -mcpu=generic -matomics -mbulk-memory -mexception-handling"
rm -rf "$OUT"
cmake -S "$SRC/runtimes" -B "$OUT" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$INST" \
  -DCMAKE_C_COMPILER="$LLVM/bin/clang" -DCMAKE_CXX_COMPILER="$LLVM/bin/clang++" -DCMAKE_AR="$LLVM/bin/llvm-ar" -DCMAKE_RANLIB="$LLVM/bin/llvm-ranlib" \
  -DCMAKE_C_COMPILER_WORKS=ON -DCMAKE_CXX_COMPILER_WORKS=ON -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=wasm32 -DCMAKE_CROSSCOMPILING=ON \
  -DCMAKE_C_COMPILER_TARGET=wasm32-unknown-linux-muslwali -DCMAKE_CXX_COMPILER_TARGET=wasm32-unknown-linux-muslwali -DCMAKE_SYSROOT="$SYS" \
  -DCMAKE_C_FLAGS="$CF" -DCMAKE_CXX_FLAGS="$CF -Wno-user-defined-literals" -DCMAKE_ASM_FLAGS="$CF" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=OFF -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
  -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_THREADS=ON -DLIBCXX_HAS_MUSL_LIBC=ON -DLIBCXX_ENABLE_EXCEPTIONS=ON -DLIBCXX_ENABLE_FILESYSTEM=ON -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=OFF -DLIBCXX_CXX_ABI=libcxxabi -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_INCLUDE_TESTS=OFF \
  -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_EXCEPTIONS=ON -DLIBCXXABI_ENABLE_THREADS=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON -DLIBCXXABI_SILENT_TERMINATE=ON -DLIBCXXABI_ENABLE_PIC=OFF \
  -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_THREADS=ON -DLIBUNWIND_HIDE_SYMBOLS=ON -DUNIX=ON
ninja -C "$OUT" install
echo "==> WALI C++ ready: $INST (link check: /tmp/wali-tools/wali-ld must report no signature mismatch)"
