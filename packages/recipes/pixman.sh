#!/bin/sh
# Recipe: pixman - pixel manipulation library used by Xvfb

NAME="pixman"
VERSION="0.42.2"
DESCRIPTION="Pixel manipulation library"
SOURCE_URL="https://cairographics.org/releases/pixman-${VERSION}.tar.gz"
SOURCE_SHA256=""

build() {
    cd "$SRC"

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
        --disable-openmp \
        --enable-libpng=no \
        --enable-gtk=no \
        CC="$CC" \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
        LIBS="$CRT1 -lc -lm"

    perl -0777 -i -pe 's/^SUBDIRS = pixman demos test$/SUBDIRS = pixman/m' "$SRC/Makefile"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install LIBS=""

    if [ -f "$STAGE/usr/lib/libpixman-1.a" ]; then
        "$AR" d "$STAGE/usr/lib/libpixman-1.a" libclang_rt.builtins.a 2>/dev/null || true
        "$RANLIB" "$STAGE/usr/lib/libpixman-1.a"
    fi
}