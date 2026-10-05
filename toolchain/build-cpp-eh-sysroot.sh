#!/bin/sh
# Build toolchain/cpp-eh-sysroot: the musl sysroot plus libc++, libc++abi and
# libunwind compiled with WebAssembly exception handling (-fwasm-exceptions).
#
# toolchain/cpp-sysroot-fixed's libc++abi was built for the native Itanium
# unwinder (it calls _Unwind_RaiseException, which nothing provides), so a
# C++ `throw` cannot work there. Big C++ ports that need exceptions
# (LibreOffice) link against this sysroot instead; existing packages keep
# using cpp-sysroot-fixed unchanged.
#
# Everything here, and every object linked with it, must be compiled with
#   -fwasm-exceptions -matomics -mbulk-memory
# (mixing in -fno-exceptions objects is fine; mixing in Emscripten-style
# JS exceptions is not). Exceptions use the wasm EH proposal's legacy
# instructions (try/catch/rethrow), which V8 and JavaScriptCore support.
# Asyncify does NOT support them: do not run `wasm-opt --asyncify` on a
# module that uses exceptions.
#
#   sh toolchain/build-cpp-eh-sysroot.sh [llvm-project-19.1.7.src dir]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
LLVM_SRC="${1:-${LLVM_SRC:-}}"
[ -n "$LLVM_SRC" ] && [ -d "$LLVM_SRC/libcxxabi" ] || {
  echo "usage: $0 <llvm-project-19.1.7.src>  (needs runtimes cmake llvm/cmake libcxx libcxxabi libunwind)"
  echo "  curl -LO https://github.com/llvm/llvm-project/releases/download/llvmorg-19.1.7/llvm-project-19.1.7.src.tar.xz"
  exit 2; }
LLVM=/opt/homebrew/opt/llvm@19/bin
OUT="$HERE/cpp-eh-sysroot"
BLD="${BLD:-$(mktemp -d)}"
TARGET=wasm32-unknown-unknown   # what build-package.sh uses (-target wasm32) with the musl sysroot
FLAGS="-O2 -matomics -mbulk-memory -fwasm-exceptions"

# 1. start from the fixed musl sysroot (libc.a with the brk + alloc_meta fixes)
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$HERE/musl-sysroot-fixed/include" "$HERE/musl-sysroot-fixed/lib" "$OUT/"
# declare mmap & co. on wasm too (musl hides the whole API behind
# #ifndef __wasm__): ports built here link sysroot/wasm_mmap.c, which
# implements it in userspace
sed -i.bak 's|^#ifndef __wasm__$|#if 1 /* cpp-eh-sysroot: mmap comes from sysroot/wasm_mmap.c */|' "$OUT/include/sys/mman.h"
rm -f "$OUT/include/sys/mman.h.bak"
grep -q "cpp-eh-sysroot: mmap" "$OUT/include/sys/mman.h" || { echo "ERROR: sys/mman.h guard not found"; exit 1; }

# 2. libunwind: for wasm EH only Unwind-wasm.c is needed (the unwinding itself
#    is done by the engine; this is the _Unwind_* glue libc++abi calls)
mkdir -p "$BLD/unwind"
$LLVM/clang --target=$TARGET --sysroot="$OUT" $FLAGS -std=c99 \
  -I"$LLVM_SRC/libunwind/include" -D_LIBUNWIND_IS_NATIVE_ONLY -D_LIBUNWIND_HIDE_SYMBOLS -DNDEBUG \
  -c "$LLVM_SRC/libunwind/src/Unwind-wasm.c" -o "$BLD/unwind/Unwind-wasm.o"
$LLVM/llvm-ar rcs "$OUT/lib/libunwind.a" "$BLD/unwind/Unwind-wasm.o"
cp "$LLVM_SRC/libunwind/include/unwind.h" "$LLVM_SRC/libunwind/include/__libunwind_config.h" "$OUT/include/"

# 3. libc++ + libc++abi
cmake -G Ninja -S "$LLVM_SRC/runtimes" -B "$BLD/rt" \
  -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
  -DCMAKE_C_COMPILER=$LLVM/clang -DCMAKE_CXX_COMPILER=$LLVM/clang++ \
  -DCMAKE_AR=$LLVM/llvm-ar -DCMAKE_RANLIB=$LLVM/llvm-ranlib \
  -DCMAKE_C_COMPILER_TARGET=$TARGET -DCMAKE_CXX_COMPILER_TARGET=$TARGET \
  -DCMAKE_SYSROOT="$OUT" \
  -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_INSTALL_PREFIX="$OUT" \
  -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_SHARED=OFF \
  -DLIBCXX_HAS_MUSL_LIBC=ON \
  -DLIBCXX_CXX_ABI=libcxxabi \
  -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=OFF \
  -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
  -DLIBCXXABI_ENABLE_STATIC_UNWINDER=OFF \
  -DLIBCXXABI_LIBUNWIND_INCLUDES="$LLVM_SRC/libunwind/include" \
  -DLIBCXX_ENABLE_EXCEPTIONS=ON -DLIBCXXABI_ENABLE_EXCEPTIONS=ON \
  -DLIBCXX_ENABLE_THREADS=ON -DLIBCXXABI_ENABLE_THREADS=ON \
  -DLIBCXX_HAS_PTHREAD_API=ON -DLIBCXXABI_HAS_PTHREAD_API=ON \
  -DLIBCXX_ENABLE_FILESYSTEM=ON \
  -DLIBCXX_ENABLE_TIME_ZONE_DATABASE=OFF \
  -DLIBCXX_HAS_ATOMIC_LIB=OFF \
  -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
  -DLIBCXXABI_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_DOCS=OFF \
  -DLIBCXX_INSTALL_MODULES=OFF \
  >"$BLD/cmake.log" 2>&1 || { tail -40 "$BLD/cmake.log"; exit 1; }
ninja -C "$BLD/rt" install-cxx install-cxxabi >"$BLD/ninja.log" 2>&1 || { tail -40 "$BLD/ninja.log"; exit 1; }

# 4. sanity: the personality routine and the wasm unwinder are there
$LLVM/llvm-nm "$OUT/lib/libc++abi.a" 2>/dev/null | grep -q " T __gxx_personality_wasm0" \
  || { echo "ERROR: libc++abi has no __gxx_personality_wasm0"; exit 1; }
$LLVM/llvm-nm "$OUT/lib/libunwind.a" 2>/dev/null | grep -q " T _Unwind_RaiseException" \
  || { echo "ERROR: libunwind has no _Unwind_RaiseException"; exit 1; }
echo "==> $OUT"
echo "    link C++ with: --sysroot=$OUT -fwasm-exceptions ... -lc++ -lc++abi -lunwind"
