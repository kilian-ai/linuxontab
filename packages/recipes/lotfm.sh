#!/bin/sh
# Recipe: lotfm — tiny two-pane file manager for the LinuxOnTab guest
#
# Written for this target because ncurses initscr() is broken on wasm32
# (call_indirect signature traps deep in the library — see recipes/mc.sh
# notes). lotfm uses raw ANSI escapes + termios only; no dependencies
# beyond musl. Source lives in-repo: packages/src/lotfm.c

NAME="lotfm"
VERSION="1.0"
DESCRIPTION="Tiny two-pane file manager (ANSI/termios, no ncurses)"
SOURCE_URL="file:///Users/kilian/.ai/LinuxOnTab-kernel/packages/lotfm-src-1.0.tar.gz"
SOURCE_SHA256=""

build() {
    SRC_C="$SRC/lotfm.c"

    # shellcheck disable=SC2086
    $CC $CFLAGS $LDFLAGS -o lotfm "$SRC_C" $CRT1 -lc $BUILTINS
    install -Dm755 lotfm "$STAGE/bin/lotfm"
}
