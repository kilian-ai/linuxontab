#!/bin/sh
# Recipe: xterm — the real X terminal emulator, for the xtiny X server
#
# Runs against xtiny (repo root) on DISPLAY=:1. xterm draws with core
# bitmap fonts + core drawing only — no Render/SHM/XKB — which is exactly
# what xtiny implements. In the guest:
#
#   xtiny &
#   DISPLAY=:1 xterm </dev/null &
#
# Notes for this platform:
#   - Toolbar disabled (--disable-toolbar): the menu path drags in more
#     Xaw machinery than we need; the scrollbar still works.
#   - Utempter/utmp, luit, and setuid helpers all disabled — no session
#     database in the guest.
#   - Terminfo for xterm/xterm-256color is already baked into the rootfs.

NAME="xterm"
VERSION="379"
DESCRIPTION="X terminal emulator"
DEPENDS="libX11 libXt libXaw"
SOURCE_URL="https://invisible-mirror.net/archives/xterm/xterm-${VERSION}.tgz"
SOURCE_SHA256=""

NCURSES_VER="6.5"
NCURSES_URL="https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz"
XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/xterm-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    # ── pty path ───────────────────────────────────────────────────────────
    # xterm picks its pty API by platform macro: the good branch
    # (openpty(), which allocates the master AND fills in ttydev) is gated
    # on __GLIBC__ or a BSD. We are musl, so xterm fell through to the
    # /dev/ptmx branch — which never sets ttydev, leaving the default
    # "/dev/tty" and failing with "open ttydev: I/O error". musl DOES
    # provide openpty() (pty.h), so widen the gate with our own macro
    # rather than impersonating glibc (which would switch on unrelated
    # glibc-only code paths).
    perl -0777 -i -pe 's/#if defined\(__osf__\) \|\| \(defined\(__GLIBC__\)/#if defined(LOT_USE_OPENPTY) || defined(__osf__) || (defined(__GLIBC__)/' main.c
    perl -0777 -i -pe 's/(#if OPT_WIDE_CHARS\n#include <charclass.h>\n#endif\n)/$1\n#ifdef LOT_USE_OPENPTY\n#include <pty.h>\t\t\/* openpty() *\/\n#endif\n/' main.c
    # Make the failure message name the device — "open ttydev" alone hides
    # whether the pty path produced a real /dev/pts name or fell back to
    # the "/dev/tty" default.
    perl -0777 -i -pe 's/perror\("open ttydev"\);/fprintf(stderr, "open ttydev \\"%s\\": %s\\n", ttydev ? ttydev : "(null)", strerror(errno));/' main.c
    grep -q "LOT_USE_OPENPTY" main.c || {
        echo "xterm pty patch did not apply — main.c layout changed" >&2
        exit 1
    }

    # ── controlling-terminal path ──────────────────────────────────────────
    # The child must OWN the new pty as its controlling terminal. xterm's
    # SysV branch only calls setpgrp(), relying on the SysV rule that a
    # process-group leader opening a tty acquires it. Linux does not work
    # that way: the opener must be a SESSION leader (setsid), otherwise the
    # subsequent open("/dev/tty") — which xterm REQUIRES before it accepts
    # the pty — fails with ENXIO because the child has no controlling
    # terminal at all in this guest. That failure is what the misleading
    # "open ttydev: No such device or address" message reports (it prints
    # the errno of the /dev/tty open, not of the ttydev open).
    perl -0777 -i -pe 's/#if defined\(CRAY\) && \(OSMAJORVERSION > 5\)\n(\s*)IGNORE_RC\(setsid\(\)\);/#if defined(LOT_USE_SETSID) || (defined(CRAY) \&\& (OSMAJORVERSION > 5))\n$1IGNORE_RC(setsid());/' main.c
    grep -q "LOT_USE_SETSID" main.c || {
        echo "xterm setsid patch did not apply — main.c layout changed" >&2
        exit 1
    }

    # ── diagnostics (XTERM_LOT_DIAG=1) ─────────────────────────────────────
    # Report the child's credentials/session state and, crucially, WHICH
    # open failed: ttyfd >= 0 in the failure message means ttydev opened
    # fine and /dev/tty is the one erroring.
    perl -0777 -i -pe 's/(\t\tfor \(;;\) \{\n)/\t\tif (getenv("XTERM_LOT_DIAG"))\n\t\t    fprintf(stderr, "[lotdiag] child pid=%d ppid=%d master_fd=%d F_GETFD=%d(%s) sid=%d pgrp=%d ttydev=%s\\n",\n\t\t\t    (int) getpid(), (int) getppid(), screen->respond,\n\t\t\t    fcntl(screen->respond, F_GETFD), strerror(errno),\n\t\t\t    (int) getsid(0), (int) getpgrp(),\n\t\t\t    ttydev ? ttydev : "(null)");\n$1/' main.c
    perl -0777 -i -pe 's/fprintf\(stderr, "open ttydev \\"%s\\": %s\\n", ttydev \? ttydev : "\(null\)", strerror\(errno\)\);/fprintf(stderr, "open ttydev \\"%s\\": %s (ttyfd=%d sid=%d pgrp=%d)\\n", ttydev ? ttydev : "(null)", strerror(errno), ttyfd, (int) getsid(0), (int) getpgrp());/' main.c
    grep -q "lotdiag" main.c || {
        echo "xterm diag patch did not apply — main.c layout changed" >&2
        exit 1
    }

    # ── ncurses (for tgetent/terminfo); reuse mc's prefix if present ────────
    NCURSES_STAGE="/tmp/lot-build/mc-ncurses-prefix"
    if [ ! -f "$NCURSES_STAGE/usr/lib/libncursesw.a" ]; then
        NCURSES_ARCHIVE="/tmp/lot-src-ncurses-${NCURSES_VER}.tar.gz"
        NCURSES_SRC="/tmp/lot-build/xterm-ncurses"
        NCURSES_STAGE="/tmp/lot-build/xterm-ncurses-prefix"
        if [ ! -f "$NCURSES_STAGE/usr/lib/libncursesw.a" ]; then
            [ -f "$NCURSES_ARCHIVE" ] || \
                curl -L --fail -o "$NCURSES_ARCHIVE" "$NCURSES_URL"
            rm -rf "$NCURSES_SRC"; mkdir -p "$NCURSES_SRC"
            tar xzf "$NCURSES_ARCHIVE" -C "$NCURSES_SRC" --strip-components=1
            cd "$NCURSES_SRC"
            BUILD_CC="$(command -v gcc || command -v cc || echo gcc)"
            ./configure \
                --host=wasm32-unknown-linux-musl --prefix=/usr \
                --without-shared --without-progs --without-manpages \
                --without-pkg-config --without-tests \
                --without-cxx --without-cxx-binding --without-ada \
                --with-normal --enable-widec --enable-overwrite \
                --with-default-terminfo-dir=/usr/share/terminfo \
                --with-terminfo-dirs=/usr/share/terminfo:/lib/terminfo:/etc/terminfo \
                CC="$CC" CFLAGS="$CFLAGS" \
                LDFLAGS="-nostdlib" LIBS="$CRT1 -lc $BUILTINS" \
                AR="$AR" RANLIB="$RANLIB" BUILD_CC="$BUILD_CC"
            make -j4
            make DESTDIR="$NCURSES_STAGE" install.libs install.includes
        fi
        cd "$SRC"
    fi

    for dep in libX11 libXext libXt libXmu libXaw; do
        [ -d "/tmp/lot-build/$dep/stage" ] || {
            echo "Missing /tmp/lot-build/$dep staged tree. Run ./packages/build-package.sh $dep first." >&2
            exit 1
        }
    done

    DEPS_PREFIX="/tmp/lot-build/xterm-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    for dep in libX11 libxcb libXau libXdmcp libXext libXt libXmu libXpm libXaw libSM libICE; do
        cp -R /tmp/lot-build/$dep/stage/usr/include/* "$DEPS_PREFIX/include/" 2>/dev/null || true
        cp -f /tmp/lot-build/$dep/stage/usr/lib/*.a "$DEPS_PREFIX/lib/" 2>/dev/null || true
    done
    cp -R "$NCURSES_STAGE/usr/include/"* "$DEPS_PREFIX/include/" 2>/dev/null || true
    cp -f "$NCURSES_STAGE/usr/lib/"*.a "$DEPS_PREFIX/lib/" 2>/dev/null || true
    # libXaw installs versioned archives; xterm links -lXaw.
    [ -f "$DEPS_PREFIX/lib/libXaw7.a" ] && cp -f "$DEPS_PREFIX/lib/libXaw7.a" "$DEPS_PREFIX/lib/libXaw.a"
    printf '%s\n' \
        '#ifndef _X11_XPOLL_H_' \
        '#define _X11_XPOLL_H_' \
        '#include <poll.h>' \
        '#endif' \
        > "$DEPS_PREFIX/include/X11/Xpoll.h"

    # The X11compat shim from the xeyes recipe (XSupportsLocale etc.) —
    # xterm pulls the same reduced-libX11 gaps.
    if [ -f /tmp/lot-build/xeyes-deps-prefix/lib/libX11compat.a ]; then
        cp -f /tmp/lot-build/xeyes-deps-prefix/lib/libX11compat.a "$DEPS_PREFIX/lib/"
        X11COMPAT="-lX11compat"
    else
        X11COMPAT=""
    fi

    # ── xterm-specific compat: the i18n text-property calls our reduced
    # libX11 omits. These are REAL implementations, not stubs returning
    # Success: Xlib callers XFree() the buffers these hand back (that
    # exact trap killed xeyes — see the XmbTextListToTextProperty note in
    # xeyes.sh), and xterm round-trips selections through them. ──
    cat > "$SRC/xterm_compat.c" << 'COMPATEOF'
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <wchar.h>
#include <stdlib.h>
#include <string.h>

/* Property (NUL-separated blob) → NULL-terminated char* list. Matches
 * XFreeStringList's contract: one allocation for the text (list[0]) plus
 * one for the pointer array. */
