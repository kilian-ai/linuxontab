#!/bin/sh
# Recipe: vnc-server — librfb demo app for the lean image (serves the X display
# panel on :5900; run it instead of xtiny, they share the port). Built from
# this repo's sources, the same way build-vnc-demos.sh builds the
# full-image copy.

NAME="vnc-server"
VERSION="1.0.1"
DESCRIPTION="VNC demo: eyes that follow your mouse (open the X display panel)"
SOURCE_URL="local:"

build() {
    cd "$REPO_ROOT"
    # dlmalloc: librfb's frame and RRE buffers pass 128 KB, where musl
    # mallocng needs mmap and traps (SIGSEGV) on free/realloc.
    $CC $CFLAGS -o "$SRC/vnc-server" librfb.c vnc-server.c sysroot/wasm_dlmalloc.c \
        $LDFLAGS -Wl,-z,stack-size=8388608 $CRT1 -lc $BUILTINS \
        || { echo "vnc-server build failed" >&2; exit 1; }
    mkdir -p "$STAGE/usr/local/bin"
    install -m755 "$SRC/vnc-server" "$STAGE/usr/local/bin/vnc-server"
    rmdir "$STAGE/bin" 2>/dev/null || true
}
