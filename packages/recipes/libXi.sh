#!/bin/sh
# Recipe: libXi — X Input Extension client library

NAME="libXi"
VERSION="1.8.2"
DESCRIPTION="X Input Extension client library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libXi-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/libXi-xorgproto"
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
    [ -f "/tmp/lot-build/libXfixes/stage/usr/lib/libXfixes.a" ] || {
        echo "Missing /tmp/lot-build/libXfixes staged library. Run ./packages/build-package.sh libXfixes first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/libXi-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    cp -R /tmp/lot-build/libX11/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXext/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXfixes/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -f /tmp/lot-build/libX11/stage/usr/lib/libX11.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXext/stage/usr/lib/libXext.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXfixes/stage/usr/lib/libXfixes.a "$DEPS_PREFIX/lib/"

    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = "--version" ]; then echo "1.0"; exit 0; fi' \
        'if [ "$1" = "--modversion" ]; then' \
        '  case "$2" in' \
        '    x11) echo "1.8.10" ;;' \
        '    xext) echo "1.3.6" ;;' \
        '    xfixes) echo "6.0.1" ;;' \
        '    xi) echo "1.8.2" ;;' \
        '    inputproto) echo "2.4.99.1" ;;' \
        '    *) echo "1.0" ;;' \
        '  esac' \
        '  exit 0' \
        'fi' \
        'if [ "$1" = "--exists" ] || [ "$1" = "--print-errors" ]; then exit 0; fi' \
        'if [ "$1" = "--cflags" ]; then echo "-I'"$XPROTO_SRC"'/include -I'"$DEPS_PREFIX"'/include"; exit 0; fi' \
        'if [ "$1" = "--libs" ]; then echo "-L'"$DEPS_PREFIX"'/lib -lXfixes -lXext -lX11"; exit 0; fi' \
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
        LIBS="$CRT1 -lc -lm $BUILTINS -lXfixes -lXext -lX11"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install
}
