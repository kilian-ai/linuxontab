#!/bin/sh
# Build the xtiny desktop apps (lot-calc, lot-calendar, lot-textedit).
#   sh xapps/build.sh <x11-prefix> <outdir>
# <x11-prefix> holds include/ and lib/ of the packaged X11 client libraries
# (libX11, libxcb, libXau, libXdmcp + xorgproto headers); the xtiny-apps
# recipe unpacks them there. Plain Xlib, statically linked, no fork.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
X="$1"; OUT="$2"
CLANG="${LOT_CLANG:-/opt/homebrew/opt/llvm@19/bin/clang}"
SR="${LOT_SYSROOT:-$REPO/toolchain/musl-sysroot-fixed}"
B="$SR/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
mkdir -p "$OUT"
for a in calc calendar textedit; do
  "$CLANG" -target wasm32 --sysroot="$SR" -fuse-ld=lld -O2 -matomics -mbulk-memory \
    -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
    -I"$X/include" \
    -nostdlib -static -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
    -Wl,--export=__heap_base -Wl,--export=__data_end -Wl,--shared-memory \
    -Wl,--max-memory=268435456 -Wl,-z,stack-size=1048576 -Wl,--table-base=2 \
    "$SR/lib/crt1.o" "$REPO/xapps/$a.c" "$REPO/xapps/x11_compat.c" "$REPO/sysroot/wasm_ld128.c" "$REPO/sysroot/wasm_dlmalloc.c" \
    -L"$X/lib" -lX11 -lxcb -lXau -lc -lm "$B" -o "$OUT/lot-$a"
done
ls -l "$OUT"/lot-*
