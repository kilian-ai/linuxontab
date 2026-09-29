#!/bin/sh
# NOT ACTIVE (moved out of packages/recipes, 2026-09-29). A from-source zsh
# recipe: it builds and simple commands and single forks work, but NESTED
# command substitution comes back empty (zsh -c 'x=$(echo $(echo hi))' ->
# ""), which breaks clawlite's first line. The committed rootfs/bin/zsh
# (built by local/build-zsh.sh, commit 1871791) does not have the problem,
# and its build tree is gone, so the difference is unknown (compiler build,
# ncurses build, or a manual step not in build-zsh.sh). packages/recipes/zsh.sh
# packages that proven binary instead. Copy this back to packages/recipes/
# when the nested-fork difference is found.
#
# Recipe: zsh — the Z shell 5.9, static, as /bin/zsh.
#
# The guest's /bin/sh is busybox hush on a no-MMU kernel. It cannot fork,
# so it runs children by re-parsing function definitions from saved text,
# which drops heredoc bodies: any function containing a heredoc fails in a
# pipeline or $(...) ("syntax error: unexpected EOF in here document"). The
# lean image's hush also lacks $(...) assignments. zsh uses the kernel's
# asyncify fork (sysroot/wasm_fork.c), so children are real copies and
# ordinary POSIX scripts just work — `zsh --emulate sh script`, or zsh run
# under the name `sh`. The claw package runs on it.
#
# Build (from local/build-zsh.sh, where the history is):
#   - wasm exception-handling setjmp/longjmp (zsh leans on setjmp/longjmp
#     plus fork, which only compose under wasm-EH) + sysroot/sjlj_rt_wasmeh.c
#   - fork/vfork prototypes (the sysroot hides them behind __wasm__) and the
#     fork thunk
#   - toolchain/patches/zsh-5.9-wasm-call-indirect.py: two zero-argument
#     completion hooks registered as 2-argument Hookfn trapped every
#     interactive zsh at its first keypress
#   - configure answers for probes that cannot run when cross-compiling
#   - static ncursesw (same build as the xterm recipe, shared prefix)

NAME="zsh"
VERSION="5.9"
DESCRIPTION="Z shell 5.9 — also a POSIX sh for scripts busybox hush can't run (zsh --emulate sh)"
SOURCE_URL="https://sourceforge.net/projects/zsh/files/zsh/5.9/zsh-5.9.tar.xz/download"
SOURCE_SHA256="9b8d1ecedd5b5e81fbf1918e876752a7dd948e05c1a0dba10ab863842d45acd5"

NCURSES_VER="6.5"
NCURSES_URL="https://invisible-mirror.net/archives/ncurses/ncurses-${NCURSES_VER}.tar.gz"
NCURSES_SHA256="136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"

build() {
    # ── static ncursesw (shared with the xterm recipe's prefix) ───────────
    NC="/tmp/lot-build/xterm-ncurses-prefix"
    if [ ! -f "$NC/usr/lib/libncursesw.a" ]; then
        A="/tmp/lot-src-ncurses-${NCURSES_VER}.tar.gz"
        [ -f "$A" ] || curl -sL --fail -o "$A" "$NCURSES_URL" || { echo "ncurses download failed" >&2; exit 1; }
        [ "$(shasum -a 256 "$A" | cut -d' ' -f1)" = "$NCURSES_SHA256" ] || { echo "ncurses checksum mismatch" >&2; exit 1; }
        rm -rf "$SRC/ncurses" && mkdir -p "$SRC/ncurses" && tar xzf "$A" -C "$SRC/ncurses" --strip-components=1
        ( cd "$SRC/ncurses" && ./configure \
            --host=wasm32-unknown-linux-musl --prefix=/usr \
            --without-shared --without-progs --without-manpages \
            --without-pkg-config --without-tests \
            --without-cxx --without-cxx-binding --without-ada \
            --with-normal --enable-widec --enable-overwrite \
            --with-default-terminfo-dir=/usr/share/terminfo \
            --with-terminfo-dirs=/usr/share/terminfo:/lib/terminfo:/etc/terminfo \
            CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="-nostdlib" LIBS="$CRT1 -lc $BUILTINS" \
            AR="$AR" RANLIB="$RANLIB" BUILD_CC=cc > configure.log 2>&1 \
          && make -j4 > make.log 2>&1 \
          && make DESTDIR="$NC" install.libs install.includes > install.log 2>&1 ) \
          || { echo "ncurses build failed" >&2; exit 1; }
    fi

    python3 "$REPO_ROOT/toolchain/patches/zsh-5.9-wasm-call-indirect.py" \
        || { echo "zsh call_indirect patch failed" >&2; exit 1; }

    SJLJ="-mexception-handling -mllvm -wasm-enable-sjlj"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_fork.c" -o "$SRC/wasm_fork.o"
    $CC $CFLAGS $SJLJ -c "$REPO_ROOT/sysroot/sjlj_rt_wasmeh.c" -o "$SRC/sjlj_rt.o"
    printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n' > "$SRC/zsh-fork.h"

    export CC="$CC -include $SRC/zsh-fork.h $SJLJ"
    export CPP="${CC%% -include*} -E"
    export CFLAGS="$CFLAGS -I$NC/usr/include -I$NC/usr/include/ncursesw -D_GNU_SOURCE"
    export CPPFLAGS="-I$NC/usr/include -I$NC/usr/include/ncursesw"
    # build-package's LDFLAGS already carry the guest memory ABI (imported
    # shared memory, which the fork copy relies on); zsh also needs 8 MB of
    # stack.
    export LDFLAGS="$LDFLAGS -L$NC/usr/lib -Wl,-z,stack-size=8388608"
    export LIBS="$SRC/wasm_fork.o $SRC/sjlj_rt.o -lncursesw $CRT1 -lc -lm $BUILTINS"

    # Answers for AC_TRY_RUN probes a cross build cannot execute.
    export zsh_cv_shared_environ=yes zsh_cv_sys_nis=no zsh_cv_sys_nis_plus=no
    export zsh_cv_sys_fifos_broken=no zsh_cv_sys_named_fds=yes zsh_cv_sys_path_dev_fd=/proc/self/fd
    export zsh_cv_sys_getpwnam_faked=no zsh_cv_sys_getpwuid_faked=no
    export zsh_cv_func_tgetent_accepts_null=yes zsh_cv_func_tgetent_zero_success=yes
    export zsh_cv_sys_elf=yes zsh_cv_sys_signals_use_sigaction=yes zsh_cv_c_variable_length_arrays=yes
    export ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes
    export ac_cv_func_mmap_fixed_mapped=no ac_cv_func_mbrtowc=yes ac_cv_func_wcwidth=yes
    export zsh_cv_sys_tcsetpgrp=yes
    # HAVE_POLL without HAVE_SELECT miscompiles zle (undefined symbol `cost`);
    # the kernel has both.
    export ac_cv_func_select=yes ac_cv_header_sys_select_h=yes

    ./configure --host=wasm32-unknown-linux-musl --prefix=/usr \
        --disable-dynamic --disable-restricted-r --enable-multibyte --disable-gdbm \
        > "$SRC/zsh-configure.log" 2>&1 \
        || { echo "zsh configure failed" >&2; tail -20 "$SRC/zsh-configure.log" >&2; exit 1; }
    make -j4 > "$SRC/zsh-make.log" 2>&1 \
        || { echo "zsh make failed" >&2; grep -E "error:|undefined symbol" "$SRC/zsh-make.log" | head >&2; exit 1; }

    mkdir -p "$STAGE/bin"
    install -m755 Src/zsh "$STAGE/bin/zsh"
}
