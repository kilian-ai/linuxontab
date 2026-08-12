#!/bin/sh
# Recipe: tmux — terminal multiplexer
# Builds static libevent + reuses ncursesw (from the mc/nano build), then tmux.
#
# Runtime note: tmux forks a server (daemonizes) and a shell per pane, plus
# uses ptys + a unix socket. That's heavy on this NOMMU/asyncify fork model —
# the build is the first milestone; running is the real test.

NAME="tmux"
VERSION="3.5a"
DESCRIPTION="Terminal multiplexer"
SOURCE_URL="https://github.com/tmux/tmux/releases/download/${VERSION}/tmux-${VERSION}.tar.gz"
SOURCE_SHA256=""

NCURSES_VER="6.5"
NCURSES_URL="https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz"
LIBEVENT_VER="2.1.12-stable"
LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz"

build() {
    # ── 1. ncursesw (reuse the mc/nano prefix if present, else build) ────────
    NCURSES_STAGE="/tmp/lot-build/mc-ncurses-prefix"
    if [ ! -f "$NCURSES_STAGE/usr/lib/libncursesw.a" ]; then
        NCURSES_STAGE="/tmp/lot-build/tmux-ncurses-prefix"
        NCURSES_ARCHIVE="/tmp/lot-src-ncurses-${NCURSES_VER}.tar.gz"
        NCURSES_SRC="/tmp/lot-build/tmux-ncurses"
        if [ ! -f "$NCURSES_STAGE/usr/lib/libncursesw.a" ]; then
            [ -f "$NCURSES_ARCHIVE" ] || curl -L --fail -o "$NCURSES_ARCHIVE" "$NCURSES_URL"
            rm -rf "$NCURSES_SRC"; mkdir -p "$NCURSES_SRC"
            tar xzf "$NCURSES_ARCHIVE" -C "$NCURSES_SRC" --strip-components=1
            cd "$NCURSES_SRC"
            ./configure --host=wasm32-unknown-linux-musl --prefix=/usr \
                --without-shared --without-progs --without-manpages \
                --without-pkg-config --without-tests --without-cxx \
                --without-cxx-binding --without-ada --with-normal \
                --enable-widec --enable-overwrite \
                --with-default-terminfo-dir=/usr/share/terminfo \
                CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="-nostdlib" \
                LIBS="$CRT1 -lc $BUILTINS" AR="$AR" RANLIB="$RANLIB" \
                BUILD_CC="$(command -v gcc || command -v cc)"
            make -j4
            make DESTDIR="$NCURSES_STAGE" install.libs install.includes
        fi
    fi
    # tmux's configure wants the ncursesw/ header subdir + a plain libtinfo/curses name
    [ -d "$NCURSES_STAGE/usr/include/ncursesw" ] || {
        mkdir -p "$NCURSES_STAGE/usr/include/ncursesw"
        for _h in curses.h ncurses.h term.h termcap.h unctrl.h ncurses_dll.h; do
            [ -f "$NCURSES_STAGE/usr/include/$_h" ] && cp "$NCURSES_STAGE/usr/include/$_h" "$NCURSES_STAGE/usr/include/ncursesw/"
        done
    }
    [ -f "$NCURSES_STAGE/usr/lib/libtinfo.a" ] || cp "$NCURSES_STAGE/usr/lib/libncursesw.a" "$NCURSES_STAGE/usr/lib/libtinfo.a"

    # ── 2. libevent (static, no openssl) ─────────────────────────────────────
    LIBEVENT_STAGE="/tmp/lot-build/tmux-libevent-prefix"
    if [ ! -f "$LIBEVENT_STAGE/lib/libevent.a" ]; then
        LE_ARCHIVE="/tmp/lot-src-libevent-${LIBEVENT_VER}.tar.gz"
        LE_SRC="/tmp/lot-build/tmux-libevent"
        [ -f "$LE_ARCHIVE" ] || curl -L --fail -o "$LE_ARCHIVE" "$LIBEVENT_URL"
        rm -rf "$LE_SRC"; mkdir -p "$LE_SRC"
        tar xzf "$LE_ARCHIVE" -C "$LE_SRC" --strip-components=1
        cd "$LE_SRC"
        # Cross-compile cache: assume the kernel's epoll works (it does — see
        # wasm-kernel-async-fixes); AC_TRY_RUN can't run wasm on the host.
        ./configure \
            --host=wasm32-unknown-linux-musl \
            --prefix="$LIBEVENT_STAGE" \
            --disable-shared --enable-static \
            --disable-openssl \
            --disable-libevent-regress --disable-samples \
            --disable-debug-mode --disable-dependency-tracking \
            CC="$CC" CFLAGS="$CFLAGS" \
            LDFLAGS="-nostdlib" LIBS="$CRT1 -lc $BUILTINS" \
            AR="$AR" RANLIB="$RANLIB" \
            ac_cv_func_epoll_create1=yes \
            ac_cv_func_epoll_ctl=yes \
            ac_cv_header_sys_epoll_h=yes
        # 'make' first generates include/event2/event-config.h via a make rule
        # (not config.status), so build the default target — not just the .la.
        make -j4 || make libevent_core.la
        make install || {
            # manual install if libtool install trips on the cross target
            mkdir -p "$LIBEVENT_STAGE/lib" "$LIBEVENT_STAGE/include"
            cp .libs/libevent*.a "$LIBEVENT_STAGE/lib/" 2>/dev/null
            cp -R include/* "$LIBEVENT_STAGE/include/" 2>/dev/null
            cp *.h "$LIBEVENT_STAGE/include/" 2>/dev/null
        }
        # libtool ar's $LIBS (crt1.o + nested builtins.a) into the .a; macOS
        # llvm-ar then pads members to Darwin format -> corrupt wasm objects
        # ("malformed uleb128"). Rebuild each staged archive from the pristine
        # .libs/*.o with GNU-format ar. (Same fix as recipes/mc.sh.)
        # --disable-shared libtool keeps the real objects in the source root.
        # tmux only links libevent_core; rebuild it from all root objects
        # (over-inclusive is fine — gc-sections drops the unused).
        rm -f "$LIBEVENT_STAGE/lib/libevent_core.a"
        "$AR" --format=gnu crs "$LIBEVENT_STAGE/lib/libevent_core.a" "$LE_SRC"/*.o
        "$RANLIB" "$LIBEVENT_STAGE/lib/libevent_core.a"
    fi

    # ── 3. fork support ──────────────────────────────────────────────────────
    # tmux forks (server daemonize + per-pane shells). wasm-musl hides the
    # fork/vfork decls and ships no implementation; the dynamic asyncify fork
    # thunk (sysroot/wasm_fork.c, same as the ash build) provides a real fork.
    # $REPO_ROOT is exported by build-package.sh
    WASM_FORK_C="$REPO_ROOT/sysroot/wasm_fork.c"
    [ -f "$WASM_FORK_C" ] || WASM_FORK_C="/Users/kilian/.ai/LinuxOnTab-kernel/sysroot/wasm_fork.c"
    FORK_DECLS="/tmp/lot-build/tmux-fork-decls.h"
    mkdir -p /tmp/lot-build
    printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n' > "$FORK_DECLS"
    $CC $CFLAGS -c "$WASM_FORK_C" -o /tmp/lot-build/tmux-wasm-fork.o

    # ── 4. tmux ──────────────────────────────────────────────────────────────
    cd "$SRC"
    # jail pkg-config to OUR staged libevent (else homebrew's macOS libevent
    # headers leak in via PKG_CHECK_MODULES: kqueue config = wrong platform)
    export PKG_CONFIG_LIBDIR="$LIBEVENT_STAGE/lib/pkgconfig"
    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-utf8proc \
        --disable-systemd \
        CC="$CC" \
        CFLAGS="$CFLAGS -include $FORK_DECLS -I$NCURSES_STAGE/usr/include -I$NCURSES_STAGE/usr/include/ncursesw -I$LIBEVENT_STAGE/include" \
        LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608" \
        LIBS="/tmp/lot-build/tmux-wasm-fork.o -L$LIBEVENT_STAGE/lib -levent_core -L$NCURSES_STAGE/usr/lib -lncursesw $CRT1 -lc -lm $BUILTINS" \
        LIBEVENT_CFLAGS="-I$LIBEVENT_STAGE/include" \
        LIBEVENT_LIBS="-L$LIBEVENT_STAGE/lib -levent_core" \
        LIBNCURSES_CFLAGS="-I$NCURSES_STAGE/usr/include" \
        LIBNCURSES_LIBS="-L$NCURSES_STAGE/usr/lib -lncursesw" \
        AR="$AR" RANLIB="$RANLIB"

    # configure selects compat/forkpty-linux.c (host is *-linux-*) but tmux
    # doesn't ship it (musl normally provides forkpty; ours dropped it since
    # it calls fork()). Provide it: openpty + our fork thunk + login_tty.
    cat > compat/forkpty-linux.c <<'FPEOF'
#include <sys/types.h>
#include <pty.h>
#include <utmp.h>
#include <unistd.h>
#include <string.h>
#include <termios.h>
#include "compat.h"

pid_t
forkpty(int *master, char *name, struct termios *tio, struct winsize *ws)
{
	int slave;
	pid_t pid;

	if (openpty(master, &slave, name, tio, ws) == -1)
		return (-1);
	switch (pid = fork()) {
	case -1:
		close(*master);
		close(slave);
		return (-1);
	case 0:
		close(*master);
		login_tty(slave);
		return (0);
	}
	close(slave);
	return (pid);
}
FPEOF

    make -j4
    install -Dm755 tmux "$STAGE/bin/tmux"
}
