#!/bin/sh
# Recipe: curl — command-line tool for transferring data with URLs, with
# HTTPS (OpenSSL 1.1.1w) against the guest's CA bundle (/etc/ssl/cert.pem).
#
#   curl -sS https://example.com/
#
# r1 adds TLS; 8.13.0 was HTTP-only. Real curl's sockets work on the 7.1
# kernel (on 6.1 they timed out, which is why the full image still carries a
# python-backed curl shim in /usr/local/bin). HTTPS curl also lets npm fetch
# registry tarballs without python and is what the claw package needs.
#
# OpenSSL is built once into $OSSL (same configuration as the netsurf and
# python3 recipes: no asm, no threads/atomics, no engines) and reused.

NAME="curl"
VERSION="8.13.0-r1"   # r1: HTTPS (OpenSSL)
DESCRIPTION="Command-line tool for transferring data with URLs (HTTP and HTTPS)"
SOURCE_URL="https://curl.se/download/curl-8.13.0.tar.gz"
SOURCE_SHA256="c261a4db579b289a7501565497658bbd52d3138fdbaccf1490fa918129ab45bc"

OPENSSL_VER="1.1.1w"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz"
OPENSSL_SHA256="cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"

build() {
    OSSL="/tmp/lot-build/openssl-$OPENSSL_VER-wasm"
    if [ ! -f "$OSSL/.built" ]; then
        A="/tmp/lot-src-openssl-$OPENSSL_VER.tar.gz"
        [ -f "$A" ] || curl -sL --fail -o "$A" "$OPENSSL_URL" || { echo "openssl download failed" >&2; exit 1; }
        [ "$(shasum -a 256 "$A" | cut -d' ' -f1)" = "$OPENSSL_SHA256" ] || { echo "openssl checksum mismatch" >&2; exit 1; }
        rm -rf "$SRC/openssl" && mkdir -p "$SRC/openssl" && tar xzf "$A" -C "$SRC/openssl" --strip-components=1
        ( cd "$SRC/openssl" \
          && CC="$CC" AR="$AR" RANLIB="$RANLIB" ./Configure linux-generic32 no-asm no-shared no-dso no-engine \
                no-async no-tests no-ui-console -DOPENSSL_NO_SECURE_MEMORY \
                no-bf no-cast no-idea no-rc2 no-rc4 no-rc5 no-md2 no-md4 no-mdc2 \
                no-seed no-camellia no-whirlpool no-blake2 \
                -DOPENSSL_DEV_NO_ATOMICS -D__STDC_NO_ATOMICS__=1 --prefix="$OSSL" $CFLAGS > configure.log 2>&1 \
          && make -j8 build_libs > make.log 2>&1 ) || { echo "openssl build failed" >&2; exit 1; }
        rm -rf "$OSSL" && mkdir -p "$OSSL/lib" "$OSSL/include"
        cp "$SRC"/openssl/libssl.a "$SRC"/openssl/libcrypto.a "$OSSL/lib/"
        cp -R "$SRC/openssl/include/openssl" "$OSSL/include/"
        touch "$OSSL/.built"
    fi

    # dlmalloc: TLS and transfer buffers can pass mallocng's 128 KB
    # large-block path, which needs mmap and traps here. ld128: long-double
    # printf/strtod compat for the sysroot's musl.
    SHIMS=""
    for f in wasm_dlmalloc wasm_ld128; do
        $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/$f.c" -o "$SRC/$f.o"
        SHIMS="$SHIMS $SRC/$f.o"
    done

    # -nostdlib is in LDFLAGS; $CRT1 and -lc go in LIBS so they follow the
    # objects on the link line (required order for musl).
    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --enable-static \
        --disable-shared \
        --with-openssl="$OSSL" \
        --with-ca-bundle=/etc/ssl/cert.pem \
        --without-ca-path \
        --without-zlib \
        --without-libpsl \
        --without-libidn2 \
        --without-librtmp \
        --without-brotli \
        --without-zstd \
        --without-nghttp2 \
        --without-nghttp3 \
        --disable-unix-sockets \
        --disable-socketpair \
        --disable-threaded-resolver \
        --disable-ipv6 \
        --disable-docs \
        --disable-manual \
        --disable-ldap --disable-ldaps \
        CC="$CC" \
        CFLAGS="$CFLAGS -D_GNU_SOURCE" \
        CPPFLAGS="-I$OSSL/include" \
        LDFLAGS="$LDFLAGS -L$OSSL/lib" \
        LIBS="$SHIMS -lssl -lcrypto $CRT1 -lc -lm $BUILTINS" > "$SRC/curl-configure.log" 2>&1 \
        || { echo "curl configure failed" >&2; tail -20 "$SRC/curl-configure.log" >&2; exit 1; }
    grep -q "SSL:.*OpenSSL" "$SRC/curl-configure.log" || { echo "curl: configure did not enable OpenSSL" >&2; grep -E "^  SSL" "$SRC/curl-configure.log" >&2; exit 1; }

    make -j4 -C lib

    # macOS ar corrupts WASM objects (extra \n padding bytes in members), and
    # llvm-ar crashes on an archive macOS ar already wrote. Recreate it clean
    # from all libcurl objects (top level and vauth/vtls/vquic/vssh).
    rm -f lib/.libs/libcurl.a
    find lib -name "libcurl_la-*.o" ! -path "*/.libs/*" | sort | \
        xargs "$AR" crs lib/.libs/libcurl.a

    make -j4 -C src
    install -Dm755 src/curl "$STAGE/bin/curl"
}
