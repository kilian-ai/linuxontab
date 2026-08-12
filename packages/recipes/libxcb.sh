#!/bin/sh
# Recipe: libxcb — X C Binding library

NAME="libxcb"
VERSION="1.17.0"
DESCRIPTION="X C Binding library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libxcb-${VERSION}.tar.gz"
SOURCE_SHA256=""

XCB_PROTO_VER="1.17.0"
XCB_PROTO_URL="https://xorg.freedesktop.org/archive/individual/proto/xcb-proto-${XCB_PROTO_VER}.tar.xz"
XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/libxcb-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    XCBP_ARCHIVE="/tmp/lot-src-xcb-proto-${XCB_PROTO_VER}.tar.xz"
    XCBP_SRC="/tmp/lot-build/libxcb-xcbproto"
    if [ ! -f "$XCBP_ARCHIVE" ]; then
        echo "==> Downloading xcb-proto $XCB_PROTO_VER"
        curl -L --fail -o "$XCBP_ARCHIVE" "$XCB_PROTO_URL"
    fi
    rm -rf "$XCBP_SRC"
    mkdir -p "$XCBP_SRC"
    tar xJf "$XCBP_ARCHIVE" -C "$XCBP_SRC" --strip-components=1

    AUTH_PREFIX="/tmp/lot-build/libxcb-auth-prefix"
    rm -rf "$AUTH_PREFIX"
    mkdir -p "$AUTH_PREFIX"

    [ -f "/tmp/lot-build/libXau/stage/usr/include/X11/Xauth.h" ] || {
      echo "Missing /tmp/lot-build/libXau staged headers. Run ./packages/build-package.sh libXau first." >&2
      exit 1
    }
    [ -f "/tmp/lot-build/libXdmcp/stage/usr/include/X11/Xdmcp.h" ] || {
      echo "Missing /tmp/lot-build/libXdmcp staged headers. Run ./packages/build-package.sh libXdmcp first." >&2
      exit 1
    }
    cp -R /tmp/lot-build/libXau/stage/usr/include "$AUTH_PREFIX/"
    cp -R /tmp/lot-build/libXdmcp/stage/usr/include/X11 "$AUTH_PREFIX/include/"

    # Build/install xcb-proto into a local prefix so libxcb can find XML + xcbgen.
    XCBP_PREFIX="/tmp/lot-build/libxcb-xcbproto-prefix"
    rm -rf "$XCBP_PREFIX"
    mkdir -p "$XCBP_PREFIX"
    (
      cd "$XCBP_SRC"
      ./configure --prefix="$XCBP_PREFIX"
      make -j4
      make install
    )

    XCBGEN_SITE="$(find "$XCBP_PREFIX/lib" -type d -path '*/site-packages' | head -1)"
    [ -n "$XCBGEN_SITE" ] || { echo "xcbgen site-packages not found" >&2; exit 1; }

    # libxcb's configure relies heavily on pkg-config checks.
    cat > "$SRC/pkg-config" << EOF
#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    --variable=xcbincludedir)
      echo "$XCBP_PREFIX/share/xcb"
      exit 0
      ;;
    --variable=pythondir)
      echo "$XCBGEN_SITE"
      exit 0
      ;;
  esac
done
if [ "$1" = "--version" ] || [ "$1" = "--modversion" ]; then
  echo "1.0"
  exit 0
fi
if [ "$1" = "--exists" ] || [ "$1" = "--print-errors" ]; then
  exit 0
fi
if [ "$1" = "--cflags" ]; then
  echo "-I$XPROTO_SRC/include -I$XCBP_PREFIX/include -I$AUTH_PREFIX/include"
  exit 0
fi
if [ "$1" = "--libs" ]; then
  echo ""
  exit 0
fi
exit 0
EOF
    chmod +x "$SRC/pkg-config"

    export PKG_CONFIG="$SRC/pkg-config"
    export PYTHONPATH="$XCBGEN_SITE:$PYTHONPATH"
    export XCBPROTO_XCBINCLUDEDIR="$XCBP_PREFIX/share/xcb"
    export XCBPROTO_XCBPYTHONDIR="$XCBGEN_SITE"

    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --without-doxygen \
      XCBPROTO_XCBINCLUDEDIR="$XCBPROTO_XCBINCLUDEDIR" \
      XCBPROTO_XCBPYTHONDIR="$XCBPROTO_XCBPYTHONDIR" \
        CC="$CC" \
      CFLAGS="$CFLAGS -I$XPROTO_SRC/include -I$XCBP_PREFIX/include -I$AUTH_PREFIX/include" \
      LDFLAGS="$LDFLAGS" \
      LIBS="$CRT1 -lc -lm $BUILTINS"

    make -j4 \
      XCBPROTO_XCBINCLUDEDIR="$XCBPROTO_XCBINCLUDEDIR" \
      XCBPROTO_XCBPYTHONDIR="$XCBPROTO_XCBPYTHONDIR" \
      LIBS=""
    make DESTDIR="$STAGE" install
}
