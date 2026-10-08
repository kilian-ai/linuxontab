#!/bin/sh
# Recipe: xfe — Xfe (X File Explorer) 2.1.11, a two-pane file manager on the
# FOX 1.6 toolkit, for the xtiny desktop. Anti-aliased text through Xft's
# core-protocol path (xtiny has no RENDER), DejaVu fonts, PNG icon theme.
#
# Built in the LibreOffice cross-build container (spikes/libreoffice/Dockerfile:
# Debian, clang/lld 19.1.7 like the host) with spikes/libreoffice/bin/wasm-cc
# and toolchain/cpp-eh-sysroot: FOX and Xfe are C++ with exceptions.
#   zlib libpng freetype expat fontconfig libXft FOX Xfe
# spikes/libreoffice/xfe/build.sh has the details (weak FOX definitions for
# Xfe's overrides, native reswrap, the tryHandle try/catch removed so that
# asyncify fork works, input-method stubs, cancellation shim).
# Needs Docker. Needs xtiny with CopyPlane, clip masks, bitmaps, selections
# (xtiny ae9c1426 or later).

NAME="xfe"
VERSION="2.1.11-r1"   # r1: relinked on the binary128 long-double libc (printf %f, strtod)
DESCRIPTION="Xfe file manager (X File Explorer on FOX 1.6) for the xtiny desktop"
SOURCE_URL="local:"
DEPENDS="xtiny-apps"

build() {
    command -v docker >/dev/null || { echo "xfe: needs Docker (the cross-build container)" >&2; exit 1; }
    IMG=lot-libreoffice-build
    docker image inspect $IMG >/dev/null 2>&1 \
        || docker build -t $IMG "$REPO_ROOT/spikes/libreoffice" || exit 1
    VOL=lot-xfe-build
    docker volume create $VOL >/dev/null
    CID=$(docker run -d -v $VOL:/work \
        -v "$REPO_ROOT/toolchain:/lot/toolchain:ro" -v "$REPO_ROOT/sysroot:/lot/sysroot:ro" \
        -v "$REPO_ROOT/spikes/libreoffice:/lot/spike" -v "$REPO_ROOT/packages:/lot/packages:ro" \
        $IMG sleep infinity) || exit 1
    docker exec -u 0 $CID chown lo /work
    if ! docker exec $CID sh /lot/spike/xfe/build.sh; then
        docker rm -f $CID >/dev/null; echo "xfe build failed" >&2; exit 1
    fi
    docker cp $CID:/work/fm/stage/. "$STAGE/"
    docker rm -f $CID >/dev/null
    # build-package asyncifies usr/local/bin/xfe (fork() comes from asyncify)
}
