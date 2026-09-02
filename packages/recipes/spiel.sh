#!/bin/sh
# Recipe: spiel — the Spiel media server (FastAPI backend + React frontend) for
# the guest, as an apk package so the lean image can install it on demand.
#
#   spiel-demo                 start on :8080  (then: top bar → web view)
#   spiel-demo stop
#
# Payload = the already-ported guest tree under rootfs/opt (app + host-baked
# pure-Python deps with unchecked-hash pycs + built React dist), the launcher
# and the nginx front config; python3 + nginx are runtime deps (apk resolves). The "source"
# tarball is produced by packages/make-spiel-src.sh from rootfs/opt.

NAME="spiel"
VERSION="2.0"
DESCRIPTION="Spiel media server — FastAPI backend + React UI (spiel-demo, web view :8080)"
SOURCE_URL="file:///Users/kilian/.ai/LinuxOnTab-kernel/packages/spiel-src-2.0.tar.gz"
SOURCE_SHA256=""
DEPENDS="python3 nginx"

build() {
    mkdir -p "$STAGE/opt" "$STAGE/usr/local/bin"
    cp -Rp "$SRC/opt/webfuse" "$SRC/opt/webfuse-libs" "$SRC/opt/frontend" "$STAGE/opt/"
    install -m755 "$SRC/usr/local/bin/spiel-demo" "$STAGE/usr/local/bin/spiel-demo"
    mkdir -p "$STAGE/etc/nginx" && install -m644 "$SRC/etc/nginx/spiel.conf" "$STAGE/etc/nginx/spiel.conf"
    rmdir "$STAGE/bin" 2>/dev/null || true
}
