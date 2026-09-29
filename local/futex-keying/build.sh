#!/bin/sh
# Build the cross-process futex keying tests (see README.md).
#   sh local/futex-keying/build.sh [outdir]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$HERE/out}"
CLANG=/opt/homebrew/opt/llvm@19/bin/clang
SYSROOT="$REPO/toolchain/musl-sysroot-fixed"
CRT1="$SYSROOT/lib/crt1.o"
BUILTINS="$SYSROOT/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
CC="$CLANG -target wasm32 --sysroot=$SYSROOT"
CFLAGS="-O2 -matomics -mbulk-memory"
LDFLAGS="-nostdlib -static -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
  -Wl,--export=__heap_base -Wl,--export=__data_end -Wl,--shared-memory \
  -Wl,--max-memory=268435456 -Wl,-z,stack-size=1048576"
O="$OUT/obj"; mkdir -p "$O"
for f in wasm_clone wasm_dlmalloc_mt; do
  $CC $CFLAGS -w -c "$REPO/sysroot/$f.c" -o "$O/$f.o"
done
for f in futexkey condpp; do
  $CC $CFLAGS -c "$HERE/$f.c" -o "$O/$f.o"
  $CC -fuse-ld=lld $CFLAGS $LDFLAGS "$CRT1" "$O/wasm_dlmalloc_mt.o" "$O/wasm_clone.o" \
    "$O/$f.o" -lc -lm "$BUILTINS" -o "$OUT/$f"
done
chmod +x "$OUT/futexkey" "$OUT/condpp"
ls -l "$OUT" | grep -v obj
