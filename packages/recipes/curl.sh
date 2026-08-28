#!/bin/sh
# Recipe: curl — Command-line tool for transferring data with URLs
#
# This build is HTTP-only (no TLS). The virtual gateway (192.168.86.1)
# and internal services are HTTP, so this is fully useful inside the VM.
# For HTTPS support, build mbedtls first, then rebuild with --with-mbedtls.
#
# To get HTTPS later:
#   ./packages/build-package.sh mbedtls
#   LOT_CURL_TLS=mbedtls ./packages/build-package.sh curl

NAME="curl"
VERSION="8.13.0"
DESCRIPTION="Command-line tool for transferring data with URLs (HTTP)"
SOURCE_URL="https://curl.se/download/curl-8.13.0.tar.gz"
SOURCE_SHA256="c261a4db579b289a7501565497658bbd52d3138fdbaccf1490fa918129ab45bc"

build() {
    # Configure for cross-compilation to wasm32-linux-musl.
    # -nostdlib is in LDFLAGS; we pass $CRT1 and -lc via LIBS so they appear
    # after the object files in the linker command (required order for musl).
    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --enable-static \
        --disable-shared \
        --without-ssl \
        --without-zlib \
        --without-libpsl \
        --without-libidn2 \
        --without-librtmp \
        --without-brotli \
        --without-zstd \
        --without-nghttp2 \
        --without-nghttp3 \
        --disable-crypto-auth \
        --disable-unix-sockets \
        --disable-socketpair \
        --disable-threaded-resolver \
        --disable-ipv6 \
        --disable-docs \
        --disable-manual \
        CC="$CC" \
        CFLAGS="$CFLAGS -D_GNU_SOURCE" \
        LDFLAGS="$LDFLAGS" \
        LIBS="$CRT1 -lc -lm $BUILTINS"

    make -j4 -C lib

    # macOS ar corrupts WASM objects (extra \n padding bytes in members).
    # llvm-ar also crashes if the target archive already exists in macOS format
    # (LLVM ERROR: malformed uleb128).  Delete the macOS-ar archive first, then
    # recreate it clean with llvm-ar so that make -C src can link against it.
    rm -f lib/.libs/libcurl.a
    # Include all libcurl objects: top-level AND subdirs (vauth, vtls, vquic, vssh)
    find lib -name "libcurl_la-*.o" ! -path "*/.libs/*" | sort | \
        xargs "$AR" crs lib/.libs/libcurl.a

    make -j4 -C src
    install -Dm755 src/curl "$STAGE/bin/curl"
}
