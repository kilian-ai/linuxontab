#!/bin/sh
# Recipe: wolf3d — Wolfenstein 3D (shareware episode 1) on the guest's X
# server. Engine = Steven Fuller's "Linux Wolf" port of the id source
# (2001-10-28, GPL), built with its plain-Xlib backend (vi_xlib.c): one
# 320x200 XPutImage per frame, key press/release events, a TrueColor visual
# — exactly what xtiny implements. Sound is sd_null (the port's OSS backend
# needs /dev/dsp). Data = the unmodified shareware v1.4 WL1 files, which
# Apogee licensed for free redistribution (VENDOR.DOC ships alongside).
#
#   xtiny &          # the X server (then: top bar → X display)
#   wolf3d &         # the game, DISPLAY defaults to :1

NAME="wolf3d"
VERSION="1.4-20011028-r2"   # r1: scales to the window (maximise)
                            # r2: fixed-brk sysroot, heap no longer capped at ~60 MB
DESCRIPTION="Wolfenstein 3D shareware (episode 1) — id's raycaster on the X server (run xtiny first)"
# icculus.org dropped the tarball; FreeBSD's ports distfile cache keeps it.
SOURCE_URL="http://distcache.freebsd.org/ports-distfiles/wolf3d-20011028.tar.gz"
SOURCE_SHA256="9a1bde32bee0e78a82ad98ee6176e3bf93ec4fa70d1353ad63e1f9f6a30c72fb"
DATA_URL="https://image.dosgamesarchive.com/games/1wolf14.zip"
DATA_SHA256="309eaa5dffd8d00452b5002ff991768bd7f097ab665227571e3b5f95fb61302d"
DEPENDS="xtiny"

