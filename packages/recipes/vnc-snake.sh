#!/bin/sh
# Recipe: vnc-snake — librfb demo app for the lean image (serves the X display
# panel on :5900; run it instead of xtiny, they share the port). Built from
# this repo's sources, the same way build-vnc-demos.sh builds the
# full-image copy.

NAME="vnc-snake"
VERSION="1.0.2"   # 1.0.2: fixed-brk sysroot, heap no longer capped at ~60 MB
DESCRIPTION="VNC demo: snake game on the X display (arrows/WASD, p pause, r restart)"
SOURCE_URL="local:"

build() {
    cd "$REPO_ROOT"
    # dlmalloc: librfb's frame and RRE buffers pass 128 KB, where musl
    # mallocng needs mmap and traps (SIGSEGV) on free/realloc.
    $CC $CFLAGS -o "$SRC/vnc-snake" librfb.c vnc-snake.c sysroot/wasm_dlmalloc.c \
        $LDFLAGS -Wl,-z,stack-size=8388608 $CRT1 -lc $BUILTINS \
        || { echo "vnc-snake build failed" >&2; exit 1; }
    mkdir -p "$STAGE/usr/local/bin"
    install -m755 "$SRC/vnc-snake" "$STAGE/usr/local/bin/vnc-snake"
    rmdir "$STAGE/bin" 2>/dev/null || true
}
