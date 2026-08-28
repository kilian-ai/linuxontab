#!/bin/sh
# Recipe: libXfont2 - X font library used by Xorg/Xvfb

NAME="libXfont2"
VERSION="2.0.7"
DESCRIPTION="X font library"
SOURCE_URL="https://www.x.org/archive/individual/lib/libXfont2-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/libXfont2-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    [ -f "/tmp/lot-build/freetype/stage/usr/lib/libfreetype.a" ] || {
        echo "Missing /tmp/lot-build/freetype staged library. Run ./packages/build-package.sh freetype first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/fontenc/stage/usr/lib/libfontenc.a" ] || {
        echo "Missing /tmp/lot-build/fontenc staged library. Run ./packages/build-package.sh fontenc first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/xtrans/stage/usr/include/X11/Xtrans/Xtrans.h" ] || {
        echo "Missing /tmp/lot-build/xtrans staged headers. Run ./packages/build-package.sh xtrans first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/zlib/stage/usr/lib/libz.a" ] || {
        echo "Missing /tmp/lot-build/zlib staged library. Run ./packages/build-package.sh zlib first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/libXfont2-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    cp -R /tmp/lot-build/freetype/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/fontenc/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/xtrans/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -f /tmp/lot-build/zlib/stage/usr/include/zlib.h /tmp/lot-build/zlib/stage/usr/include/zconf.h "$DEPS_PREFIX/include/"
    mkdir -p "$DEPS_PREFIX/include/X11/Xtrans"
    cp -f /tmp/lot-build/xtrans/src/*.c /tmp/lot-build/xtrans/src/*.h "$DEPS_PREFIX/include/X11/Xtrans/"
    printf '%s\n' \
        '#ifndef _X11_XPOLL_H_' \
        '#define _X11_XPOLL_H_' \
        '' \
        '#include <poll.h>' \
        '' \
        '#endif' \
        > "$DEPS_PREFIX/include/X11/Xpoll.h"
    cp -f /tmp/lot-build/freetype/stage/usr/lib/libfreetype.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/fontenc/stage/usr/lib/libfontenc.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/zlib/stage/usr/lib/libz.a "$DEPS_PREFIX/lib/"

    cat > "$SRC/pkg-config" << EOF
#!/bin/sh
if [ "\$1" = "--version" ]; then echo "1.0"; exit 0; fi
if [ "\$1" = "--modversion" ]; then
  case "\$2" in
    freetype2) echo "2.13.3" ;;
    fontenc) echo "1.1.8" ;;
    zlib) echo "1.3.2" ;;
    *) echo "1.0" ;;
  esac
  exit 0
fi
if [ "\$1" = "--exists" ] || [ "\$1" = "--print-errors" ]; then exit 0; fi
    if [ "\$1" = "--cflags" ]; then echo "-I$XPROTO_SRC/include -I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/freetype2"; exit 0; fi
if [ "\$1" = "--libs" ]; then echo "-L$DEPS_PREFIX/lib -lfreetype -lfontenc -lz"; exit 0; fi
exit 0
EOF
    chmod +x "$SRC/pkg-config"

    export PKG_CONFIG="$SRC/pkg-config"

    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --disable-devel-docs \
        CC="$CC" \
        CFLAGS="$CFLAGS -DSelect=select -I$XPROTO_SRC/include -I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/freetype2" \
        LDFLAGS="$LDFLAGS -L$DEPS_PREFIX/lib" \
        LIBS="$CRT1 -lfontenc -lfreetype -lz -lc -lm $BUILTINS"

    perl -0pi -e 's/^noinst_PROGRAMS = lsfontdir\$\(EXEEXT\)$/noinst_PROGRAMS =/m; s/^TEST_UTIL_SRCS = .*$/TEST_UTIL_SRCS =/m; s/^lsfontdir_SOURCES = .*$/lsfontdir_SOURCES =/m; s/^lsfontdir_LDADD = .*$/lsfontdir_LDADD =/m' "$SRC/Makefile"

    make -j4 LIBS=""
    make DESTDIR="$STAGE" install LIBS=""
}