#!/bin/sh
# Build tools/lotfetch.c -> rootfs/usr/bin/lotfetch (wasm32-linux-musl,
# asyncified). Same flags as the proven small-tool builds (sigprobe et al).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CLANG="${LOT_CLANG:-/nix/store/crxcx38y8j2yahb8kzhs3dnifka7kl53-clang-19.1.7/bin/clang}"
SR="$REPO/toolchain/musl-sysroot-fixed"
WASM_OPT="${LOT_WASM_OPT:-/opt/homebrew/bin/wasm-opt}"
OUT="$REPO/rootfs/usr/bin/lotfetch"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

"$CLANG" -target wasm32 --sysroot="$SR" -O2 -matomics -mbulk-memory \
    -c "$HERE/lotfetch.c" -o "$TMP/lotfetch.o"
"$CLANG" -target wasm32 --sysroot="$SR" -nostdlib -static \
    -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
    -Wl,--export=__heap_base -Wl,--export=__data_end \
    -Wl,--shared-memory -Wl,--max-memory=268435456 \
    -Wl,-z,stack-size=1048576 \
    "$SR/lib/crt1.o" "$TMP/lotfetch.o" -lc \
    "$SR/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a" \
    -o "$TMP/lotfetch.wasm"
"$WASM_OPT" --enable-exception-handling --asyncify -O1 \
    "$TMP/lotfetch.wasm" -o "$OUT"
chmod +x "$OUT"
ls -la "$OUT"
