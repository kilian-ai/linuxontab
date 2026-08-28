#!/bin/sh
# Recipe: xeyes — simple X11 eye-follow demo app

NAME="xeyes"
VERSION="1.3.0"
DESCRIPTION="X11 eye-follow demo"
# Runtime deps resolved by the in-guest `apk`: xeyes needs an X server to draw
# into (Xvfb) and a way to see it in the browser (x11vnc). Static binary, so
# these are service deps, not shared libs.
DEPENDS="xvfb x11vnc"
SOURCE_URL="https://www.x.org/archive/individual/app/xeyes-${VERSION}.tar.gz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/xeyes-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    [ -f "/tmp/lot-build/libX11/stage/usr/lib/libX11.a" ] || {
        echo "Missing /tmp/lot-build/libX11 staged library. Run ./packages/build-package.sh libX11 first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libxcb/stage/usr/include/xcb/xcb.h" ] || {
        echo "Missing /tmp/lot-build/libxcb staged headers. Run ./packages/build-package.sh libxcb first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXext/stage/usr/lib/libXext.a" ] || {
        echo "Missing /tmp/lot-build/libXext staged library. Run ./packages/build-package.sh libXext first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXt/stage/usr/lib/libXt.a" ] || {
        echo "Missing /tmp/lot-build/libXt staged library. Run ./packages/build-package.sh libXt first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXmu/stage/usr/lib/libXmu.a" ] || {
        echo "Missing /tmp/lot-build/libXmu staged library. Run ./packages/build-package.sh libXmu first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXrender/stage/usr/lib/libXrender.a" ] || {
        echo "Missing /tmp/lot-build/libXrender staged library. Run ./packages/build-package.sh libXrender first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXi/stage/usr/lib/libXi.a" ] || {
        echo "Missing /tmp/lot-build/libXi staged library. Run ./packages/build-package.sh libXi first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXfixes/stage/usr/lib/libXfixes.a" ] || {
        echo "Missing /tmp/lot-build/libXfixes staged library. Run ./packages/build-package.sh libXfixes first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXau/stage/usr/lib/libXau.a" ] || {
        echo "Missing /tmp/lot-build/libXau staged library. Run ./packages/build-package.sh libXau first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/xeyes-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    cp -R /tmp/lot-build/libX11/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libxcb/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXext/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXt/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXmu/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXrender/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXi/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXfixes/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXau/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libSM/stage/usr/include/* "$DEPS_PREFIX/include/" 2>/dev/null || true
    cp -R /tmp/lot-build/libICE/stage/usr/include/* "$DEPS_PREFIX/include/" 2>/dev/null || true
    cp -f /tmp/lot-build/libX11/stage/usr/lib/libX11.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libX11/stage/usr/lib/libX11-xcb.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libxcb/stage/usr/lib/libxcb.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXext/stage/usr/lib/libXext.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXt/stage/usr/lib/libXt.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXmu/stage/usr/lib/libXmu.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXrender/stage/usr/lib/libXrender.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXi/stage/usr/lib/libXi.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXfixes/stage/usr/lib/libXfixes.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXau/stage/usr/lib/libXau.a "$DEPS_PREFIX/lib/"
    [ -f /tmp/lot-build/libSM/stage/usr/lib/libSM.a ] && cp -f /tmp/lot-build/libSM/stage/usr/lib/libSM.a "$DEPS_PREFIX/lib/" || true
    [ -f /tmp/lot-build/libICE/stage/usr/lib/libICE.a ] && cp -f /tmp/lot-build/libICE/stage/usr/lib/libICE.a "$DEPS_PREFIX/lib/" || true

    # Compatibility shims for symbols absent from our reduced libX11 build.
    printf '%s\n' \
        '#include <stddef.h>' \
        '#include <stdarg.h>' \
        '#include <string.h>' \
        '#include <stdlib.h>' \
        '' \
        'typedef void *XlcArgList;' \
        'void *_Xi18n_lock = 0;' \
        'void *_conv_lock = 0;' \
        '' \
        'int XSupportsLocale(void) { return 0; }' \
        'char *XSetLocaleModifiers(const char *mod) { return (char *)mod; }' \
        '/* Real STRING-style implementation, NOT a lying stub: libXt Shell.c' \
        ' * Realize passes the result to XChangeProperty and then XFree()s' \
        ' * text_prop->value. A stub that returns Success without filling the' \
        ' * struct makes Xt free an uninitialized pointer — mallocng get_meta' \
        ' * traps (unreachable) and the client dies in XtRealizeWidget. */' \
        'struct _xtp_shim { unsigned char *value; unsigned long encoding; int format; unsigned long nitems; };' \
        'int XmbTextListToTextProperty(void *dpy, char **list, int count, int style, void *text_prop) {' \
        '    struct _xtp_shim *tp = (struct _xtp_shim *)text_prop;' \
        '    unsigned long total = 0;' \
        '    int i;' \
        '    (void)dpy; (void)style;' \
        '    for (i = 0; i < count; i++) total += strlen(list[i] ? list[i] : "") + 1;' \
        '    if (total == 0) total = 1;' \
        '    {' \
        '        unsigned char *buf = (unsigned char *)malloc(total);' \
        '        unsigned long off = 0;' \
        '        if (!buf) return -1;  /* XNoMemory */' \
        '        for (i = 0; i < count; i++) {' \
        '            const char *s = list[i] ? list[i] : "";' \
        '            unsigned long n = strlen(s);' \
        '            memcpy(buf + off, s, n);' \
        '            off += n;' \
        '            buf[off++] = 0;   /* separator / trailing NUL */' \
        '        }' \
        '        if (off == 0) buf[off++] = 0;' \
        '        tp->value = buf;' \
        '        tp->encoding = 31;    /* XA_STRING */' \
        '        tp->format = 8;' \
        '        tp->nitems = off - 1; /* excludes the final NUL */' \
        '    }' \
        '    return 0;                 /* Success */' \
        '}' \
        'int XkbLookupKeySym(void *dpy, unsigned int kc, unsigned int state, unsigned int *mods, unsigned int *sym) {' \
        '    (void)dpy; (void)kc; (void)state;' \
        '    if (mods) *mods = 0;' \
        '    if (sym) *sym = 0;' \
        '    return 0;' \
        '}' \
        'void *_XOpenLC(char *name) { (void)name; return 0; }' \
        'void _XCloseLC(void *lc) { (void)lc; }' \
        'void *_XlcCurrentLC(void) { return _XOpenLC((char *)0); }' \
        'int _XlcNCompareISOLatin1(const char *a, const char *b, int n) {' \
        '    if (!a) a = "";' \
        '    if (!b) b = "";' \
        '    return strncmp(a, b, (size_t)(n < 0 ? 0 : n));' \
        '}' \
        'void _XlcCountVaList(va_list var, int *count_return) {' \
        '    (void)var;' \
        '    if (count_return) *count_return = 0;' \
        '}' \
        'void _XlcVaToArgList(va_list var, int count, XlcArgList *args_return) {' \
        '    (void)var; (void)count;' \
        '    if (args_return) *args_return = 0;' \
        '}' \
        'void *_XrmInitParseInfo(void *statep) {' \
        '    if (statep) *(void **)statep = 0;' \
        '    return 0;' \
        '}' \
        > "$SRC/x11_compat.c"
    $CC -c "$SRC/x11_compat.c" -o "$SRC/x11_compat.o" $CFLAGS
    "$AR" rcs "$DEPS_PREFIX/lib/libX11compat.a" "$SRC/x11_compat.o"

    # Lightweight breadcrumbs for crash correlation.
    cat > "$SRC/trace_instrument.c" << 'EOF'
#include <unistd.h>
#include <stdint.h>
#include <stddef.h>

static volatile unsigned xe_counter = 0;

__attribute__((no_instrument_function))
static size_t cstr_len(const char *s) {
    size_t n = 0;
    while (s && s[n]) n++;
    return n;
}

__attribute__((no_instrument_function))
static int write_hex(char *dst, uintptr_t v) {
    static const char hex[] = "0123456789abcdef";
    for (int i = (int)(sizeof(uintptr_t) * 2) - 1; i >= 0; --i) {
        dst[i] = hex[v & 0xfU];
        v >>= 4U;
    }
    return (int)(sizeof(uintptr_t) * 2);
}

__attribute__((no_instrument_function))
void xe_trace(const char *tag) {
    unsigned ncall = __atomic_add_fetch(&xe_counter, 1U, __ATOMIC_RELAXED);
    // Sample to reduce log volume while preserving ordering clues.
    if ((ncall & 0x3fU) != 0U) return;
    char buf[64];
    int n = 0;
    buf[n++] = 'X';
    buf[n++] = 'E';
    buf[n++] = ':';
    size_t tlen = cstr_len(tag);
    if (tlen > 40U) tlen = 40U;
    for (size_t i = 0; i < tlen; i++) buf[n++] = tag[i];
    buf[n++] = ':';
    n += write_hex(buf + n, (uintptr_t)ncall);
    buf[n++] = '\n';
    (void)write(2, buf, (size_t)n);
}
EOF
    $CC -c "$SRC/trace_instrument.c" -o "$SRC/trace_instrument.o" $CFLAGS -fno-builtin
    "$AR" rcs "$DEPS_PREFIX/lib/libXEtrace.a" "$SRC/trace_instrument.o"

    cat > "$SRC/trace_instrument.h" << 'EOF'
#ifndef XE_TRACE_INSTRUMENT_H
#define XE_TRACE_INSTRUMENT_H
void xe_trace(const char *tag);
#endif
EOF

    # Inject breadcrumb calls in hot lifecycle/render functions.
    perl -0777 -i -pe 's/(main\(int argc, char \*\*argv\)\n\{)/$1\n    xe_trace("xeyes.main");/s' "$SRC/xeyes.c"

    perl -0777 -i -pe 's/(static void draw_it_core\(EyesWidget w\)\n\{)/$1\n    xe_trace("Eyes.draw_it_core");/s' "$SRC/Eyes.c"
    perl -0777 -i -pe 's/(static void draw_it \(\n\s*XtPointer closure,\n\s*XtIntervalId \*id\)\n\{)/$1\n    xe_trace("Eyes.draw_it");/s' "$SRC/Eyes.c"
    perl -0777 -i -pe 's/(static void Resize \(Widget gw\)\n\{)/$1\n    xe_trace("Eyes.Resize");/s' "$SRC/Eyes.c"
    perl -0777 -i -pe 's/(static void Realize \(\n\s*Widget gw,\n\s*XtValueMask \*valueMask,\n\s*XSetWindowAttributes \*attributes\)\n\{)/$1\n    xe_trace("Eyes.Realize");/s' "$SRC/Eyes.c"
    perl -0777 -i -pe 's/(static void Redisplay\(\n\s*Widget gw,\n\s*XEvent \*event,\n\s*Region region\)\n\{)/$1\n    xe_trace("Eyes.Redisplay");/s' "$SRC/Eyes.c"
    perl -0777 -i -pe 's/(static Boolean SetValues \(\n\s*Widget current,\n\s*Widget request,\n\s*Widget new,\n\s*ArgList args,\n\s*Cardinal \*num_args\)\n\{)/$1\n    xe_trace("Eyes.SetValues");/s' "$SRC/Eyes.c"

    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = "--version" ]; then echo "1.0"; exit 0; fi' \
        'if [ "$1" = "--modversion" ]; then' \
        '  case "$2" in' \
        '    x11) echo "1.8.10" ;;' \
        '    xext) echo "1.3.6" ;;' \
        '    xt) echo "1.3.1" ;;' \
        '    xmu) echo "1.2.1" ;;' \
        '    xrender) echo "0.9.12" ;;' \
        '    xi) echo "1.8.2" ;;' \
        '    xfixes) echo "6.0.1" ;;' \
        '    xeyes) echo "1.3.0" ;;' \
        '    *) echo "1.0" ;;' \
        '  esac' \
        '  exit 0' \
        'fi' \
        'if [ "$1" = "--exists" ] || [ "$1" = "--print-errors" ]; then exit 0; fi' \
        'if [ "$1" = "--cflags" ]; then echo "-I'"$XPROTO_SRC"'/include -I'"$DEPS_PREFIX"'/include"; exit 0; fi' \
        'if [ "$1" = "--libs" ]; then echo "-L'"$DEPS_PREFIX"'/lib -lXi -lXfixes -lXrender -lXmu -lXt -lXext -lX11 -lX11-xcb -lxcb -lXau -lX11compat -lSM -lICE"; exit 0; fi' \
        'exit 0' \
        > "$SRC/pkg-config"
    chmod +x "$SRC/pkg-config"

    export PKG_CONFIG="$SRC/pkg-config"

    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --with-present=no \
        --with-xrender=no \
        CC="$CC" \
        CFLAGS="$CFLAGS -O0 -I$XPROTO_SRC/include -I$DEPS_PREFIX/include" \
        LDFLAGS="$LDFLAGS -L$DEPS_PREFIX/lib" \
        LIBS="$CRT1 -lc -lm $BUILTINS -lXi -lXfixes -lXrender -lXmu -lXt -lXext -lX11 -lX11-xcb -lxcb -lXau -lX11compat -lXEtrace -lSM -lICE"

    make -j4 CFLAGS="$CFLAGS -O0 -include $SRC/trace_instrument.h -I$XPROTO_SRC/include -I$DEPS_PREFIX/include"
    make DESTDIR="$STAGE" install
}