static int prop_to_list(const XTextProperty *tp, char ***list, int *count)
{
    unsigned long n = tp ? tp->nitems : 0;
    const char *src = (tp && tp->value) ? (const char *)tp->value : "";
    char *buf;
    char **arr;
    unsigned long i;
    int items = 0;

    if (list) *list = NULL;
    if (count) *count = 0;
    if (!list || !count) return -1;          /* XNoMemory-ish */

    buf = (char *)malloc((size_t)n + 1);
    if (!buf) return -1;
    memcpy(buf, src, (size_t)n);
    buf[n] = '\0';

    for (i = 0; i < n; i++) if (src[i] == '\0') items++;
    if (n > 0 && src[n - 1] != '\0') items++;  /* unterminated tail */
    if (items == 0) items = 1;

    arr = (char **)malloc(sizeof(char *) * (size_t)(items + 1));
    if (!arr) { free(buf); return -1; }

    {
        int k = 0;
        char *p = buf;
        char *end = buf + n;
        while (k < items) {
            arr[k++] = p;
            while (p < end && *p != '\0') p++;
            if (p < end) p++;                 /* step past the NUL */
        }
        arr[k] = NULL;
    }
    *list = arr;
    *count = items;
    return 0;                                 /* Success */
}

int XmbTextPropertyToTextList(Display *d, const XTextProperty *tp,
                              char ***list, int *count)
{ (void)d; return prop_to_list(tp, list, count); }

