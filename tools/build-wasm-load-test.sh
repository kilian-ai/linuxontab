#!/bin/sh
# Build tools/wasm-load-test.c -> tools/wasm-load-test (wasm32-linux-musl),
# the guest test for the runtime's code-loading call (#14). Linked with
# --growable-table: lot_wasm_load appends to the program's function table.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CLANG="${LOT_CLANG:-/nix/store/crxcx38y8j2yahb8kzhs3dnifka7kl53-clang-19.1.7/bin/clang}"
SR="$REPO/toolchain/musl-sysroot-fixed"
WASM_OPT="${LOT_WASM_OPT:-/opt/homebrew/bin/wasm-opt}"
OUT="${1:-$HERE/wasm-load-test}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

"$CLANG" -target wasm32 --sysroot="$SR" -O2 -matomics -mbulk-memory \
    -c "$HERE/wasm-load-test.c" -o "$TMP/t.o"
"$CLANG" -target wasm32 --sysroot="$SR" -nostdlib -static \
    -Wl,--import-memory -Wl,--export-memory -Wl,--export-table -Wl,--growable-table \
    -Wl,--export=__heap_base -Wl,--export=__data_end \
    -Wl,--shared-memory -Wl,--max-memory=268435456 \
    -Wl,-z,stack-size=1048576 \
    "$SR/lib/crt1.o" "$TMP/t.o" -lc \
    "$SR/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a" \
    -o "$TMP/t.wasm"
"$WASM_OPT" --enable-exception-handling --asyncify -O1 "$TMP/t.wasm" -o "$OUT"
chmod +x "$OUT"
ls -la "$OUT"
