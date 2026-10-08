#!/bin/sh
# Recipe: sylpheed — Sylpheed 3.7.0, a lightweight GTK 2 mail client (IMAP,
# POP3, SMTP over TLS), for the xtiny desktop (Apps > Sylpheed).
#
# Built in the GTK cross-build container (spikes/sylpheed/Dockerfile = the
# LibreOffice build image + GLib/GTK host tools) with spikes/libreoffice/bin/
# wasm-cc: libffi (generated dispatch), glib 2.84, fribidi, harfbuzz, pixman,
# cairo (xlib), pango, atk, gdk-pixbuf, GTK 2.24.33, OpenSSL 1.1.1w, Sylpheed.
# spikes/sylpheed/build.sh + README have the details: binaryen --fpcast-emu
# (GTK calls through mismatched function pointer types, which traps on wasm;
# the 7.1 runtime adapts its table calls for __lot_fpcast modules), GTK
# without XKB, xlibi18n compat, the SNI patch. zlib/libpng/freetype/expat/
# fontconfig and the guest's X11 client libraries come from the Xfe build
# steps (spikes/libreoffice/xfe/build.sh), run first in the same volume.
# Needs Docker; first build ~45 min, the volume keeps the stack
# (LOT_SYL_VOL=<volume> to reuse another one, LOT_SYL_STEPS to run fewer steps).
# Needs xtiny 1.11.1+ (GTK 2 input, clip rectangles, menus) and the runtime
# with the __lot_fpcast table-call adapter (Pages a6d7b781+).

NAME="sylpheed"
VERSION="3.7.0-r2"   # r2: page-aligned brk (b6fd3d53); r1: binary128 long-double libc (7ccde12f)
DESCRIPTION="Sylpheed: lightweight graphical mail client (GTK 2) for the xtiny desktop"
SOURCE_URL="local:"
DEPENDS=""
NO_ASYNCIFY=1   # already post-processed with --fpcast-emu; no fork needed

build() {
    command -v docker >/dev/null || { echo "sylpheed: needs Docker (the cross-build container)" >&2; exit 1; }
    docker image inspect lot-libreoffice-build >/dev/null 2>&1 \
        || docker build -t lot-libreoffice-build "$REPO_ROOT/spikes/libreoffice" || exit 1
    docker build -q -t lot-gtk-build "$REPO_ROOT/spikes/sylpheed" >/dev/null || exit 1
    VOL="${LOT_SYL_VOL:-lot-sylpheed-build}"
    docker volume create "$VOL" >/dev/null
    CID=$(docker run -d -v "$VOL:/work" \
        -v "$REPO_ROOT/toolchain:/lot/toolchain:ro" -v "$REPO_ROOT/sysroot:/lot/sysroot:ro" \
        -v "$REPO_ROOT/spikes/libreoffice:/lot/spike" -v "$REPO_ROOT/spikes/sylpheed:/lot/syl:ro" \
        -v "$REPO_ROOT/packages:/lot/packages:ro" \
        lot-gtk-build sleep infinity) || exit 1
    docker exec -u 0 "$CID" chown lo /work
    # the Xfe build's libraries, the guest's X11 client libraries and the shims
    if ! docker exec "$CID" test -f /work/fm/prefix/lib/libfontconfig.a; then
        docker exec "$CID" sh /lot/spike/xfe/build.sh prep zlib libpng freetype expat fontconfig \
            || { docker rm -f "$CID" >/dev/null; echo "sylpheed: dependency build failed" >&2; exit 1; }
    fi
    # shellcheck disable=SC2086
    if ! docker exec "$CID" sh /lot/syl/build.sh ${LOT_SYL_STEPS:-}; then
        docker rm -f "$CID" >/dev/null; echo "sylpheed build failed" >&2; exit 1
    fi
    docker cp "$CID:/work/gtk/stage/." "$STAGE/"
    docker rm -f "$CID" >/dev/null
}