int Xutf8TextPropertyToTextList(Display *d, const XTextProperty *tp,
                                char ***list, int *count)
{ (void)d; return prop_to_list(tp, list, count); }

int XwcTextPropertyToTextList(Display *d, const XTextProperty *tp,
                              wchar_t ***list, int *count)
{ (void)d; (void)tp; if (list) *list = NULL; if (count) *count = 0; return -1; }

/* List → property. The caller XFree()s value, so it must be malloc'd. */
static int list_to_prop(char **list, int count, Atom encoding,
                        XTextProperty *tp)
{
    unsigned long total = 0;
    int i;
    char *buf, *p;

    if (!tp) return -1;
    for (i = 0; i < count; i++)
        total += (unsigned long)strlen(list && list[i] ? list[i] : "") + 1;
    if (total == 0) total = 1;

    buf = (char *)malloc((size_t)total);
    if (!buf) return -1;
    p = buf;
    for (i = 0; i < count; i++) {
        const char *s = (list && list[i]) ? list[i] : "";
        size_t len = strlen(s);
        memcpy(p, s, len);
        p += len;
        *p++ = '\0';
    }
    if (p == buf) *p++ = '\0';

    tp->value = (unsigned char *)buf;
    tp->encoding = encoding;
    tp->format = 8;
    tp->nitems = (unsigned long)(p - buf) - 1;   /* excl. final NUL */
    return 0;                                    /* Success */
}

