#!/bin/sh
# Build zlib for wasm32 and install to a writable prefix.
#
# Usage:
#   ./local/bootstrap-wasm-zlib.sh
#   ./local/bootstrap-wasm-zlib.sh /custom/prefix
#
# Env overrides:
#   LOT_CLANG, LOT_SYSROOT, LOT_WASM_ZLIB_VERSION, LOT_WASM_ZLIB_URL

set -eu

PREFIX="${1:-${LOT_WASM_ZLIB_PREFIX:-$HOME/.cache/linuxontab/wasm-zlib}}"
VERSION="${LOT_WASM_ZLIB_VERSION:-1.3.1}"
URL="${LOT_WASM_ZLIB_URL:-https://github.com/madler/zlib/releases/download/v${VERSION}/zlib-${VERSION}.tar.gz}"

find_one() {
    find /nix/store -maxdepth 3 "$@" 2>/dev/null | sort | head -1
}

find_llvm_tool() {
    tool_name="$1"
    p="$(find /nix/store -maxdepth 3 -name "$tool_name" -path '*llvm-19*' 2>/dev/null | sort | head -1)"
    [ -n "$p" ] || p="$(find /nix/store -maxdepth 3 -name "$tool_name" 2>/dev/null | sort | head -1)"
    [ -n "$p" ] || p="$(command -v "$tool_name" 2>/dev/null || true)"
    printf '%s\n' "$p"
}

CLANG="${LOT_CLANG:-}"
SYSROOT="${LOT_SYSROOT:-}"

[ -n "$CLANG" ] || CLANG="$(find_one -path '*/bin/clang')"
[ -n "$SYSROOT" ] || SYSROOT="$(find /nix/store -maxdepth 1 -type d -name '*musl-sysroot' 2>/dev/null | sort | head -1)"

[ -x "${CLANG:-}" ] || { echo "error: clang not found (set LOT_CLANG)" >&2; exit 1; }
[ -d "${SYSROOT:-}" ] || { echo "error: musl sysroot not found (set LOT_SYSROOT)" >&2; exit 1; }

mkdir -p "$PREFIX/include" "$PREFIX/lib"

if [ -f "$PREFIX/include/zlib.h" ] && [ -f "$PREFIX/lib/libz.a" ]; then
    echo "zlib already bootstrapped at $PREFIX"
    exit 0
fi

WORK="/tmp/lot-build-zlib-${VERSION}"
SRC_DIR="$WORK/src"
TARBALL="$WORK/zlib-${VERSION}.tar.gz"

rm -rf "$WORK"
mkdir -p "$SRC_DIR"

echo "==> zlib bootstrap"
echo "    version: $VERSION"
echo "    url:     $URL"
echo "    prefix:  $PREFIX"
echo "    clang:   $CLANG"
echo "    sysroot: $SYSROOT"

curl -L --fail -o "$TARBALL" "$URL"
tar xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1

cd "$SRC_DIR"

export CC="$CLANG -target wasm32 --sysroot=$SYSROOT -fuse-ld=lld"
export AR="$(find_llvm_tool llvm-ar)"
export RANLIB="$(find_llvm_tool llvm-ranlib)"

[ -x "$AR" ] || { echo "error: llvm-ar/ar not found" >&2; exit 1; }
[ -x "$RANLIB" ] || { echo "error: llvm-ranlib/ranlib not found" >&2; exit 1; }

CHOST=wasm32-unknown-linux-musl ./configure --static
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" libz.a

cp zlib.h zconf.h "$PREFIX/include/"
cp libz.a "$PREFIX/lib/"

echo "done: wrote $PREFIX/include/zlib.h"
echo "done: wrote $PREFIX/lib/libz.a"
