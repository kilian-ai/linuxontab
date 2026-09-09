#!/usr/bin/env bash
# Package the WALI-host rustc (built by x.py, see README) for the guest:
#   packages/rustc-<ver>.tar.gz  with  usr/local/lib/rust-wali/{bin/rustc.wasm, lib/rustlib/...}
#   and usr/local/bin/{rustc, lot-rust-ld, lot-rustc}   (toolchain/wali/guest/)
# plus index.json entries (bins rustc + lot-rustc → lean auto-install stubs).
#   toolchain/wali/package-rustc.sh [rust-src-dir]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
RUST="${1:-/tmp/rust-src/rust}"
WASM_OPT="${LOT_WASM_OPT:-/opt/homebrew/bin/wasm-opt}"
NAME=rustc
STAGE2="$RUST/build/wasm32-wali-linux-musl/stage2"
[ -d "$STAGE2/bin" ] || { echo "no cross-host stage2 at $STAGE2 — did 'x.py build --stage 2 --host wasm32-wali-linux-musl compiler/rustc' finish?"; exit 1; }
BIN="$(ls "$STAGE2"/bin/rustc* | head -1)"
# the cross-host stage2 sysroot is empty; the target std built by stage1 lives under the build host
LIBS="$RUST/build/aarch64-apple-darwin/stage2/lib/rustlib/wasm32-wali-linux-musl/lib"
[ -n "$(ls "$LIBS"/libstd-*.rlib 2>/dev/null)" ] || LIBS="$STAGE2/lib/rustlib/wasm32-wali-linux-musl/lib"
[ -d "$LIBS" ] || { echo "no target std at $LIBS"; exit 1; }
VERSION="$(grep -o '^version = "[^"]*"' "$RUST/src/version" 2>/dev/null | head -1 | cut -d'"' -f2)"; VERSION="${VERSION:-$(cat "$RUST/src/version" 2>/dev/null | tr -d '\n')}"; VERSION="${VERSION:-nightly}"
T="$(mktemp -d /tmp/pkg-rustc.XXXXXX)"; P="$T/pkg-$NAME"; R="$P/usr/local/lib/rust-wali"
mkdir -p "$R/bin" "$R/lib/rustlib/wasm32-wali-linux-musl/lib" "$P/usr/local/bin"
echo "==> strip + asyncify $(basename "$BIN") ($(du -h "$BIN" | cut -f1)) — the guest runs asyncified modules"
cp "$BIN" "$T/rustc-raw.wasm"; wasm-strip "$T/rustc-raw.wasm"; BIN="$T/rustc-raw.wasm"
"$WASM_OPT" --enable-exception-handling --enable-threads --enable-bulk-memory --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
  --enable-reference-types --enable-multivalue --enable-tail-call --asyncify -O1 "$BIN" -o "$R/bin/rustc.wasm"
chmod 755 "$R/bin/rustc.wasm"
cp "$LIBS"/*.rlib "$R/lib/rustlib/wasm32-wali-linux-musl/lib/"
mkdir -p "$R/lib/rustlib/wasm32-wali-linux-musl/lib/self-contained"
cp /tmp/wali-sysroot/lib/crt1-command.o /tmp/wali-sysroot/lib/libc.a /tmp/wali-sysroot/lib/libclang_rt.builtins-wasm32-wali.a "$R/lib/rustlib/wasm32-wali-linux-musl/lib/self-contained/"
cp "$HERE"/guest/rustc "$HERE"/guest/lot-rust-ld "$HERE"/guest/lot-rustc "$P/usr/local/bin/"; chmod 755 "$P"/usr/local/bin/*
cat > "$P/info" <<INFO
name=$NAME
version=$VERSION
description=rustc for the guest — the Rust compiler as a wasm32-wali-linux-musl binary (lot-rustc hello.rs)
depends=
built_with=toolchain/wali/package-rustc.sh
target=wasm32-wali-linux-musl
INFO
TAR="$REPO/packages/$NAME-$VERSION.tar.gz"
COPYFILE_DISABLE=1 tar czf "$TAR" -C "$T" "pkg-$NAME"
SIZE="$(wc -c < "$TAR" | tr -d ' ')"; SHA="$(shasum -a 256 "$TAR" | cut -d' ' -f1)"
echo "==> $TAR ($SIZE bytes) sha256 $SHA"
for idx in "$REPO/packages/index.json" "$REPO/rootfs/packages/index.json"; do
  [ -f "$idx" ] || continue
  python3 - "$idx" "$NAME" "$VERSION" "$SIZE" "$SHA" <<'PY'
import json, sys, datetime
f, name, version, size, sha = sys.argv[1:]
idx = json.load(open(f))
idx.setdefault("packages", {})[name] = {
    "version": version,
    "description": "rustc for the guest — the Rust compiler as a wasm32-wali-linux-musl binary (lot-rustc hello.rs)",
    "url": f"https://linuxontab.com/packages/{name}-{version}.tar.gz",
    "size": int(size), "sha256": sha, "bins": ["rustc", "lot-rustc"], "depends": [], "status": "available",
}
idx["generated"] = datetime.date.today().isoformat()
json.dump(idx, open(f, "w"), indent=2); open(f, "a").write("\n"); print("updated", f)
PY
done
rm -rf "$T"
