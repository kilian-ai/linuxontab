#!/usr/bin/env sh
# build-xfonttest.sh — build the xtiny font-support test client against the
# staged X libs (run ./packages/build-package.sh libX11 libxcb libXau xeyes
# first if /tmp/lot-build is empty).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

CLANG="${LOT_CLANG:-/nix/store/sa4f4iaw4zmkdnfiidjpys8dlgkzridc-clang/bin/clang}"
SYSROOT="${LOT_SYSROOT:-$DIR/toolchain/musl-sysroot-fixed}"
DIR_LD="${LOT_LLD_DIR:-/nix/store/l62m9j22mhh21n6w9g3rzb5f8kp55f8a-lld-19.1.7/bin}"
WASM_OPT="${LOT_WASM_OPT:-$(command -v wasm-opt || echo /opt/homebrew/bin/wasm-opt)}"
DEBUGFS="${LOT_DEBUGFS:-/opt/homebrew/opt/e2fsprogs/sbin/debugfs}"
DEPS=/tmp/lot-build/xeyes-deps-prefix
XPROTO=/tmp/lot-build/xeyes-xorgproto

[ -d "$DEPS" ] || { echo "staged X libs missing — build xeyes first"; exit 1; }

PATH="$DIR_LD:$PATH" "$CLANG" -target wasm32 --sysroot="$SYSROOT" \
    -fuse-ld=lld -static -O1 \
    -I"$XPROTO/include" -I"$DEPS/include" \
    -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
    -Wl,--export=__heap_base -Wl,--export=__data_end \
    -Wl,--shared-memory -Wl,--max-memory=268435456 \
    -o /tmp/xfonttest xfonttest.c \
    -L"$DEPS/lib" -lX11 -lX11-xcb -lxcb -lXau -lX11compat
"$WASM_OPT" --asyncify -O1 /tmp/xfonttest -o rootfs/usr/local/bin/xfonttest
chmod +x rootfs/usr/local/bin/xfonttest
"$DEBUGFS" -w -R "rm /usr/local/bin/xfonttest" shell/linux-dist/rootfs.ext4 >/dev/null 2>&1 || true
"$DEBUGFS" -w -R "write rootfs/usr/local/bin/xfonttest /usr/local/bin/xfonttest" shell/linux-dist/rootfs.ext4 2>&1 | grep -v debugfs || true
"$DEBUGFS" -w -R "sif /usr/local/bin/xfonttest mode 0100755" shell/linux-dist/rootfs.ext4 >/dev/null 2>&1
echo "xfonttest installed ($(wc -c < rootfs/usr/local/bin/xfonttest | tr -d ' ') bytes)"
