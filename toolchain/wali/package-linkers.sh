#!/usr/bin/env bash
# Register the guest linker tools rustc depends on as auto-installable packages:
#   wasm-ld  — lld 19.1.7 (rootfs/usr/local/bin/wasm-ld.real + the --threads=1 wrapper)
#   wasm-opt — binaryen 129 cross-built for wasm32-wali (LOT_BINARYEN=/tmp/binaryen-wali/bin/wasm-opt,
#              cmake with tools/wali.cmake like lld, see README); the old C-toolchain build
#              (wasm-opt-129.tar.gz) traps in musl's allocator on inputs of a few hundred KB.
# Both tools existed but were missing from index.json, so the lean image had no stubs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
LD_VER=19.1.7; OPT_VER=129-wali
BINARYEN="${LOT_BINARYEN:-/tmp/binaryen-wali/bin/wasm-opt}"
WASM_OPT="${LOT_WASM_OPT:-/opt/homebrew/bin/wasm-opt}"
T="$(mktemp -d /tmp/pkg-linkers.XXXXXX)"
P="$T/pkg-wasm-ld"; mkdir -p "$P/usr/local/bin"
cp "$REPO/rootfs/usr/local/bin/wasm-ld.real" "$REPO/rootfs/usr/local/bin/wasm-ld" "$P/usr/local/bin/"; chmod 755 "$P"/usr/local/bin/*
printf 'name=wasm-ld\nversion=%s\ndescription=wasm-ld (lld %s) for wasm32 — the linker rustc and clang use in the guest\ndepends=\nbuilt_with=toolchain/wali/package-linkers.sh\ntarget=wasm32\n' "$LD_VER" "$LD_VER" > "$P/info"
COPYFILE_DISABLE=1 tar czf "$REPO/packages/wasm-ld-$LD_VER.tar.gz" -C "$T" pkg-wasm-ld
[ -f "$BINARYEN" ] || { echo "no WALI wasm-opt at $BINARYEN (LOT_BINARYEN=)"; exit 1; }
P="$T/pkg-wasm-opt"; mkdir -p "$P/usr/local/bin"
cp "$BINARYEN" "$T/wasm-opt-raw.wasm"; wasm-strip "$T/wasm-opt-raw.wasm"
echo "==> asyncify wasm-opt ($(du -h "$T/wasm-opt-raw.wasm" | cut -f1))"
"$WASM_OPT" --enable-exception-handling --enable-threads --enable-bulk-memory --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
  --enable-reference-types --enable-multivalue --enable-tail-call --asyncify -O1 "$T/wasm-opt-raw.wasm" -o "$P/usr/local/bin/wasm-opt"
chmod 755 "$P/usr/local/bin/wasm-opt"
printf 'name=wasm-opt\nversion=%s\ndescription=wasm-opt (binaryen 129, wasm32-wali build) — asyncify/optimize wasm modules in the guest (lot-rustc)\ndepends=\nbuilt_with=toolchain/wali/package-linkers.sh\ntarget=wasm32-wali-linux-musl\n' "$OPT_VER" > "$P/info"
COPYFILE_DISABLE=1 tar czf "$REPO/packages/wasm-opt-$OPT_VER.tar.gz" -C "$T" pkg-wasm-opt
register() {  # name version description bins-json
  local name=$1 ver=$2 desc=$3 bins=$4 tar="$REPO/packages/$1-$2.tar.gz"
  local size sha; size="$(wc -c < "$tar" | tr -d ' ')"; sha="$(shasum -a 256 "$tar" | cut -d' ' -f1)"
  echo "==> $tar ($size bytes) sha256 $sha"
  for idx in "$REPO/packages/index.json" "$REPO/rootfs/packages/index.json"; do
    [ -f "$idx" ] || continue
    python3 - "$idx" "$name" "$ver" "$desc" "$bins" "$size" "$sha" <<'PY'
import json, sys, datetime
f, name, version, desc, bins, size, sha = sys.argv[1:]
idx = json.load(open(f))
idx.setdefault("packages", {})[name] = {
    "version": version, "description": desc,
    "url": f"https://linuxontab.com/packages/{name}-{version}.tar.gz",
    "size": int(size), "sha256": sha, "bins": json.loads(bins), "depends": [], "status": "available",
}
idx["generated"] = datetime.date.today().isoformat()
json.dump(idx, open(f, "w"), indent=2); open(f, "a").write("\n"); print("updated", f)
PY
  done
}
register wasm-ld "$LD_VER" "wasm-ld (lld $LD_VER) for wasm32 — the linker rustc and clang use in the guest" '["wasm-ld"]'
register wasm-opt "$OPT_VER" "wasm-opt (binaryen 129, wasm32-wali build) — asyncify/optimize wasm modules in the guest (used by lot-rustc)" '["wasm-opt"]'
rm -rf "$T"
