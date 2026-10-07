#!/bin/sh
# Recipe: xtiny — the tiny X11 server + desktop (xtiny.c on librfb) for the
# lean image. Serves X on :1 and the desktop over RFB on :5900 (top bar →
# X display). Built from this repo's sources, the same way build-vnc-demos.sh
# builds the full-image copy.

NAME="xtiny"
VERSION="1.10.0"  # 1.10.0: mouse wheel (X buttons 4-7: NetSurf, xterm, GTK scroll);
                  # X pointer semantics — press/release propagate to the first
                  # ancestor that selected them, implicit grab, Enter/LeaveNotify
                  # 1.9.0: what LibreOffice's X11 backend needs — PropertyNotify (the
                  # server-time handshake it blocks on before mapping a window),
                  # override-redirect popups (menus at their own position, no frame),
                  # active pointer/keyboard grabs; Writer in the Apps menu while the
                  # LibreOffice disk is mounted at /opt/lo
                  # 1.8.0: Apps menu — AI Assistant (claw, in a terminal); launched
                  # apps get HOME=/root instead of init's HOME=/
                  # 1.7.0: Apps menu — File Manager (xfe, pinned), Chromium (when the x86
                  # disk is mounted), Rust IDE, tmux, Node.js; menu flows into columns;
                  # installs refresh a stale package index once (apk update) and retry
                  # 1.6.0: sound server — /tmp/.lot-audio (s16le stereo 48 kHz) forwarded
                  # to the viewer over RFB (QEMU audio extension); lotplay plays sound
                  # 1.5.0: CopyPlane, GC clip masks, depth-1 PutImage, X selections +
                  # SendEvent (clipboard), 1024 windows/4096 pixmaps/512 GCs:
                  # what FOX/Xfe (the xfe package) needs
                  # 1.4.0: JPEG for video-like regions (librfb LJPG + lossless repair),
                  # damage merging, _LOT_PUTIMAGE_SCALE, fast PutImage, Videos entry
                  # 1.3.0: Text Editor + Calculator apps, date & time dialog on a
                  # double-click of the clock (package xtiny-apps); honours
                  # USPosition (WM_NORMAL_HINTS) for client-placed windows
                  # 1.2.0: Apps menu (built-ins + /usr/share/applications/*.desktop,
                  # install-on-launch via apk in a terminal)
                  # 1.1.0: theme pass — desktop follows the viewer size, AA UI font,
                  # rounded/shadowed frames, edge resize, dark xterm defaults
                  # 1.0.3: fixed-brk sysroot, heap no longer capped at ~60 MB
DESCRIPTION="Tiny X11 server + desktop on :5900 for real X clients (xterm, netsurf, wolf3d) with an Apps menu; open the X display panel"
SOURCE_URL="local:"
DEPENDS="xterm xeyes xtiny-apps"

build() {
    cd "$REPO_ROOT"
    # fork() for the taskbar launcher: musl omits it on wasm32, the kernel
    # provides it via asyncify (sysroot/wasm_fork.c). dlmalloc: frame and
    # RRE buffers pass 128 KB, where musl mallocng needs mmap and traps.
    $CC $CFLAGS -o "$SRC/xtiny" librfb.c xtiny.c sysroot/wasm_fork.c sysroot/wasm_dlmalloc.c \
        $LDFLAGS -Wl,-z,stack-size=8388608 $CRT1 -lc $BUILTINS \
        || { echo "xtiny build failed" >&2; exit 1; }
    mkdir -p "$STAGE/usr/local/bin"
    install -m755 "$SRC/xtiny" "$STAGE/usr/local/bin/xtiny"
    rmdir "$STAGE/bin" 2>/dev/null || true
}
