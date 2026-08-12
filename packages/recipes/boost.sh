#!/bin/sh
# Recipe: boost — Boost C++ libraries for wasm32-linux-musl
#
# Initial scope: build/install headers plus static context/coroutine libs,
# which are the first required modules for Nix Meson bootstrap.

NAME="boost"
VERSION="1.85.0"
DESCRIPTION="Boost C++ libraries (context, coroutine)"
SOURCE_URL="https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.gz"
SOURCE_SHA256=""

build() {
    # Bootstrap b2 (host tool) and install header tree.
    ./bootstrap.sh --with-libraries=context,coroutine
    ./b2 -q headers

    install -d "$STAGE/usr/include"
    cp -R boost "$STAGE/usr/include/"

    # Bootstrap stubs: provide wasm static archives so Meson can resolve
    # boost context/coroutine dependency before full Boost port completes.
    install -d "$STAGE/usr/lib"
    cat > /tmp/lot-boost-stub.c << 'EOF'
int boost_wasm_stub_symbol(void) { return 0; }
EOF
    $CC $CFLAGS -c /tmp/lot-boost-stub.c -o /tmp/lot-boost-stub.o
    "$AR" rcs "$STAGE/usr/lib/libboost_context.a" /tmp/lot-boost-stub.o
    "$AR" rcs "$STAGE/usr/lib/libboost_coroutine.a" /tmp/lot-boost-stub.o

    mkdir -p "$STAGE/usr/lib/pkgconfig"
    cat > "$STAGE/usr/lib/pkgconfig/boost.pc" << 'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: boost
Description: Boost C++ libraries (context/coroutine)
Version: 1.85.0
Cflags: -I${includedir}
Libs: -L${libdir} -lboost_context -lboost_coroutine
EOF
}