#!/bin/sh
# Recipe: jq — Command-line JSON processor
# Uses bundled oniguruma (regex library) — no external dependencies.

NAME="jq"
VERSION="1.7.1"
DESCRIPTION="Lightweight command-line JSON processor"
SOURCE_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1.tar.gz"
SOURCE_SHA256="478c9ca129fd2e3443fe27314b455e211e0d8c60bc8ff7df703873deeee580c2"

build() {
    # Configure with -Wl,--no-entry so configure's link tests don't require
    # _start (cross-compilation: the WASM binary can't be run on macOS anyway).
    # Keep LIBS minimal (-lc -lm only) so libtool doesn't embed CRT1/BUILTINS
    # into libjq.a as nested archives (wasm-ld can't read nested archives).
    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --without-oniguruma \
        --disable-shared \
        --enable-static \
        --disable-docs \
        --disable-maintainer-mode \
        CC="$CC" \
        CFLAGS="$CFLAGS -D_GNU_SOURCE" \
        LDFLAGS="$LDFLAGS -Wl,--no-entry" \
        LIBS="-lc -lm"

    # musl doesn't provide gamma() — patch it out before building
    sed -i '' '/LIBM_DD(gamma)/d' src/libm.h

    make -j4

    # Re-link the final binary: strip --no-entry, add CRT1/BUILTINS for _start.
    # libjq.a is already clean (no nested archives) — just re-link directly.
    LDFLAGS_FINAL=$(printf '%s\n' "$LDFLAGS" | sed 's/-Wl,--no-entry//g')
    $CC $CFLAGS $LDFLAGS_FINAL \
        -o jq src/main.o .libs/libjq.a \
        $CRT1 -lc -lm $BUILTINS

    install -Dm755 jq "$STAGE/bin/jq"
}
