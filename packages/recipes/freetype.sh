#!/bin/sh
# Recipe: freetype - font rasterizer used by libXfont2/Xorg

NAME="freetype"
VERSION="2.13.3"
DESCRIPTION="Font rasterization library"
SOURCE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${VERSION}.tar.gz"
SOURCE_SHA256=""

build() {
    cd "$SRC"

    [ -f "/tmp/lot-build/zlib/stage/usr/lib/libz.a" ] || {
        echo "Missing /tmp/lot-build/zlib staged library. Run ./packages/build-package.sh zlib first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/freetype-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    cp -f /tmp/lot-build/zlib/stage/usr/include/zlib.h /tmp/lot-build/zlib/stage/usr/include/zconf.h "$DEPS_PREFIX/include/"
    cp -f /tmp/lot-build/zlib/stage/usr/lib/libz.a "$DEPS_PREFIX/lib/"

    cat > "$SRC/pkg-config" << EOF
#!/bin/sh
if [ "\$1" = "--version" ]; then echo "1.0"; exit 0; fi
if [ "\$1" = "--modversion" ]; then
  case "\$2" in
    zlib) echo "1.3.2" ;;
    *) echo "1.0" ;;
  esac
  exit 0
fi
if [ "\$1" = "--exists" ] || [ "\$1" = "--print-errors" ]; then exit 0; fi
if [ "\$1" = "--cflags" ]; then echo "-I$DEPS_PREFIX/include"; exit 0; fi
if [ "\$1" = "--libs" ]; then echo "-L$DEPS_PREFIX/lib -lz"; exit 0; fi
exit 0
EOF
    chmod +x "$SRC/pkg-config"

    export PKG_CONFIG="$SRC/pkg-config"

    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --disable-mmap \
        --with-zlib=yes \
        --with-bzip2=no \
        --with-png=no \
        --with-harfbuzz=no \
        --with-brotli=no \
        CC="$CC" \
        CFLAGS="$CFLAGS -I$DEPS_PREFIX/include" \
        LDFLAGS="$LDFLAGS -L$DEPS_PREFIX/lib" \
        LIBS="$CRT1 -lz -lc -lm $BUILTINS"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install LIBS=""
}