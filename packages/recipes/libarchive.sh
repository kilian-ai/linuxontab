#!/bin/sh
# Recipe: libarchive — static libarchive for wasm32-linux-musl

NAME="libarchive"
VERSION="3.7.4"
DESCRIPTION="libarchive static library"
SOURCE_URL="https://github.com/libarchive/libarchive/releases/download/v3.7.4/libarchive-3.7.4.tar.xz"
SOURCE_SHA256=""

build() {
    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --enable-static \
        --disable-shared \
        --disable-bsdtar \
        --disable-bsdcpio \
        --disable-bsdcat \
        --without-zlib \
        --without-bz2lib \
        --without-lzma \
        --without-lz4 \
        --without-zstd \
        --without-expat \
        --without-xml2 \
        --without-iconv \
        --without-openssl \
        --without-nettle \
        CC="$CC" \
        CFLAGS="$CFLAGS -D_GNU_SOURCE" \
        LDFLAGS="$LDFLAGS" \
        LIBS="$CRT1 -lc -lm $BUILTINS"

    # Build only the library target to avoid linking utility binaries.
    make -j4 libarchive.la

    install -d "$STAGE/usr/lib" "$STAGE/usr/include"
    install -m644 ./.libs/libarchive.a "$STAGE/usr/lib/libarchive.a"
    install -m644 libarchive/archive.h "$STAGE/usr/include/archive.h"
    install -m644 libarchive/archive_entry.h "$STAGE/usr/include/archive_entry.h"

    # Ensure pkg-config metadata exists for Meson dependency lookup.
    if [ ! -f "$STAGE/usr/lib/pkgconfig/libarchive.pc" ]; then
        mkdir -p "$STAGE/usr/lib/pkgconfig"
        cat > "$STAGE/usr/lib/pkgconfig/libarchive.pc" << 'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: libarchive
Description: Multi-format archive and compression library
Version: 3.7.4
Cflags: -I${includedir}
Libs: -L${libdir} -larchive
EOF
    fi
}