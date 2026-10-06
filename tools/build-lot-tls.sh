#!/bin/sh
# Build tools/lot-tls (rustls → wasm32-wasip1) into shell/linux-dist/lot-tls.wasm
# and stamp its content hash into shell/wasm.html (LOT_TLS_URL ?v=), because
# /linux-dist/* is served immutable for a year.
#
# Needs: rustup target wasm32-wasip1, and a clang with a wasm32 backend for
# ring's C (the nix clang 19; its resource headers are passed explicitly).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CLANG="${LOT_CLANG:-/nix/store/crxcx38y8j2yahb8kzhs3dnifka7kl53-clang-19.1.7/bin/clang}"
AR="${LOT_AR:-$(find /nix/store -maxdepth 3 -name llvm-ar -path '*llvm-19*' 2>/dev/null | head -1)}"
CINC="${LOT_CLANG_INC:-$(find /nix/store -maxdepth 6 -path '*clang-19*-lib/lib/clang/19/include' -type d 2>/dev/null | head -1)}"
[ -x "$CLANG" ] && [ -x "$AR" ] && [ -d "$CINC" ] || { echo "clang/llvm-ar/resource headers not found (set LOT_CLANG/LOT_AR/LOT_CLANG_INC)" >&2; exit 1; }

cd "$HERE/lot-tls"
CC_wasm32_wasip1="$CLANG" AR_wasm32_wasip1="$AR" CFLAGS_wasm32_wasip1="-isystem $CINC" \
    cargo build --release --target wasm32-wasip1
OUT="$REPO/shell/linux-dist/lot-tls.wasm"
cp target/wasm32-wasip1/release/lot_tls.wasm "$OUT"
V=$(shasum -a 256 "$OUT" | cut -c1-12)
perl -pi -e "s{(LOT_TLS_URL = '\./linux-dist/lot-tls\.wasm\?v=)[^']*'}{\${1}$V'}" "$REPO/shell/wasm.html"
grep -q "lot-tls.wasm?v=$V'" "$REPO/shell/wasm.html" || { echo "failed to stamp wasm.html" >&2; exit 1; }
ls -l "$OUT"; echo "stamped v=$V"
