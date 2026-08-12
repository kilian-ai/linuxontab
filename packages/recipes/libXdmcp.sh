#!/bin/sh
# Recipe: libXdmcp — X Display Manager Control Protocol library

NAME="libXdmcp"
VERSION="1.1.5"
DESCRIPTION="X Display Manager Control Protocol library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libXdmcp-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/libXdmcp-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

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
    export XDMCP_CFLAGS="-I$XPROTO_SRC/include"
    export XDMCP_LIBS=""
    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        CC="$CC" \
        CFLAGS="$CFLAGS -I$XPROTO_SRC/include" \
        LDFLAGS="$LDFLAGS" \
        LIBS="$CRT1 -lc -lm $BUILTINS"

    make -j4
    make DESTDIR="$STAGE" install
}
