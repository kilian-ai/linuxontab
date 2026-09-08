#!/usr/bin/env bash
# Build a Rust crate for the LinuxOnTab guest (target wasm32-wali-linux-musl)
# and asyncify it into a guest-runnable binary.
#
#   toolchain/wali/build-rust-crate.sh <crate dir> <out.wasm> [cargo args...]
#
# Needs: rust nightly + rust-src (rustup), the wali-musl sysroot
# (./build-wali-musl.sh -> $WALI_SYSROOT, default /tmp/wali-sysroot), wasm-opt.
# Crates that hard-code "wasm32 = no OS" (mio, rustix, linux-raw-sys) get the
# patches in ./patches applied to a vendored copy and wired in via
# [patch.crates-io]. Everything is written into the crate's .cargo/config.toml
# and a Cargo.toml [patch] section — check them in if you want reproducible
# builds without this script.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CRATE="$(cd "$1" && pwd)"; OUT="$2"; shift 2
WALI_SYSROOT="${WALI_SYSROOT:-/tmp/wali-sysroot}"
WASM_OPT="${LOT_WASM_OPT:-/opt/homebrew/bin/wasm-opt}"
VENDOR="${WALI_VENDOR:-/tmp/wali-vendor}"
REG="$HOME/.cargo/registry/src"
[ -f "$WALI_SYSROOT/lib/libc.a" ] || { echo "no wali sysroot at $WALI_SYSROOT — run $HERE/build-wali-musl.sh"; exit 1; }

# 1. vendored + patched crates
mkdir -p "$VENDOR"
PATCH_LINES=""
for p in "$HERE"/patches/*.patch; do
  c="$(basename "$p" .patch)"; name="${c%-*}"
  if [ ! -d "$VENDOR/$c" ]; then
    src="$(ls -d "$REG"/*/"$c" 2>/dev/null | head -1)"
    [ -n "$src" ] || { echo "crate $c not in the cargo registry (build once on the host so it downloads)"; exit 1; }
    cp -R "$src" "$VENDOR/$c"
    (cd "$VENDOR" && patch -p1 -d "$c" --strip=1 < "$p" > /dev/null) || (cd "$VENDOR/$c" && patch -p2 < "$p" > /dev/null)
  fi
  PATCH_LINES="$PATCH_LINES$name = { path = \"$VENDOR/$c\" }
"
done

# 2. cargo config: build-std + link against wali-musl (see README)
mkdir -p "$CRATE/.cargo"
cat > "$CRATE/.cargo/config.toml" <<CFG
[unstable]
build-std = ["std", "panic_abort"]

[build]
target = "wasm32-wali-linux-musl"

[target.wasm32-wali-linux-musl]
rustflags = [
  "-Clink-self-contained=no",
  "-Clink-arg=-L$WALI_SYSROOT/lib",
  "-Clink-arg=$WALI_SYSROOT/lib/crt1-command.o",
  "-Clink-arg=-lc",
  "-Clink-arg=$WALI_SYSROOT/lib/libclang_rt.builtins-wasm32-wali.a",
  "-Clink-arg=--import-memory",
  "-Clink-arg=--export-memory",
  "-Clink-arg=--export-table",
  "-Clink-arg=--export=__heap_base",
  "-Clink-arg=--export=__data_end",
  "-Clink-arg=--shared-memory",
  "-Clink-arg=--max-memory=268435456",
  "-Clink-arg=-z",
  "-Clink-arg=stack-size=8388608",
]
CFG
if ! grep -q '^\[patch.crates-io\]' "$CRATE/Cargo.toml"; then
  printf '\n[patch.crates-io]\n%s' "$PATCH_LINES" >> "$CRATE/Cargo.toml"
fi

# 3. build + asyncify (the guest runs asyncified modules: fork/blocking syscalls)
(cd "$CRATE" && cargo +nightly build --release "$@")
BIN="$(ls "$CRATE"/target/wasm32-wali-linux-musl/release/*.wasm | head -1)"
"$WASM_OPT" --enable-exception-handling --enable-threads --enable-bulk-memory --enable-mutable-globals \
  --enable-sign-ext --enable-nontrapping-float-to-int --asyncify -O1 "$BIN" -o "$OUT"
echo "==> $OUT ($(du -h "$OUT" | cut -f1)); drop it in a guest image, e.g.:"
echo "    LEAN_EXTRA_BIN=$OUT ./cloudflare/build-lean-rootfs.sh   (local test image)"
