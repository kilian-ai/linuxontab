#!/bin/sh
# Recipe: libXmu — X miscellaneous utilities library

NAME="libXmu"
VERSION="1.2.1"
DESCRIPTION="X miscellaneous utilities library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libXmu-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/libXmu-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    [ -f "/tmp/lot-build/libX11/stage/usr/lib/libX11.a" ] || {
        echo "Missing /tmp/lot-build/libX11 staged library. Run ./packages/build-package.sh libX11 first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXext/stage/usr/lib/libXext.a" ] || {
        echo "Missing /tmp/lot-build/libXext staged library. Run ./packages/build-package.sh libXext first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXt/stage/usr/lib/libXt.a" ] || {
        echo "Missing /tmp/lot-build/libXt staged library. Run ./packages/build-package.sh libXt first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/libXmu-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    cp -R /tmp/lot-build/libX11/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXext/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXt/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libSM/stage/usr/include/* "$DEPS_PREFIX/include/" 2>/dev/null || true
    cp -R /tmp/lot-build/libICE/stage/usr/include/* "$DEPS_PREFIX/include/" 2>/dev/null || true
    printf '%s\n' \
        '#ifndef _X11_XPOLL_H_' \
        '#define _X11_XPOLL_H_' \
        '' \
        '#include <poll.h>' \
        '' \
        '#endif' \
        > "$DEPS_PREFIX/include/X11/Xpoll.h"
    cp -f /tmp/lot-build/libX11/stage/usr/lib/libX11.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXext/stage/usr/lib/libXext.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXt/stage/usr/lib/libXt.a "$DEPS_PREFIX/lib/"
    [ -f /tmp/lot-build/libSM/stage/usr/lib/libSM.a ] && cp -f /tmp/lot-build/libSM/stage/usr/lib/libSM.a "$DEPS_PREFIX/lib/" || true
    [ -f /tmp/lot-build/libICE/stage/usr/lib/libICE.a ] && cp -f /tmp/lot-build/libICE/stage/usr/lib/libICE.a "$DEPS_PREFIX/lib/" || true

    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = "--version" ]; then echo "1.0"; exit 0; fi' \
        'if [ "$1" = "--modversion" ]; then' \
        '  case "$2" in' \
        '    x11) echo "1.8.10" ;;' \
        '    xext) echo "1.3.6" ;;' \
        '    xt) echo "1.3.1" ;;' \
        '    xmu) echo "1.2.1" ;;' \
        '    *) echo "1.0" ;;' \
        '  esac' \
        '  exit 0' \
        'fi' \
        'if [ "$1" = "--exists" ] || [ "$1" = "--print-errors" ]; then exit 0; fi' \
        'if [ "$1" = "--cflags" ]; then echo "-I'"$XPROTO_SRC"'/include -I'"$DEPS_PREFIX"'/include"; exit 0; fi' \
        'if [ "$1" = "--libs" ]; then echo "-L'"$DEPS_PREFIX"'/lib -lXt -lXext -lX11 -lSM -lICE"; exit 0; fi' \
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
        CC="$CC" \
        CFLAGS="$CFLAGS -O0 -I$XPROTO_SRC/include -I$DEPS_PREFIX/include" \
        LDFLAGS="$LDFLAGS -L$DEPS_PREFIX/lib" \
        LIBS="$CRT1 -lc -lm $BUILTINS -lXt -lXext -lX11 -lSM -lICE"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install
}
