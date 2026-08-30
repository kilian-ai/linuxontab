#!/bin/sh
# Recipe: vitetris — colorful terminal Tetris
# No ncurses: the ANSI backend draws with raw escapes + termios, which the
# guest pty + xterm.js render natively. We skip its configure script (it
# compiles AND RUNS host probes) and write config.mk directly; the Makefile
# then generates src/src-conf.mk from it.

NAME="vitetris"
VERSION="0.59.1"
DESCRIPTION="Terminal Tetris — colors, 30 block styles, high scores"
SOURCE_URL="https://github.com/vicgeralds/vitetris/archive/refs/tags/v0.59.1.tar.gz"
SOURCE_SHA256=""

build() {
    cd "$SRC"
    cat > config.mk <<EOF
prefix = /usr
bindir = \$(prefix)/bin
datarootdir = \$(prefix)/share
docdir     = \$(datarootdir)/doc/vitetris
pixmapdir  = \$(datarootdir)/pixmaps
desktopdir = \$(datarootdir)/applications
datadir = \$(datarootdir)/allegro

UNIX = y
TWOPLAYER = y
TERM_RESIZING = y
MENU = y
BLOCKSTYLES = y

INPUT_SYS = unixterm

CC = $CC
# gnu89: vitetris is old-school C (implicit int etc.) that clang 16+ hard-errors under C99
CFLAGS = $CFLAGS -std=gnu89
LDFLAGS = $LDFLAGS -Wl,-z,stack-size=8388608
LDLIBS = $CRT1 -lc $BUILTINS
EOF
    # NETWORK/JOYSTICK/CURSES deliberately unset (sockets + /dev/js + ncurses
    # all unneeded); TTY_SOCKET off with network. `strip --strip-all` in the
    # build target is host-strip on a wasm binary — it's prefixed with '-' in
    # the Makefile, so its failure is ignored.
    #
    # The sub-Makefiles hardcode `ar rs` — macOS system ar pads members to
    # Darwin format, corrupting wasm objects ("section too large"; same bug
    # as the mc/tmux archives). Shim `ar` to GNU-format llvm-ar via PATH.
    mkdir -p /tmp/lot-build/vitetris-bin
    printf '#!/bin/sh\nexec %s --format=gnu "$@"\n' "$AR" > /tmp/lot-build/vitetris-bin/ar
    chmod +x /tmp/lot-build/vitetris-bin/ar
    PATH="/tmp/lot-build/vitetris-bin:$PATH" make build
    install -Dm755 tetris "$STAGE/bin/tetris"
}
