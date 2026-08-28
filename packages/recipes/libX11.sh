#!/bin/sh
# Recipe: libX11 — core X11 client-side library

NAME="libX11"
VERSION="1.8.10"
DESCRIPTION="Core X11 client-side library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libX11-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/libX11-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    [ -f "/tmp/lot-build/libxcb/stage/usr/lib/libxcb.a" ] || {
        echo "Missing /tmp/lot-build/libxcb staged library. Run ./packages/build-package.sh libxcb first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/xtrans/stage/usr/include/X11/Xtrans/Xtrans.h" ] || {
        echo "Missing /tmp/lot-build/xtrans staged headers. Run ./packages/build-package.sh xtrans first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/libX11-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    cp -R /tmp/lot-build/libxcb/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -f /tmp/lot-build/libxcb/stage/usr/lib/libxcb.a "$DEPS_PREFIX/lib/"
    cp -R /tmp/lot-build/xtrans/stage/usr/include/* "$DEPS_PREFIX/include/"
    mkdir -p "$DEPS_PREFIX/include/X11/Xtrans"
    cp -f /tmp/lot-build/xtrans/src/*.c /tmp/lot-build/xtrans/src/*.h "$DEPS_PREFIX/include/X11/Xtrans/"

    printf '%s\n' \
        '#ifndef _X11_XPOLL_H_' \
        '#define _X11_XPOLL_H_' \
        '' \
        '#include <poll.h>' \
        '' \
        '#endif' \
        > "$DEPS_PREFIX/include/X11/Xpoll.h"

    printf '%s\n' \
        '#!/bin/sh' \
        'for arg in "$@"; do' \
        '  case "$arg" in' \
        '    --variable=xcbincludedir) echo "'"$DEPS_PREFIX"'/include"; exit 0 ;;' \
        '    --variable=pythondir) echo ""; exit 0 ;;' \
        '  esac' \
        'done' \
        'if [ "$1" = "--version" ]; then echo "1.0"; exit 0; fi' \
        'if [ "$1" = "--modversion" ]; then' \
        '  case "$2" in' \
        '    xcb) echo "1.17.0" ;;' \
        '    xtrans) echo "1.6.0" ;;' \
        '    *) echo "1.0" ;;' \
        '  esac' \
        '  exit 0' \
        'fi' \
        'if [ "$1" = "--exists" ] || [ "$1" = "--print-errors" ]; then exit 0; fi' \
        'if [ "$1" = "--cflags" ]; then echo "-I'"$XPROTO_SRC"'/include -I'"$DEPS_PREFIX"'/include"; exit 0; fi' \
        'if [ "$1" = "--libs" ]; then echo "-L'"$DEPS_PREFIX"'/lib -lxcb"; exit 0; fi' \
        'exit 0' \
        > "$SRC/pkg-config"
    chmod +x "$SRC/pkg-config"

    export PKG_CONFIG="$SRC/pkg-config"

    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --enable-malloc0returnsnull \
        --disable-xlocale \
        --disable-loadable-i18n \
        --disable-xcms \
        --disable-xkb \
        --disable-xf86bigfont \
        --disable-composecache \
        --with-keysymdefdir="$XPROTO_SRC/include/X11" \
        --without-xmlto \
        CC="$CC" \
        CFLAGS="$CFLAGS -O0 -I$XPROTO_SRC/include -I$DEPS_PREFIX/include" \
        LDFLAGS="$LDFLAGS -L$DEPS_PREFIX/lib" \
        LIBS="$CRT1 -lc -lm $BUILTINS -lxcb"

    # In wasm builds, ximcp/i18n objects can exceed section-size limits.
    # Keep core X11 by skipping i18n module subdir builds.
    perl -0777 -i -pe 's/^SUBDIRS = im lc om$/SUBDIRS = lc om/m' "$SRC/modules/Makefile"
    perl -0777 -i -pe 's/^SUBDIRS = util xcms xlibi18n \$\(XKB_SUBDIRS\)$/SUBDIRS = util \$\(XKB_SUBDIRS\)/m' "$SRC/src/Makefile"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install
}