build() {
    cd "$SRC"

    # ── shareware data ────────────────────────────────────────────────────
    DATA_ZIP="/tmp/lot-src-wolf3d-1wolf14.zip"
    [ -f "$DATA_ZIP" ] || curl -L --fail -o "$DATA_ZIP" "$DATA_URL" || { echo "data download failed" >&2; exit 1; }
    [ "$(shasum -a 256 "$DATA_ZIP" | cut -d' ' -f1)" = "$DATA_SHA256" ] || { echo "data checksum mismatch" >&2; exit 1; }
    rm -rf "$SRC/wl1" && mkdir -p "$SRC/wl1/outer" "$SRC/wl1/inner"
    unzip -qo "$DATA_ZIP" -d "$SRC/wl1/outer"
    # The inner W3D1_BBS._1 is a zip behind a 335-byte installer header;
    # unzip reports that as a warning (exit 1), which is expected here.
    unzip -qo "$SRC/wl1/outer/W3D1_BBS._1" -d "$SRC/wl1/inner" || [ $? -eq 1 ]
    SHARE="$STAGE/usr/local/share/wolf3d"
    mkdir -p "$SHARE"
    for f in AUDIOHED AUDIOT GAMEMAPS MAPHEAD VGADICT VGAGRAPH VGAHEAD VSWAP; do
        [ -f "$SRC/wl1/inner/$f.WL1" ] || { echo "missing $f.WL1" >&2; exit 1; }
        # the engine opens "<name>.wl1" lowercase in its working directory
        lower=$(echo "$f" | tr 'A-Z' 'a-z')
        install -m644 "$SRC/wl1/inner/$f.WL1" "$SHARE/$lower.wl1"
    done
    install -m644 "$SRC/wl1/inner/VENDOR.DOC" "$SHARE/VENDOR.DOC"

    # ── X libraries from our own packages ─────────────────────────────────
    XDEPS="/tmp/lot-build/wolf3d-xdeps"
    rm -rf "$XDEPS" && mkdir -p "$XDEPS"
    for p in libX11 libXext libxcb libXau libXdmcp xorgproto; do
        t=$(ls "$REPO_ROOT"/packages/$p-*.tar.gz 2>/dev/null | head -1)
        [ -n "$t" ] || { echo "missing package tarball: $p" >&2; exit 1; }
        tar xzf "$t" -C "$XDEPS"
    done
    XINC=""; XLIB=""
    for d in "$XDEPS"/pkg-*/usr; do
        [ -d "$d/include" ] && XINC="$XINC -I$d/include"
        [ -d "$d/lib" ] && XLIB="$XLIB -L$d/lib"
    done

    # ── port patches ──────────────────────────────────────────────────────
    # The engine waits by spinning on get_TimeCount() in ~10 places. On a
    # one-CPU guest a spin starves the X server that has to turn each frame
    # into pixels, so every clock read yields for 1 ms: spins become polls,
    # and a game frame gains at most a few ms.
    perl -0777 -i -pe 's{(unsigned long get_TimeCount\(\)\s*\{)}{$1\n\tusleep(1000);}' misc.c
    grep -q "usleep(1000)" misc.c || { echo "misc.c patch failed" >&2; exit 1; }
    grep -q "<unistd.h>" misc.c || perl -0777 -i -pe 's{^}{#include <unistd.h>\n}' misc.c

    # sd_null.c defines MusicMode as SDMode; id_sd's header (sd_comm.h) and
    # every user say SMMode. gcc 2001 let two enum types alias; clang errors.
    perl -0777 -i -pe 's{^SDMode SoundMode, MusicMode;}{SDMode SoundMode;\nSMMode MusicMode;}m' sd_null.c
    grep -q "^SMMode MusicMode;" sd_null.c || { echo "sd_null.c patch failed" >&2; exit 1; }

    # Globals that gcc 2001 merged as "common" symbols, which the wasm
    # backend does not support (-fcommon crashes clang): wl_menu.h declares
    # an unused enum VARIABLE in every includer, and viewx/viewy are defined
    # in both wl_main.c and wl_draw.c (wl_def.h already has the extern).
    perl -0777 -i -pe 's/\}\s*menuitems;/};/' wl_menu.h
    perl -0777 -i -pe 's{^fixed viewx, viewy;[^\n]*\n}{}m' wl_draw.c
    ! grep -q "menuitems;" wl_menu.h && ! grep -q "^fixed viewx, viewy;" wl_draw.c \
        || { echo "common-symbol patch failed" >&2; exit 1; }

    # Symbols the plain-Xlib build lacks. vi_xlib.c never implemented mouse
    # input (only vi_sdl.c did), so the menu/game see no buttons and no
    # motion; keyboard controls are the classic ones. The three X internals
    # are absent from our reduced libX11 (no i18n/locale support) — the same
    # stubs xeyes.sh links; with a C locale nothing ever takes these paths.
    cat > "$SRC/wolf_compat.c" <<'COMPAT'
typedef unsigned char byte;
byte IN_MouseButtons(void) { return 0; }
void IN_GetMouseDelta(int *dx, int *dy) { if (dx) *dx = 0; if (dy) *dy = 0; }
void *_Xi18n_lock = 0;
void *_conv_lock = 0;
void *_XrmInitParseInfo(void *statep) { if (statep) *(void **)statep = 0; return 0; }
COMPAT
    $CC $CFLAGS -c "$SRC/wolf_compat.c" -o "$SRC/wolf_compat.o"
    SHIMS_COMPAT="$SRC/wolf_compat.o"

    # Menu dispatch: every menu item stores its handler as MenuFunc,
    # void (*)(int), and HandleMenu calls routine(0) — but the handlers are
    # void CP_NewGame(void), int CP_LoadGame(int), ... cast into it. Native
    # C shrugs that off; wasm's call_indirect checks the exact signature and
    # traps ("function signature mismatch") the moment a menu item is chosen.
    # These 13 casts are the complete set (clang -Wcast-function-type-strict
    # and -Wincompatible-function-pointer-types over all sources). Route each
    # through a thunk that really is void f(int). Actor think/action pointers
    # are already called through a prototyped void (*)(objtype *) and all 16
    # targets match, so they need nothing.
    cat > "$SRC/lot_menufunc.h" <<'MFH'
void CP_NewGame_mf(int), CP_Sound_mf(int), CP_Control_mf(int),
     CP_LoadGame_mf(int), CP_SaveGame_mf(int), CP_ChangeView_mf(int),
     CP_ReadThis_mf(int), CP_ViewScores_mf(int), MouseSensitivity_mf(int),
     CustomControls_mf(int);
MFH
    cat > "$SRC/lot_menufunc.c" <<'MFC'
#include "wl_def.h"
void CP_ReadThis();
void CP_NewGame_mf(int t)       { (void)t; CP_NewGame(); }
void CP_Sound_mf(int t)         { (void)t; CP_Sound(); }
void CP_Control_mf(int t)       { (void)t; CP_Control(); }
void CP_LoadGame_mf(int t)      { CP_LoadGame(t); }
void CP_SaveGame_mf(int t)      { CP_SaveGame(t); }
void CP_ChangeView_mf(int t)    { (void)t; CP_ChangeView(); }
void CP_ReadThis_mf(int t)      { (void)t; CP_ReadThis(); }
void CP_ViewScores_mf(int t)    { (void)t; CP_ViewScores(); }
void MouseSensitivity_mf(int t) { (void)t; MouseSensitivity(); }
void CustomControls_mf(int t)   { (void)t; CustomControls(); }
MFC
    perl -pi -e 's/\(MenuFunc\)\s*([A-Za-z_]+)/$1_mf/g' wl_menu.c wl_game.c
    for f in wl_menu.c wl_game.c; do perl -0777 -pi -e 's/^/#include "lot_menufunc.h"\n/' "$f"; done
    ! /usr/bin/grep -q "(MenuFunc)" wl_menu.c wl_game.c || { echo "MenuFunc thunk patch failed" >&2; exit 1; }

    # Follow window resizes: vi_xlib.c drew a fixed 320x200 image at the
    # window origin and pinned the size hints, so maximising the window
    # (xtiny's green button) left the game in a corner. Now the frame is
    # drawn at the largest whole scale that fits, centred on black.
    patch -p1 < "$REPO_ROOT/packages/patches/wolf3d-scale-to-window.patch" \
        || { echo "vi_xlib.c scale patch failed" >&2; exit 1; }

    # ── compile + link ────────────────────────────────────────────────────
    SHIMS=""
    for f in wasm_ld128 wasm_dlmalloc; do
        $CC $CFLAGS -c "$REPO_ROOT/sysroot/$f.c" -o "$SRC/$f.o"
        SHIMS="$SHIMS $SRC/$f.o"
    done
    OBJS="objs misc id_ca id_vh id_us wl_act1 wl_act2 wl_act3 wl_agent wl_game
          wl_inter wl_menu wl_play wl_state wl_text wl_main wl_debug vi_comm
          sd_comm sd_null wl_draw vi_xlib lot_menufunc"
    WCFLAGS="$CFLAGS -std=gnu99 -w -DWMODE=0 -Dlinux=1 -D__linux__=1 -D_GNU_SOURCE=1 $XINC"
    for o in $OBJS; do
        $CC $WCFLAGS -c "$o.c" -o "$o.o" || { echo "compile failed: $o.c" >&2; exit 1; }
    done
    $CC $CFLAGS -o xwolf3d $(for o in $OBJS; do printf '%s.o ' "$o"; done) $SHIMS $SHIMS_COMPAT \
        $LDFLAGS -Wl,-z,stack-size=8388608 -Wl,--error-limit=0 $XLIB \
        -lXext -lX11 -lxcb -lXau $CRT1 -lc -lm $BUILTINS \
        || { echo "link failed" >&2; exit 1; }

    mkdir -p "$STAGE/usr/local/libexec" "$STAGE/usr/local/bin"
    install -m755 xwolf3d "$STAGE/usr/local/libexec/xwolf3d"
    cat > "$STAGE/usr/local/bin/wolf3d" <<'LAUNCHER'
#!/bin/sh
# Wolfenstein 3D (shareware). Needs an X server: run `xtiny &` first.
# The engine reads its .wl1 data and writes config/saves in its cwd.
: "${DISPLAY:=:1}"; export DISPLAY
cd /usr/local/share/wolf3d || exit 1
# stdin from /dev/null: an X client left holding the console busy-reads it.
exec /usr/local/libexec/xwolf3d "$@" </dev/null
LAUNCHER
    chmod 755 "$STAGE/usr/local/bin/wolf3d"
    rmdir "$STAGE/bin" 2>/dev/null || true
}
