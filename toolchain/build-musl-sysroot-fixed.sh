#!/usr/bin/env bash
# build-musl-sysroot-fixed.sh — Rebuild the wasm32-musl sysroot with the
# mallocng alloc_meta fix applied.
#
# Background: the tombl/musl wasm32 port's alloc_meta() (src/malloc/mallocng/
# malloc.c) called sbrk() but discarded its return value, then computed the
# meta-area base as (void *)(3*pagesize - pagesize) — i.e. the hardcoded
# address 0x8000 (PAGE_SIZE is 16384 on this port). Every process's malloc
# metadata was silently written over bytes 0x8000–0xC000 of linear memory,
# corrupting the data/rodata (default --global-base=1024) or stack of any
# binary linked against it, and eventually malloc's own earlier meta areas.
# See toolchain/patches/musl-mallocng-alloc-meta-sbrk.patch for the fix.
#
# This script replays the original Nix derivations (musl.drv + musl-sysroot
# .drv) outside Nix, using the exact same toolchain store paths, with the
# patch applied. Output: toolchain/musl-sysroot-fixed/ — byte-identical to
# /nix/store/*-musl-sysroot except libc.a / libc.so (and musl-gcc.specs
# paths). build-package.sh prefers this sysroot automatically.
#
# Requirements: the Nix store paths below (present on the original build
# machine). Override via env if the hashes differ on your machine.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${LOT_SYSROOT_OUT:-$REPO_ROOT/toolchain/musl-sysroot-fixed}"
WORK="${LOT_MUSL_WORK:-/tmp/lot-musl-fixed-build}"

MUSL_SRC="${LOT_MUSL_SRC:-/nix/store/1vnlankkh1b061srg5b17n0rd6kzzc0j-tombl-musl-314d4e81e26546ba063663437657095ad2c0351c}"
CLANG_BIN="${LOT_CLANG_BIN:-/nix/store/ikvjm47zi9ahv46v4g3vakvyqaw4vpvk-clang-19.1.7/bin}"
MAKE_BIN="${LOT_MAKE_BIN:-/nix/store/308q7v3aaiw4d1wjijy7xcszlgnfadb6-gnumake-4.4.1/bin}"
LLD_BIN="${LOT_LLD_BIN:-/nix/store/hi5jf8kppa6mz32pqawjq7wm6pvn1nhn-lld-19.1.7/bin}"
LLVM_BIN="${LOT_LLVM_BIN:-/nix/store/9bcy8p4xf4ni3bfmzxd0ib3nljbfw6v1-llvm-19.1.7/bin}"
LINUX_HEADERS="${LOT_LINUX_HEADERS:-/nix/store/k9lpm468z5y66dclgqs8hvv6402mlv3f-linux-headers}"
COMPILER_RT="${LOT_COMPILER_RT:-/nix/store/7s2hsdqkfwm0g05w09176jcs840b8ng6-compiler-rt}"

for p in "$MUSL_SRC" "$CLANG_BIN" "$MAKE_BIN" "$LLD_BIN" "$LLVM_BIN" "$LINUX_HEADERS" "$COMPILER_RT"; do
    [ -e "$p" ] || { echo "Error: missing input: $p (set LOT_* overrides)"; exit 1; }
done

echo "==> Copying musl source"
rm -rf "$WORK"
mkdir -p "$WORK"
cp -R "$MUSL_SRC" "$WORK/src"
chmod -R u+w "$WORK/src"

echo "==> Applying alloc_meta patch"
patch -p1 -d "$WORK/src" < "$REPO_ROOT/toolchain/patches/musl-mallocng-alloc-meta-sbrk.patch"

echo "==> Building musl (wasm32)"
MUSL_OUT="$WORK/out"
mkdir -p "$MUSL_OUT"
cd "$WORK/src"
printf 'ARCH=wasm32\nprefix=%s\nsyslibdir=%s\nCFLAGS=\n' "$MUSL_OUT" "$MUSL_OUT" > config.mak
export PATH="$CLANG_BIN:$MAKE_BIN:$LLD_BIN:$LLVM_BIN:$PATH"
make -j"$(sysctl -n hw.logicalcpu 2>/dev/null || nproc)" install-libs install-headers

echo "==> Assembling sysroot at $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
cp -r "$MUSL_OUT/include/." "$OUT/include/"
cp "$MUSL_OUT/lib/"* "$OUT/lib/"
# NOTE: the original musl-sysroot derivation copied the linux-headers
# package's top-level entries into include/, which nests them (unused) at
# include/include/. Replicated as-is so builds see identical header layouts.
cp -r "$LINUX_HEADERS/include" "$OUT/include/include"
for d in wasm32 wasm32-unknown wasm32-unknown-linux-musl; do
    mkdir -p "$OUT/lib/clang/19/lib/$d"
    cp "$COMPILER_RT/libclang_rt.builtins-wasm32.a" "$OUT/lib/clang/19/lib/$d/libclang_rt.builtins.a"
done
chmod -R u+w "$OUT"
sed -i '' "s|$MUSL_OUT|$OUT|g" "$OUT/lib/musl-gcc.specs"

echo "==> Verifying"
python3 - "$OUT/lib/libc.a" << 'PY'
import sys
data = open(sys.argv[1], 'rb').read()
bad = bytes.fromhex('417f460d0341808002210 2'.replace(' ', ''))
if data.count(bad):
    sys.exit("ERROR: buggy alloc_meta pattern still present in libc.a")
print("OK: libc.a is free of the hardcoded-0x8000 alloc_meta bug")
PY

echo "Done: $OUT"