int Xutf8TextListToTextProperty(Display *d, char **list, int count,
                                XICCEncodingStyle style, XTextProperty *tp)
{
    (void)d; (void)style;
    /* No locale support in this build, so everything is bytes; report
     * STRING, which every X client understands. */
    return list_to_prop(list, count, XA_STRING, tp);
}

int XwcTextListToTextProperty(Display *d, wchar_t **list, int count,
                              XICCEncodingStyle style, XTextProperty *tp)
{ (void)d; (void)list; (void)count; (void)style; (void)tp; return -1; }

/* ── Xaw's XIM path (XawIm.c is compiled unconditionally) ──────────────
 * There is no input-method server in the guest, so XCreateIC HONESTLY
 * fails with NULL; Xaw guards every other IC call on that, which is the
 * behaviour of a real Xlib against a display with no XIM. The IC-value
 * calls therefore never see a live IC — they report "first failed arg"
 * so nobody mistakes a no-op for success. */
XIM XOpenIM(Display *d, struct _XrmHashBucketRec *db, char *rn, char *rc)
{ (void)d; (void)db; (void)rn; (void)rc; return NULL; }

Status XCloseIM(XIM im) { (void)im; return 0; }

Display *XDisplayOfIM(XIM im) { (void)im; return NULL; }

XIC XCreateIC(XIM im, ...) { (void)im; return NULL; }

void XDestroyIC(XIC ic) { (void)ic; }

void XSetICFocus(XIC ic) { (void)ic; }
void XUnsetICFocus(XIC ic) { (void)ic; }

char *XGetICValues(XIC ic, ...) { (void)ic; return (char *)"noXIM"; }
char *XSetICValues(XIC ic, ...) { (void)ic; return (char *)"noXIM"; }

XVaNestedList XVaCreateNestedList(int dummy, ...) { (void)dummy; return NULL; }

/* Fontset text: this build has a single fixed-width 8px font, so
 * escapement is exact and drawing maps straight onto the core call. */
int XmbTextEscapement(XFontSet fs, _Xconst char *text, int len)
{ (void)fs; (void)text; return len * 8; }

void XmbDrawString(Display *d, Drawable w, XFontSet fs, GC gc,
                   int x, int y, _Xconst char *text, int len)
{ (void)fs; XDrawString(d, w, gc, x, y, text, len); }

/* ── single-user credentials ───────────────────────────────────────────
 * The guest kernel is built without CONFIG_MULTIUSER, so libc's
 * setuid/setgid always fail — and xterm exits when its privilege-drop
 * fails ("unable to reset uid"). These implementations succeed exactly
 * when the request is a no-op (target id == current id, always true in
 * this single-user guest, everything is root) and fail with EPERM for a
 * real change. That is the true postcondition, not a lie: after the
 * call the process really does run as the requested id. Linked BEFORE
 * -lc so these win over libc's versions. */
#include <unistd.h>
#include <errno.h>

