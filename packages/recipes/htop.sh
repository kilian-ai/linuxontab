#!/bin/sh
# Recipe: htop — interactive process viewer
# The flagship "watch the wasm kernel work" app: meters + process table read
# straight from this kernel's /proc. Reuses the nano/mc ncursesw prefix.

NAME="htop"
VERSION="3.3.0"
DESCRIPTION="Interactive colorful process viewer (reads the wasm kernel's /proc)"
SOURCE_URL="https://github.com/htop-dev/htop/releases/download/3.3.0/htop-3.3.0.tar.xz"
SOURCE_SHA256=""

build() {
    # ── ncursesw: reuse any existing prefix (nano's, mc's, tmux's) ───────────
    NCURSES_STAGE=""
    for _p in /tmp/lot-build/nano-ncurses-prefix /tmp/lot-build/mc-ncurses-prefix /tmp/lot-build/tmux-ncurses-prefix; do
        [ -f "$_p/usr/lib/libncursesw.a" ] && { NCURSES_STAGE="$_p"; break; }
    done
    if [ -z "$NCURSES_STAGE" ]; then
        echo "==> no cached ncursesw prefix — build nano first (it creates one)"
        exit 1
    fi
    # configure is told ncursesw6 exists (cache var below) — provide the name
    [ -f "$NCURSES_STAGE/usr/lib/libncursesw6.a" ] ||
        cp "$NCURSES_STAGE/usr/lib/libncursesw.a" "$NCURSES_STAGE/usr/lib/libncursesw6.a"
    [ -d "$NCURSES_STAGE/usr/include/ncursesw" ] || {
        mkdir -p "$NCURSES_STAGE/usr/include/ncursesw"
        for _h in curses.h ncurses.h term.h termcap.h unctrl.h ncurses_dll.h; do
            [ -f "$NCURSES_STAGE/usr/include/$_h" ] && cp "$NCURSES_STAGE/usr/include/$_h" "$NCURSES_STAGE/usr/include/ncursesw/"
        done
    }

    # ── fork support (OpenFilesScreen/lsof popup forks) ─────────────────────
    # wasm-musl hides the fork decl and ships no impl; use the dynamic
    # asyncify fork thunk, same as the tmux/ash builds.
    WASM_FORK_C="$REPO_ROOT/sysroot/wasm_fork.c"
    FORK_DECLS="/tmp/lot-build/htop-fork-decls.h"
    mkdir -p /tmp/lot-build
    printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n' > "$FORK_DECLS"
    $CC $CFLAGS -c "$WASM_FORK_C" -o /tmp/lot-build/htop-wasm-fork.o
    # long-double compat: htop printf's floats everywhere (CPU%, loadavg);
    # the sysroot's ld80/binary128 mismatch makes %f recurse forever in
    # frexpl → stack overflow → "Segmentation fault". Link the fixed
    # primitives before -lc (same fix redis needed).
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_ld128.c" -o /tmp/lot-build/htop-ld128.o

    cd "$SRC"
    # Cross-compile cache: configure probes that would run wasm binaries.
    # htop's ncursesw detection: point it at our static lib directly.
    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --enable-unicode \
        --disable-sensors \
        --disable-capabilities \
        --disable-hwloc \
        --disable-delayacct \
        --disable-unwind \
        CC="$CC" \
        CFLAGS="$CFLAGS -include $FORK_DECLS -I$NCURSES_STAGE/usr/include -I$NCURSES_STAGE/usr/include/ncursesw" \
        LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608" \
        LIBS="/tmp/lot-build/htop-wasm-fork.o /tmp/lot-build/htop-ld128.o -L$NCURSES_STAGE/usr/lib -lncursesw $CRT1 -lc -lm $BUILTINS" \
        HTOP_NCURSES_CONFIG_SCRIPT=/bin/false \
        ac_cv_lib_ncursesw6_addnwstr=yes \
        ac_cv_lib_ncursesw_addnwstr=yes \
        ac_cv_file__proc_stat=yes \
        ac_cv_file__proc_meminfo=yes

    make -j4
    install -Dm755 htop "$STAGE/bin/htop"
}
