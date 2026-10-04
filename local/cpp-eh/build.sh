#!/bin/sh
# Build the C++ exception test against toolchain/cpp-eh-sysroot (see
# toolchain/build-cpp-eh-sysroot.sh).   sh local/cpp-eh/build.sh [outdir]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$HERE/out}"
LLVM=/opt/homebrew/opt/llvm@19/bin
SYSROOT="$REPO/toolchain/cpp-eh-sysroot"
BUILTINS="$SYSROOT/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
FLAGS="-O2 -matomics -mbulk-memory -fwasm-exceptions"
LDFLAGS="-nostdlib -static -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
  -Wl,--export=__heap_base -Wl,--export=__data_end -Wl,--shared-memory \
  -Wl,--max-memory=268435456 -Wl,-z,stack-size=1048576 -Wl,--table-base=2"
O="$OUT/obj"; mkdir -p "$O"
for f in wasm_clone wasm_dlmalloc_mt; do
  $LLVM/clang -target wasm32 --sysroot="$SYSROOT" $FLAGS -w -c "$REPO/sysroot/$f.c" -o "$O/$f.o"
done
$LLVM/clang++ -target wasm32 --sysroot="$SYSROOT" $FLAGS -std=c++17 -c "$HERE/ehtest.cpp" -o "$O/ehtest.o"
$LLVM/clang++ -target wasm32 --sysroot="$SYSROOT" -fuse-ld=lld $FLAGS $LDFLAGS \
  "$SYSROOT/lib/crt1.o" "$O/wasm_dlmalloc_mt.o" "$O/wasm_clone.o" "$O/ehtest.o" \
  -lc++ -lc++abi -lunwind -lc -lm "$BUILTINS" -o "$OUT/ehtest"
chmod +x "$OUT/ehtest"
printf 'out/\n' > "$HERE/.gitignore"
ls -l "$OUT/ehtest"
