#!/bin/sh
# Recipe: xorgproto — X.Org protocol headers
# Header-only package used by libX11/libXext/xeyes builds.

NAME="xorgproto"
VERSION="2024.1"
DESCRIPTION="X.Org protocol and extension headers"
SOURCE_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${VERSION}/xorgproto-xorgproto-${VERSION}.tar.gz"
SOURCE_SHA256=""

build() {
    mkdir -p "$STAGE/usr/include"

    if [ -d "$SRC/include" ]; then
        cp -R "$SRC/include/." "$STAGE/usr/include/"
    else
        echo "xorgproto: expected include/ in source tree" >&2
        exit 1
    fi

    # Keep protocol metadata for debugging/repro.
    mkdir -p "$STAGE/usr/share/xorgproto"
    [ -f "$SRC/COPYING" ] && cp "$SRC/COPYING" "$STAGE/usr/share/xorgproto/" || true
    [ -f "$SRC/README.md" ] && cp "$SRC/README.md" "$STAGE/usr/share/xorgproto/" || true
}
