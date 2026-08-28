#!/bin/sh
# Recipe: libXext — miscellaneous X extension client library

NAME="libXext"
VERSION="1.3.6"
DESCRIPTION="X11 miscellaneous extension library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libXext-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/libXext-xorgproto"
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
    [ -f "/tmp/lot-build/libXau/stage/usr/include/X11/Xauth.h" ] || {
        echo "Missing /tmp/lot-build/libXau staged headers. Run ./packages/build-package.sh libXau first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/libXext-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    cp -R /tmp/lot-build/libX11/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -f /tmp/lot-build/libX11/stage/usr/lib/libX11.a "$DEPS_PREFIX/lib/"
    cp -R /tmp/lot-build/libXau/stage/usr/include/* "$DEPS_PREFIX/include/"

    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = "--version" ]; then echo "1.0"; exit 0; fi' \
        'if [ "$1" = "--modversion" ]; then' \
        '  case "$2" in' \
        '    x11) echo "1.8.10" ;;' \
        '    xproto|xextproto) echo "7.0.31" ;;' \
        '    *) echo "1.0" ;;' \
        '  esac' \
        '  exit 0' \
        'fi' \
        'if [ "$1" = "--exists" ] || [ "$1" = "--print-errors" ]; then exit 0; fi' \
        'if [ "$1" = "--cflags" ]; then echo "-I'"$XPROTO_SRC"'/include -I'"$DEPS_PREFIX"'/include"; exit 0; fi' \
        'if [ "$1" = "--libs" ]; then echo "-L'"$DEPS_PREFIX"'/lib -lX11"; exit 0; fi' \
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
        --disable-xextproto \
        CC="$CC" \
        CFLAGS="$CFLAGS -O0 -I$XPROTO_SRC/include -I$DEPS_PREFIX/include" \
        LDFLAGS="$LDFLAGS -L$DEPS_PREFIX/lib" \
        LIBS="$CRT1 -lc -lm $BUILTINS -lX11"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install
}
