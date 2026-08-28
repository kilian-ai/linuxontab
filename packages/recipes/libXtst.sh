#!/bin/sh
# Recipe: libXtst — X Test extension client library (record/replay)

NAME="libXtst"
VERSION="1.2.4"
DESCRIPTION="X Test extension client library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libXtst-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/libXtst-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    for dep in libX11 libXext libXi; do
        ls /tmp/lot-build/$dep/stage/usr/lib/*.a >/dev/null 2>&1 || {
            echo "Missing /tmp/lot-build/$dep staged library. Run ./packages/build-package.sh $dep first." >&2
            exit 1
        }
    done

    DEPS_PREFIX="/tmp/lot-build/libXtst-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    for dep in libX11 libXext libXi; do
        cp -Rn /tmp/lot-build/$dep/stage/usr/include/* "$DEPS_PREFIX/include/" 2>/dev/null || true
        cp -f /tmp/lot-build/$dep/stage/usr/lib/*.a "$DEPS_PREFIX/lib/" 2>/dev/null || true
    done

    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = "--version" ]; then echo "1.0"; exit 0; fi' \
        'if [ "$1" = "--modversion" ]; then' \
        '  case "$2" in' \
        '    x11) echo "1.8.10" ;;' \
        '    xext) echo "1.3.6" ;;' \
        '    xi) echo "1.8.1" ;;' \
        '    xtst|recordproto) echo "1.2.4" ;;' \
        '    *) echo "1.0" ;;' \
        '  esac' \
        '  exit 0' \
        'fi' \
        'if [ "$1" = "--exists" ] || [ "$1" = "--print-errors" ]; then exit 0; fi' \
        'if [ "$1" = "--cflags" ]; then echo "-I'"$XPROTO_SRC"'/include -I'"$DEPS_PREFIX"'/include"; exit 0; fi' \
        'if [ "$1" = "--libs" ]; then echo "-L'"$DEPS_PREFIX"'/lib -lXi -lXext -lX11"; exit 0; fi' \
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
        LIBS="$CRT1 -lc -lm $BUILTINS -lXi -lXext -lX11"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install
}
