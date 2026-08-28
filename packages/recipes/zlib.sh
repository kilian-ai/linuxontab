#!/bin/sh
# Recipe: zlib - compression library needed by fontenc/libXfont2

NAME="zlib"
VERSION="1.3.2"
DESCRIPTION="Compression library"
SOURCE_URL="https://zlib.net/zlib-${VERSION}.tar.gz"
SOURCE_SHA256=""

build() {
    cd "$SRC"

        _ZSRCS="adler32.c compress.c crc32.c deflate.c gzclose.c gzlib.c gzread.c \
            gzwrite.c infback.c inffast.c inflate.c inftrees.c trees.c \
            uncompr.c zutil.c"

    rm -f ./*.o
    # shellcheck disable=SC2086
    $CC $CFLAGS -DHAVE_UNISTD_H -c $_ZSRCS

    mkdir -p "$STAGE/usr/lib" "$STAGE/usr/include"
    $AR rcs "$STAGE/usr/lib/libz.a" ./*.o
    $RANLIB "$STAGE/usr/lib/libz.a"
    cp zlib.h zconf.h "$STAGE/usr/include/"
}