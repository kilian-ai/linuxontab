#!/bin/sh
# Recipe: xtrans — X transport interface headers
# Header-only package used by libX11 and related X.Org libs.

NAME="xtrans"
VERSION="1.6.0"
DESCRIPTION="X transport interface headers"
SOURCE_URL="https://www.x.org/archive/individual/lib/xtrans-${VERSION}.tar.gz"
SOURCE_SHA256=""

build() {
    mkdir -p "$STAGE/usr/include/X11/Xtrans"
    install -m 0644 "$SRC/Xtrans.h" "$STAGE/usr/include/X11/Xtrans/Xtrans.h"
}
