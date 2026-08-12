#!/usr/bin/env sh
# build-vnc-demos.sh — build the librfb demo apps (vnc-server, vnc-snake)
# for wasm32-linux-musl, asyncify them, install into rootfs/, and swap
# them into shell/linux-dist/rootfs.ext4 via debugfs.
#
# Usage:
#   ./build-vnc-demos.sh              # build + install all apps
#   ./build-vnc-demos.sh vnc-snake    # just one app
#   SKIP_EXT4=1 ./build-vnc-demos.sh  # skip the rootfs.ext4 swap
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

CLANG="${LOT_CLANG:-/nix/store/sa4f4iaw4zmkdnfiidjpys8dlgkzridc-clang/bin/clang}"
SYSROOT="${LOT_SYSROOT:-$DIR/toolchain/musl-sysroot-fixed}"
DIR_LD="${LOT_LLD_DIR:-/nix/store/l62m9j22mhh21n6w9g3rzb5f8kp55f8a-lld-19.1.7/bin}"
WASM_OPT="${LOT_WASM_OPT:-$(command -v wasm-opt || echo /opt/homebrew/bin/wasm-opt)}"
DEBUGFS="${LOT_DEBUGFS:-/opt/homebrew/opt/e2fsprogs/sbin/debugfs}"
EXT4="$DIR/shell/linux-dist/rootfs.ext4"

[ -x "$CLANG" ]    || { echo "clang not found: $CLANG (set LOT_CLANG=)"; exit 1; }
[ -d "$SYSROOT" ]  || { echo "sysroot not found: $SYSROOT (set LOT_SYSROOT=)"; exit 1; }
[ -x "$WASM_OPT" ] || { echo "wasm-opt not found (brew install binaryen)"; exit 1; }

APPS="${*:-vnc-server vnc-snake xtiny}"

for app in $APPS; do
    echo "==> $app"
    # xtiny's taskbar launches apps, so it needs fork() — which musl omits
    # for wasm32; the kernel provides it via asyncify.
    EXTRA_SRC=""
    [ "$app" = "xtiny" ] && EXTRA_SRC="sysroot/wasm_fork.c"
    PATH="$DIR_LD:$PATH" "$CLANG" -target wasm32 --sysroot="$SYSROOT" \
        -fuse-ld=lld -static -O2 \
        -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
        -Wl,--export=__heap_base -Wl,--export=__data_end \
        -Wl,--shared-memory -Wl,--max-memory=268435456 \
        -o "/tmp/$app" librfb.c "$app.c" $EXTRA_SRC
    "$WASM_OPT" --asyncify -O1 "/tmp/$app" -o "rootfs/usr/local/bin/$app"
    chmod +x "rootfs/usr/local/bin/$app"
    echo "    rootfs/usr/local/bin/$app ($(wc -c < "rootfs/usr/local/bin/$app" | tr -d ' ') bytes)"

    if [ -z "$SKIP_EXT4" ]; then
        [ -x "$DEBUGFS" ] || { echo "debugfs not found (brew install e2fsprogs)"; exit 1; }
        "$DEBUGFS" -w -R "rm /usr/local/bin/$app" "$EXT4" >/dev/null 2>&1 || true
        "$DEBUGFS" -w -R "write rootfs/usr/local/bin/$app /usr/local/bin/$app" "$EXT4" 2>&1 | grep -v debugfs || true
        "$DEBUGFS" -w -R "sif /usr/local/bin/$app mode 0100755" "$EXT4" >/dev/null 2>&1
        echo "    swapped into rootfs.ext4"
    fi
done
echo "Done."