int setuid(uid_t u)  { if (u == getuid())  return 0; errno = EPERM; return -1; }
int setgid(gid_t g)  { if (g == getgid())  return 0; errno = EPERM; return -1; }
int seteuid(uid_t u) { if (u == geteuid()) return 0; errno = EPERM; return -1; }
int setegid(gid_t g) { if (g == getegid()) return 0; errno = EPERM; return -1; }
COMPATEOF
    $CC $CFLAGS -O1 -I"$XPROTO_SRC/include" -I"$DEPS_PREFIX/include" \
        -c "$SRC/xterm_compat.c" -o "$SRC/xterm_compat.o"
    # fork()/vfork() via the kernel's asyncify syscall (musl wasm32 omits
    # them); same object the nodejs recipe uses.
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_fork.c" -o "$SRC/wasm_fork.o"
    "$AR" rcs "$DEPS_PREFIX/lib/libxtermcompat.a" \
        "$SRC/xterm_compat.o" "$SRC/wasm_fork.o"

    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = "--version" ]; then echo "1.0"; exit 0; fi' \
        'if [ "$1" = "--modversion" ]; then echo "1.0"; exit 0; fi' \
        'if [ "$1" = "--exists" ] || [ "$1" = "--print-errors" ]; then exit 0; fi' \
        'if [ "$1" = "--cflags" ]; then echo "-I'"$XPROTO_SRC"'/include -I'"$DEPS_PREFIX"'/include"; exit 0; fi' \
        'if [ "$1" = "--libs" ]; then echo "-L'"$DEPS_PREFIX"'/lib -lXaw -lXmu -lXt -lXpm -lXext -lX11 -lxcb -lXau -lSM -lICE"; exit 0; fi' \
        'exit 0' \
        > "$SRC/pkg-config"
    chmod +x "$SRC/pkg-config"
    export PKG_CONFIG="$SRC/pkg-config"

    # `-target wasm32` predefines NEITHER linux NOR __linux__, but the guest
    # IS Linux. Without these, xterm's platform detection falls through to
    # the 1980s sgtty branch (fatal: sgtty.h not found) and picks wrong pty
    # and signal paths. Define them so xterm takes its normal Linux route.
    LINUXDEF="-Dlinux=1 -D__linux__=1 -D_GNU_SOURCE=1 -DNO_XPOLL_H=1 -DLOT_USE_OPENPTY=1 -DLOT_USE_SETSID=1"

    # Cross-compile answers configure cannot probe by running code.
    export cf_cv_type_fd_mask=yes
    export cf_cv_posix_saved_ids=no
    export cf_cv_ttysize=no
    export cf_cv_have_ptem=no
    export cf_cv_sysv_utmp=no
    export cf_cv_have_utmp=no
    export cf_cv_lastlog=no
    export cf_cv_working_poll=yes
    export cf_cv_func_grantpt=yes

    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-setuid \
        --disable-setgid \
        --disable-imake \
        --disable-toolbar \
        --disable-luit \
        --disable-session-mgt \
        --disable-double-buffer \
        --disable-freetype \
        --disable-tcap-query \
        --disable-rectangles \
        --disable-regis-graphics \
        --without-utempter \
        --without-xinerama \
        --with-x \
        --x-includes="$DEPS_PREFIX/include" \
        --x-libraries="$DEPS_PREFIX/lib" \
        CC="$CC" \
        CFLAGS="$CFLAGS -O1 $LINUXDEF -I$XPROTO_SRC/include -I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/ncursesw" \
        CPPFLAGS="$LINUXDEF -I$XPROTO_SRC/include -I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/ncursesw" \
        LDFLAGS="$LDFLAGS -L$DEPS_PREFIX/lib" \
        LIBS="$CRT1 -lxtermcompat -lc -lm $BUILTINS -lXaw -lXmu -lXt -lXpm -lXext -lX11 -lxcb -lXau $X11COMPAT -lSM -lICE -lncursesw"

    # Compile everything, then link by hand: xterm's generated link line
    # carries `-rpath <dir>` (autoconf X_LIBS), which wasm-ld rejects — it
    # has no runtime loader, so the flag is meaningless here anyway.
    make -j4 $(ls *.c 2>/dev/null | sed 's/\.c$/.o/' | tr '\n' ' ') || true
    make -j4 xterm || true
    [ -f xterm ] || {
        echo "==> relinking xterm without -rpath"
        # shellcheck disable=SC2086
        $CC $LDFLAGS -o xterm *.o \
            $CRT1 -L"$DEPS_PREFIX/lib" -lxtermcompat -lc -lm $BUILTINS \
            -lXaw -lXmu -lXt -lXpm -lXext -lX11 -lxcb -lXau $X11COMPAT \
            -lSM -lICE -lncursesw
    }
    mkdir -p "$STAGE/usr/bin"
    cp -f xterm "$STAGE/usr/bin/xterm"
}
