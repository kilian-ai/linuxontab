#!/bin/sh
# Recipe: mc — GNU Midnight Commander
#
# STATUS (2026-08-08): WORKING — the "ncurses is broken" verdict was wrong.
# The initscr() SIGSEGV was wasm-ld's default 64KB stack: the terminfo read
# chain stacks ~70KB of local buffers (two MAX_ENTRY_SIZE=32KB buffers +
# PATH_MAX). Fixed with -Wl,-z,stack-size=8388608 on the mc link (same
# lesson python3.sh/nodejs.sh already encoded). ALWAYS set an explicit
# stack size for deep-stack/big-locals ports.
#
# KEY LESSON #2 (the patch scripts below): wasm traps any indirect call
# whose signature differs from the target function (glib-2.56's
# `(GFunc) free_func` 1-arg-as-2-arg casts, `(GCompareDataFunc)` 2-as-3).
# Every such cast must be routed through an exactly-typed thunk. Nine such
# sites fixed across glib and mc; without them mc dies in early init.
#
# Deps built inline (all static, wasm32):
#   - ncursesw 6.5  (same pattern as nano.sh)
#   - zlib 1.3.1    (glib requires it)
#   - glib 2.56.4   (last autotools glib; meson cross to wasm32 is not viable.
#                    Only the glib/ core lib is built — mc links -lglib-2.0
#                    only, no gobject/gio, so libffi is bypassed.)
#
# NOMMU/asyncify notes:
#   - wasm-musl has no fork()/vfork() symbols (only clone works). mc's
#     subshell and background jobs are fork-based -> disabled at configure.
#     Remaining fork references (glib gspawn, mc my_system) link against a
#     shim that does clone(SIGCHLD) via syscall — the kernel's worker gives
#     cloned children a real memory copy, same mechanism busybox hush uses.

NAME="mc"
VERSION="4.8.33"
DESCRIPTION="GNU Midnight Commander — visual file manager"
# upstream ftp.midnight-commander.org has a broken TLS cert; Debian mirrors
# the pristine upstream tarball
SOURCE_URL="https://deb.debian.org/debian/pool/main/m/mc/mc_4.8.33.orig.tar.xz"
SOURCE_SHA256=""  # filled after first download

NCURSES_VER="6.5"
NCURSES_URL="https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz"
ZLIB_VER="1.3.2"
ZLIB_URL="https://zlib.net/zlib-${ZLIB_VER}.tar.gz"
GLIB_VER="2.56.4"
GLIB_URL="https://download.gnome.org/sources/glib/2.56/glib-${GLIB_VER}.tar.xz"

