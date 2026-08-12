#!/bin/sh
# Recipe: nano — GNU nano text editor
# Builds static ncurses-6.5 (wasm32) inline as a dependency, then builds nano.

NAME="nano"
VERSION="8.3"
DESCRIPTION="Small and friendly text editor"
SOURCE_URL="https://ftp.gnu.org/gnu/nano/nano-8.3.tar.gz"
SOURCE_SHA256=""  # filled after first download

NCURSES_VER="6.5"
NCURSES_URL="https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz"

build() {
    # ── 1. Build static ncurses for wasm32 ──────────────────────────────────
    NCURSES_ARCHIVE="/tmp/lot-src-ncurses-${NCURSES_VER}.tar.gz"
    NCURSES_SRC="/tmp/lot-build/nano-ncurses"
    NCURSES_STAGE="/tmp/lot-build/nano-ncurses-prefix"

    if [ ! -d "$NCURSES_STAGE/usr/include/ncursesw" ]; then
        if [ ! -f "$NCURSES_ARCHIVE" ]; then
            echo "==> Downloading ncurses $NCURSES_VER"
            curl -L --fail -o "$NCURSES_ARCHIVE" "$NCURSES_URL"
        fi
        rm -rf "$NCURSES_SRC"
        mkdir -p "$NCURSES_SRC"
        tar xzf "$NCURSES_ARCHIVE" -C "$NCURSES_SRC" --strip-components=1

        cd "$NCURSES_SRC"
        BUILD_CC="$(command -v gcc || command -v cc || echo gcc)"
        ./configure \
            --host=wasm32-unknown-linux-musl \
            --prefix=/usr \
            --without-shared \
            --without-progs \
            --without-manpages \
            --without-pkg-config \
            --without-tests \
            --without-cxx \
            --without-cxx-binding \
            --without-ada \
            --with-normal \
            --enable-widec \
            --enable-overwrite \
            --with-default-terminfo-dir=/usr/share/terminfo \
            --with-terminfo-dirs=/usr/share/terminfo:/lib/terminfo:/etc/terminfo \
            CC="$CC" \
            CFLAGS="$CFLAGS" \
            LDFLAGS="-nostdlib" \
            LIBS="$CRT1 -lc $BUILTINS" \
            AR="$AR" \
            RANLIB="$RANLIB" \
            BUILD_CC="$BUILD_CC"
        make -j4
        # Use install.libs + install.includes to skip the terminfo database
        # installation step (run_tic.sh uses macOS tic which fails on modern
        # terminfo.src entries like mintty).
        make DESTDIR="$NCURSES_STAGE" install.libs install.includes
    fi
    # nano's configure appends a bare -lncurses; alias the wide lib
    [ -f "$NCURSES_STAGE/usr/lib/libncurses.a" ] ||         cp "$NCURSES_STAGE/usr/lib/libncursesw.a" "$NCURSES_STAGE/usr/lib/libncurses.a"

    # ── Bundle terminfo data for the guest ──────────────────────────────────
    # macOS tic fails on modern terminfo.src (extended caps), so we use the
    # system terminfo database (infocmp → tic round-trip) for the terminals
    # we care about. These are platform-independent binary terminfo files.
    TERMINFO_STAGE="$STAGE/usr/share/terminfo"
    if [ ! -d "$TERMINFO_STAGE" ]; then
        mkdir -p "$TERMINFO_STAGE"
        for _t in xterm-256color xterm vt100 vt102; do
            /usr/bin/infocmp -x "$_t" 2>/dev/null | \
                /usr/bin/tic -x -o "$TERMINFO_STAGE" - 2>/dev/null || true
        done
        # compile 'linux' console terminfo from ncurses source (not in macOS)
        if [ -f "$NCURSES_SRC/misc/terminfo.src" ]; then
            grep -A200 '^linux,' "$NCURSES_SRC/misc/terminfo.src" | \
                awk '/^linux,/{found=1} found{print; if(/^$/ && NR>1){exit}}' | \
                /usr/bin/tic -o "$TERMINFO_STAGE" - 2>/dev/null || true
        fi
        # macOS tic writes hashed dirs by hex byte (e.g. 76/vt100, 78/xterm).
        # Linux ncurses typically searches first-letter dirs (v/, x/), so
        # duplicate entries into that layout for guest runtime lookup.
        mkdir -p "$TERMINFO_STAGE/v" "$TERMINFO_STAGE/x"
        [ -f "$TERMINFO_STAGE/76/vt100" ] && cp -f "$TERMINFO_STAGE/76/vt100" "$TERMINFO_STAGE/v/vt100"
        [ -f "$TERMINFO_STAGE/76/vt100-am" ] && cp -f "$TERMINFO_STAGE/76/vt100-am" "$TERMINFO_STAGE/v/vt100-am"
        [ -f "$TERMINFO_STAGE/76/vt102" ] && cp -f "$TERMINFO_STAGE/76/vt102" "$TERMINFO_STAGE/v/vt102"
        [ -f "$TERMINFO_STAGE/78/xterm" ] && cp -f "$TERMINFO_STAGE/78/xterm" "$TERMINFO_STAGE/x/xterm"
        [ -f "$TERMINFO_STAGE/78/xterm-256color" ] && cp -f "$TERMINFO_STAGE/78/xterm-256color" "$TERMINFO_STAGE/x/xterm-256color"
    fi

    # ── 2. Build nano ────────────────────────────────────────────────────────
    cd "$SRC"
    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-nls \
        --disable-browser \
        --enable-tiny \
        CC="$CC" \
        CFLAGS="$CFLAGS -I$NCURSES_STAGE/usr/include" \
        LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608" \
        LIBS="-L$NCURSES_STAGE/usr/lib -lncursesw $CRT1 -lc -lm $BUILTINS"

    make -j4
    install -Dm755 src/nano "$STAGE/bin/nano"
}
