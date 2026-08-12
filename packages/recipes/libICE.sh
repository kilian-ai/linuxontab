#!/bin/sh
# Recipe: libICE — Inter-Client Exchange library

NAME="libICE"
VERSION="1.1.2"
DESCRIPTION="Inter-Client Exchange library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libICE-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/libICE-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    [ -f "/tmp/lot-build/xtrans/stage/usr/include/X11/Xtrans/Xtrans.h" ] || {
        echo "Missing /tmp/lot-build/xtrans staged headers. Run ./packages/build-package.sh xtrans first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/libICE-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    cp -R /tmp/lot-build/xtrans/stage/usr/include/* "$DEPS_PREFIX/include/"
    mkdir -p "$DEPS_PREFIX/include/X11/Xtrans"
    cp -f /tmp/lot-build/xtrans/src/*.c /tmp/lot-build/xtrans/src/*.h "$DEPS_PREFIX/include/X11/Xtrans/"

    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = "--version" ]; then echo "1.0"; exit 0; fi' \
        'if [ "$1" = "--modversion" ]; then' \
        '  case "$2" in' \
        '    xtrans) echo "1.6.0" ;;' \
        '    ice) echo "1.1.2" ;;' \
        '    *) echo "1.0" ;;' \
        '  esac' \
        '  exit 0' \
        'fi' \
        'if [ "$1" = "--exists" ] || [ "$1" = "--print-errors" ]; then exit 0; fi' \
        'if [ "$1" = "--cflags" ]; then echo "-I'"$XPROTO_SRC"'/include -I'"$DEPS_PREFIX"'/include"; exit 0; fi' \
        'if [ "$1" = "--libs" ]; then echo ""; exit 0; fi' \
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
        LDFLAGS="$LDFLAGS" \
        LIBS="$CRT1 -lc -lm $BUILTINS"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install
}