build() {
    REPO_ROOT_PATCHES="$(cd "$(dirname "$0")/../toolchain/patches" 2>/dev/null && pwd)"
    [ -d "$REPO_ROOT_PATCHES" ] || REPO_ROOT_PATCHES="/Users/kilian/.ai/LinuxOnTab-kernel/toolchain/patches"

    # ── 1. ncursesw (identical to nano.sh's inline build) ───────────────────
    NCURSES_ARCHIVE="/tmp/lot-src-ncurses-${NCURSES_VER}.tar.gz"
    NCURSES_SRC="/tmp/lot-build/mc-ncurses"
    NCURSES_STAGE="/tmp/lot-build/mc-ncurses-prefix"

    if [ ! -f "$NCURSES_STAGE/usr/lib/libncursesw.a" ]; then
        if [ ! -f "$NCURSES_ARCHIVE" ]; then
            echo "==> Downloading ncurses $NCURSES_VER"
            curl -L --fail -o "$NCURSES_ARCHIVE" "$NCURSES_URL"
        fi
        rm -rf "$NCURSES_SRC"
        mkdir -p "$NCURSES_SRC"
        tar xzf "$NCURSES_ARCHIVE" -C "$NCURSES_SRC" --strip-components=1

        cd "$NCURSES_SRC"
        BUILD_CC="$(command -v gcc || command -v cc || echo gcc)"
        ./configure \
            --host=wasm32-unknown-linux-musl \
            --prefix=/usr \
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
    # mc's ncursesw detection wants the ncursesw/ header subdir layout
    if [ ! -d "$NCURSES_STAGE/usr/include/ncursesw" ]; then
        mkdir -p "$NCURSES_STAGE/usr/include/ncursesw"
        for _h in curses.h ncurses.h term.h termcap.h unctrl.h ncurses_dll.h panel.h; do
            [ -f "$NCURSES_STAGE/usr/include/$_h" ] && \
                cp "$NCURSES_STAGE/usr/include/$_h" "$NCURSES_STAGE/usr/include/ncursesw/"
        done
    fi

    # ── 2. zlib (static) ────────────────────────────────────────────────────
    ZLIB_ARCHIVE="/tmp/lot-src-zlib-${ZLIB_VER}.tar.gz"
    ZLIB_SRC="/tmp/lot-build/mc-zlib"
    ZLIB_STAGE="/tmp/lot-build/mc-zlib-prefix"

    if [ ! -f "$ZLIB_STAGE/lib/libz.a" ]; then
        if [ ! -f "$ZLIB_ARCHIVE" ]; then
            echo "==> Downloading zlib $ZLIB_VER"
            curl -L --fail -o "$ZLIB_ARCHIVE" "$ZLIB_URL"
        fi
        rm -rf "$ZLIB_SRC"
        mkdir -p "$ZLIB_SRC"
        tar xzf "$ZLIB_ARCHIVE" -C "$ZLIB_SRC" --strip-components=1
        cd "$ZLIB_SRC"
        # no configure — its link tests fail on wasm and poison the defines
        # (same approach as recipes/zlib.sh)
        _ZSRCS="adler32.c compress.c crc32.c deflate.c gzclose.c gzlib.c gzread.c \
            gzwrite.c infback.c inffast.c inflate.c inftrees.c trees.c \
            uncompr.c zutil.c"
        rm -f ./*.o
        # shellcheck disable=SC2086
        $CC $CFLAGS -DHAVE_UNISTD_H -c $_ZSRCS
        mkdir -p "$ZLIB_STAGE/lib" "$ZLIB_STAGE/include"
        $AR rcs "$ZLIB_STAGE/lib/libz.a" ./*.o
        $RANLIB "$ZLIB_STAGE/lib/libz.a"
        cp zlib.h zconf.h "$ZLIB_STAGE/include/"
    fi

    # ── 3. glib core (static, autotools) ────────────────────────────────────
    GLIB_ARCHIVE="/tmp/lot-src-glib-${GLIB_VER}.tar.xz"
    GLIB_SRC="/tmp/lot-build/mc-glib"
    GLIB_STAGE="/tmp/lot-build/mc-glib-prefix"

    # fork/vfork declarations: wasm-musl's unistd.h hides them behind
    # #ifndef __wasm__; the shim (step 4) provides the symbols at link time.
    FORK_DECLS="/tmp/lot-build/mc-fork-decls.h"
    mkdir -p /tmp/lot-build
    printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n' > "$FORK_DECLS"

    if [ ! -f "$GLIB_STAGE/lib/libglib-2.0.a" ]; then
        if [ ! -f "$GLIB_ARCHIVE" ]; then
            echo "==> Downloading glib $GLIB_VER"
            curl -L --fail -o "$GLIB_ARCHIVE" "$GLIB_URL"
        fi
        if [ ! -f "$GLIB_SRC/config.h" ]; then
        rm -rf "$GLIB_SRC"
        mkdir -p "$GLIB_SRC"
        tar xJf "$GLIB_ARCHIVE" -C "$GLIB_SRC" --strip-components=1
        cd "$GLIB_SRC"

        # wasm call_indirect signature fixes (see recipe header)
        python3 "$REPO_ROOT_PATCHES/glib-2.56-wasm-call-indirect.py"

        # Cross-compile cache answers for AC_TRY_RUN tests
        cat > wasm32.cache <<'CACHE'
glib_cv_stack_grows=${glib_cv_stack_grows=no}
glib_cv_uscore=${glib_cv_uscore=no}
ac_cv_func_posix_getpwuid_r=${ac_cv_func_posix_getpwuid_r=yes}
ac_cv_func_posix_getgrgid_r=${ac_cv_func_posix_getgrgid_r=yes}
glib_cv_use_pid_surrogate=${glib_cv_use_pid_surrogate=no}
ac_cv_func_printf_unix98=${ac_cv_func_printf_unix98=yes}
ac_cv_func_vsnprintf_c99=${ac_cv_func_vsnprintf_c99=yes}
CACHE

        # LIBFFI_*: satisfy the pkg-config check without libffi — we never
        # build gobject (make -C glib only).
        ./configure \
            --host=wasm32-unknown-linux-musl \
            --prefix="$GLIB_STAGE" \
            --cache-file=wasm32.cache \
            --enable-static --disable-shared \
            --with-pcre=internal \
            --disable-libmount --disable-fam --disable-xattr \
            --disable-selinux --disable-dtrace --disable-systemtap \
            --disable-compile-warnings \
            CC="$CC" CFLAGS="$CFLAGS -Wno-int-conversion -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types -include $FORK_DECLS" \
            LDFLAGS="$LDFLAGS" \
            LIBS="$CRT1 -lc -lm $BUILTINS" \
            AR="$AR" RANLIB="$RANLIB" \
            LIBFFI_CFLAGS="-I/tmp" LIBFFI_LIBS=" " \
            ZLIB_CFLAGS="-I$ZLIB_STAGE/include" ZLIB_LIBS="-L$ZLIB_STAGE/lib -lz" \
            PKG_CONFIG=/usr/bin/false
        fi
        cd "$GLIB_SRC"

        # subdir deps first (make -C glib libglib-2.0.la doesn't recurse)
        make -j4 -C glib/libcharset
        [ -d glib/gnulib ] && make -j4 -C glib/gnulib || true
        [ -d glib/pcre ] && make -j4 -C glib/pcre || true
        # macOS ar corrupts wasm .o archive members ("section too large").
        # Recreate every subdir convenience archive with llvm-ar from the
        # pristine objects (same workaround as recipes/curl.sh).
        # (static-only libtool keeps the non-PIC objects in the subdir root;
        # libtool also wrongly ar's $LIBS — CRT1/builtins — into the archive,
        # so rebuild each archive from the real objects only)
        for _la in glib/libcharset/*.la glib/gnulib/*.la glib/pcre/*.la; do
            [ -f "$_la" ] || continue
            _p="$(dirname "$_la")"
            _n="$(basename "$_la" .la)"
            ls "$_p"/*.o >/dev/null 2>&1 || continue
            mkdir -p "$_p/.libs"
            rm -f "$_p/.libs/$_n.a" "$_p/.libs/lib$_n.a"
            "$AR" crs "$_p/.libs/$_n.a" "$_p"/*.o
        done
        rm -rf glib/.libs/libglib-2.0.lax glib/.libs/libglib-2.0.a
        make -j4 -C glib libglib-2.0.la
        make -C glib DESTDIR="" install-libLTLIBRARIES install-glibincludeHEADERS \
             install-glibsubincludeHEADERS install-deprecatedincludeHEADERS 2>/dev/null || {
            # fall back: stage by hand
            mkdir -p "$GLIB_STAGE/lib" "$GLIB_STAGE/include/glib-2.0/glib/deprecated"
            cp glib/.libs/libglib-2.0.a "$GLIB_STAGE/lib/"
            cp glib/glib.h "$GLIB_STAGE/include/glib-2.0/"
            cp glib/*.h "$GLIB_STAGE/include/glib-2.0/glib/" 2>/dev/null || true
            cp glib/deprecated/*.h "$GLIB_STAGE/include/glib-2.0/glib/deprecated/" 2>/dev/null || true
        }
        # glibconfig.h is generated in the glib/ subdir
        mkdir -p "$GLIB_STAGE/lib/glib-2.0/include"
        cp glib/glibconfig.h "$GLIB_STAGE/lib/glib-2.0/include/"

        # libtool ar's $LIBS (crt1.o + nested builtins.a) into the installed
        # archive, which crashes wasm-ld ("malformed uleb128"). Rebuild the
        # staged archive from the pristine objects only.
        # glib/*.o includes the unprefixed gspawn.o/giounix.o too
        rm -f "$GLIB_STAGE/lib/libglib-2.0.a"
        "$AR" crs "$GLIB_STAGE/lib/libglib-2.0.a" \
            glib/*.o glib/deprecated/*.o \
            glib/libcharset/*.o glib/gnulib/*.o glib/pcre/*.o
        "$RANLIB" "$GLIB_STAGE/lib/libglib-2.0.a"
    fi

    # ── 4. fork shim: clone(SIGCHLD) via raw syscall ────────────────────────
    FORK_SHIM="/tmp/lot-build/mc-fork-shim.o"
    cat > /tmp/lot-build/mc-fork-shim.c <<'SHIM'
#include <signal.h>
#include <sys/syscall.h>
#include <unistd.h>
/* wasm-musl ships no fork/vfork (asyncify-only). The LinuxOnTab kernel's
 * worker implements clone-without-CLONE_VM with a real memory copy, so a
 * plain clone(SIGCHLD) behaves like fork. */
pid_t fork(void) { return syscall(SYS_clone, SIGCHLD, 0, 0, 0, 0); }
pid_t vfork(void) { return fork(); }
SHIM
    $CC $CFLAGS -c /tmp/lot-build/mc-fork-shim.c -o "$FORK_SHIM"

    # ── 5. mc ───────────────────────────────────────────────────────────────
    # mc hard-requires a pkg-config binary; jail the host one to our staged
    # .pc dir so no macOS libs leak in.
    mkdir -p "$GLIB_STAGE/lib/pkgconfig"
    cat > "$GLIB_STAGE/lib/pkgconfig/glib-2.0.pc" <<EOF
prefix=$GLIB_STAGE
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: GLib
Description: C Utility Library
Version: $GLIB_VER
Libs: -L\${libdir} -lglib-2.0
Cflags: -I\${includedir}/glib-2.0 -I\${libdir}/glib-2.0/include
EOF
    export PKG_CONFIG_LIBDIR="$GLIB_STAGE/lib/pkgconfig"

    cd "$SRC"
    # wasm call_indirect signature fixes in mc's own code
    python3 "$REPO_ROOT_PATCHES/mc-4.8.33-wasm-call-indirect.py"

    GLIB_CFLAGS="-I$GLIB_STAGE/include/glib-2.0 -I$GLIB_STAGE/lib/glib-2.0/include"
    GLIB_LIBS="-L$GLIB_STAGE/lib -lglib-2.0"

    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --with-screen=ncursesw \
        --without-subshell \
        --disable-background \
        --without-x \
        --disable-nls \
        --disable-shared \
        --disable-vfs-sftp \
        --enable-tests=no \
        CC="$CC" CFLAGS="$CFLAGS -Wno-int-conversion -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types -include $FORK_DECLS" \
        CPPFLAGS="-I$NCURSES_STAGE/usr/include" \
        LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608" \
        LIBS="$FORK_SHIM -L$NCURSES_STAGE/usr/lib -lncursesw $GLIB_LIBS $CRT1 -lc -lm $BUILTINS" \
        GLIB_CFLAGS="$GLIB_CFLAGS" GLIB_LIBS="$GLIB_LIBS" \
        AR="$AR" RANLIB="$RANLIB" \
        ac_cv_search_has_colors="-lncursesw" \
        ac_cv_search_stdscr="none required" \
        mc_cv_ncursesw_escdelay=yes \
        ac_cv_func_resizeterm=yes

    # libtool ar's $LIBS (builtins.a first) into every convenience archive;
    # llvm-ar on macOS then picks DARWIN format from the first member and
    # pads member sizes to 8 bytes, corrupting the wasm objects. Force GNU.
    export ARFLAGS="--format=gnu cr"
    make -j4
    install -Dm755 src/mc "$STAGE/bin/mc"

    # mc's runtime data files (menus, syntax, skins, help)
    make DESTDIR="$STAGE/mc-data" install-data 2>/dev/null || true
    if [ -d "$STAGE/mc-data/usr/share/mc" ]; then
        mkdir -p "$STAGE/usr/share"
        mv "$STAGE/mc-data/usr/share/mc" "$STAGE/usr/share/mc"
    fi
    # keymaps/menus/mc.ext.ini land in usr/etc (sysconfdir=$prefix/etc)
    if [ -d "$STAGE/mc-data/usr/etc/mc" ]; then
        mkdir -p "$STAGE/usr/etc"
        mv "$STAGE/mc-data/usr/etc/mc" "$STAGE/usr/etc/mc"
    fi
    if [ -d "$STAGE/mc-data/usr/libexec/mc" ]; then
        mkdir -p "$STAGE/usr/libexec"
        mv "$STAGE/mc-data/usr/libexec/mc" "$STAGE/usr/libexec/mc"
    fi
    rm -rf "$STAGE/mc-data"

    # terminfo (same as nano; guest may already have it from nano but ship anyway)
    TERMINFO_STAGE="$STAGE/usr/share/terminfo"
    if [ ! -d "$TERMINFO_STAGE" ]; then
        mkdir -p "$TERMINFO_STAGE"
        for _t in xterm-256color xterm vt100 vt102; do
            /usr/bin/infocmp -x "$_t" 2>/dev/null | \
                /usr/bin/tic -x -o "$TERMINFO_STAGE" - 2>/dev/null || true
        done
        mkdir -p "$TERMINFO_STAGE/v" "$TERMINFO_STAGE/x"
        [ -f "$TERMINFO_STAGE/76/vt100" ] && cp -f "$TERMINFO_STAGE/76/vt100" "$TERMINFO_STAGE/v/vt100"
        [ -f "$TERMINFO_STAGE/76/vt102" ] && cp -f "$TERMINFO_STAGE/76/vt102" "$TERMINFO_STAGE/v/vt102"
        [ -f "$TERMINFO_STAGE/78/xterm" ] && cp -f "$TERMINFO_STAGE/78/xterm" "$TERMINFO_STAGE/x/xterm"
        [ -f "$TERMINFO_STAGE/78/xterm-256color" ] && cp -f "$TERMINFO_STAGE/78/xterm-256color" "$TERMINFO_STAGE/x/xterm-256color"
    fi
}
