#!/usr/bin/env bash
# Package the WALI-host cargo (x.py build --stage 2 --host wasm32-wali-linux-musl src/tools/cargo)
# for the guest: packages/cargo-<ver>.tar.gz with usr/local/lib/rust-wali/bin/cargo.wasm and
# usr/local/bin/cargo (toolchain/wali/guest/cargo). Depends on the rustc package.
#   toolchain/wali/package-cargo.sh [rust-src-dir]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
RUST="${1:-/tmp/rust-src/rust}"
WASM_OPT="${LOT_WASM_OPT:-/opt/homebrew/bin/wasm-opt}"
NAME=cargo
BIN="${LOT_CARGO_BIN:-$RUST/build/wasm32-wali-linux-musl/stage2-tools-bin/cargo}"
[ -f "$BIN" ] || { echo "no WALI cargo at $BIN"; exit 1; }
VERSION="$(grep -m1 '^version = ' "$RUST/src/tools/cargo/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"; VERSION="${VERSION:-nightly}"
T="$(mktemp -d /tmp/pkg-cargo.XXXXXX)"; P="$T/pkg-$NAME"; R="$P/usr/local/lib/rust-wali"
mkdir -p "$R/bin" "$P/usr/local/bin"
echo "==> strip + asyncify cargo ($(du -h "$BIN" | cut -f1))"
if [ -n "${CARGO_ASYNC:-}" ] && [ -f "$CARGO_ASYNC" ]; then echo "    reusing $CARGO_ASYNC"; cp "$CARGO_ASYNC" "$R/bin/cargo.wasm"; else
cp "$BIN" "$T/cargo-raw.wasm"; wasm-strip "$T/cargo-raw.wasm"
"$WASM_OPT" --enable-exception-handling --enable-threads --enable-bulk-memory --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
  --enable-reference-types --enable-multivalue --enable-tail-call --asyncify -O1 "$T/cargo-raw.wasm" -o "$R/bin/cargo.wasm"
fi
chmod 755 "$R/bin/cargo.wasm"
cp "$HERE/guest/cargo" "$P/usr/local/bin/cargo"; chmod 755 "$P/usr/local/bin/cargo"
cat > "$P/info" <<INFO
name=$NAME
version=$VERSION
description=cargo for the guest — Rust's build tool as a wasm32-wali-linux-musl binary (cargo new/build/run)
depends=rustc
built_with=toolchain/wali/package-cargo.sh
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
    "description": "cargo for the guest — Rust's build tool as a wasm32-wali-linux-musl binary (cargo new/build/run)",
    "url": f"https://linuxontab.com/packages/{name}-{version}.tar.gz",
    "size": int(size), "sha256": sha, "bins": ["cargo"], "depends": ["rustc"], "status": "available",
}
idx["generated"] = datetime.date.today().isoformat()
json.dump(idx, open(f, "w"), indent=2); open(f, "a").write("\n"); print("updated", f)
PY
done
rm -rf "$T"
