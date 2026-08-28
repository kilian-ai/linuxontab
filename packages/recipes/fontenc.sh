#!/bin/sh
# Recipe: fontenc - font encoding library used by libXfont2/Xorg

NAME="fontenc"
VERSION="1.1.8"
DESCRIPTION="Font encoding library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libfontenc-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/fontenc-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    [ -f "/tmp/lot-build/zlib/stage/usr/lib/libz.a" ] || {
        echo "Missing /tmp/lot-build/zlib staged library. Run ./packages/build-package.sh zlib first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/fontenc-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    cp -f /tmp/lot-build/zlib/stage/usr/include/zlib.h /tmp/lot-build/zlib/stage/usr/include/zconf.h "$DEPS_PREFIX/include/"
    cp -f /tmp/lot-build/zlib/stage/usr/lib/libz.a "$DEPS_PREFIX/lib/"

    cat > "$SRC/pkg-config" << 'EOF'
#!/bin/sh
case "$1" in
  --version|--modversion) echo "1.0"; exit 0 ;;
  --exists|--print-errors|--cflags|--libs) exit 0 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$SRC/pkg-config"

    export PKG_CONFIG="$SRC/pkg-config"

    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        CC="$CC" \
        CFLAGS="$CFLAGS -I$XPROTO_SRC/include -I$DEPS_PREFIX/include" \
        LDFLAGS="$LDFLAGS -L$DEPS_PREFIX/lib" \
        LIBS="$CRT1 -lz -lc -lm $BUILTINS"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install LIBS=""
}