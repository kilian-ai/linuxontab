#!/bin/sh
# Recipe: xtiny-apps — small desktop apps for the xtiny X server:
#   lot-textedit  Text Editor (Apps menu + taskbar)
#   lot-calc      Calculator (Apps menu)
#   lot-calendar  Date & Time dialog (double-click the taskbar clock)
# Plain Xlib clients (xapps/ in this repo), statically linked against the
# packaged X11 client libraries. Pure core protocol, like everything xtiny runs.

NAME="xtiny-apps"
VERSION="1.0.0"
DESCRIPTION="Text editor, calculator and date/time dialog for the xtiny desktop"
SOURCE_URL="local:"
DEPENDS=""

build() {
    cd "$REPO_ROOT"
    # the X11 client libraries, from their packages (static .a + headers)
    XD="$SRC/xdeps"
    rm -rf "$XD"; mkdir -p "$XD/usr"
    for t in libX11-1.8.10 libxcb-1.17.0 libXau-1.0.12 xorgproto-2024.1; do
        tar xzf "$REPO_ROOT/packages/$t.tar.gz" -C "$XD" 2>/dev/null \
            || { echo "missing packages/$t.tar.gz" >&2; exit 1; }
    done
    for p in "$XD"/pkg-*; do cp -R "$p/usr/." "$XD/usr/"; done
    LOT_CLANG="$CLANG" LOT_SYSROOT="$SYSROOT" sh "$REPO_ROOT/xapps/build.sh" "$XD/usr" "$SRC/out" \
        || { echo "xtiny-apps build failed" >&2; exit 1; }
    mkdir -p "$STAGE/usr/local/bin"
    for b in lot-textedit lot-calc lot-calendar; do
        install -m755 "$SRC/out/$b" "$STAGE/usr/local/bin/$b"
    done
    rmdir "$STAGE/bin" 2>/dev/null || true
}
