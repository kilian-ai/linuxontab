#!/bin/sh
# Recipe: xtiny — the tiny X11 server + desktop (xtiny.c on librfb) for the
# lean image. Serves X on :1 and the desktop over RFB on :5900 (top bar →
# X display). Built from this repo's sources, the same way build-vnc-demos.sh
# builds the full-image copy.

NAME="xtiny"
VERSION="1.0.2"
DESCRIPTION="Tiny X11 server + desktop on :5900 for real X clients (xterm, xeyes, wolf3d); open the X display panel"
SOURCE_URL="local:"
DEPENDS="xterm xeyes"

build() {
    cd "$REPO_ROOT"
    # fork() for the taskbar launcher: musl omits it on wasm32, the kernel
    # provides it via asyncify (sysroot/wasm_fork.c). dlmalloc: frame and
    # RRE buffers pass 128 KB, where musl mallocng needs mmap and traps.
    $CC $CFLAGS -o "$SRC/xtiny" librfb.c xtiny.c sysroot/wasm_fork.c sysroot/wasm_dlmalloc.c \
        $LDFLAGS -Wl,-z,stack-size=8388608 $CRT1 -lc $BUILTINS \
        || { echo "xtiny build failed" >&2; exit 1; }
    mkdir -p "$STAGE/usr/local/bin"
    install -m755 "$SRC/xtiny" "$STAGE/usr/local/bin/xtiny"
    rmdir "$STAGE/bin" 2>/dev/null || true
}
