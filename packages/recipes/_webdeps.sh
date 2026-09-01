#!/bin/sh
# _webdeps.sh — shared helpers for the web-server recipes (nginx.sh, httpd.sh).
# Not a recipe. Sourced by recipes via: . "$RECIPES_DIR/_webdeps.sh"
#
# Everything builds through sysroot/lot-cc.sh, a cc wrapper that appends the
# wasm link line (LDFLAGS + shim objects + crt1/libc/builtins) to every link
# step. That is what lets stock autoconf/nginx configures probe and link
# without threading LIBS through every Makefile — and it is why libtool
# archives come out clean (no LIBS objects folded into the .a).
#
# Static deps land in one prefix, /tmp/lot-build/web-deps-prefix, and each
# builder is idempotent (skips when its artifact exists).

WEBDEPS_PREFIX=/tmp/lot-build/web-deps-prefix
WEBDEPS_OBJS=/tmp/lot-build/web-objs
WEBDEPS_BIN=/tmp/lot-build/web-bin
WEBDEPS_SRC=/tmp/lot-build/web-src

PCRE2_VER=10.44
EXPAT_VER=2.6.3
APR_VER=1.7.5
APRUTIL_VER=1.6.3

webdeps_env() {
    mkdir -p "$WEBDEPS_PREFIX" "$WEBDEPS_OBJS" "$WEBDEPS_BIN" "$WEBDEPS_SRC"
    export LOTCC="$REPO_ROOT/sysroot/lot-cc.sh"
    chmod +x "$LOTCC"
    export LOT_CLANG_BIN="$CLANG" LOT_SYSROOT_DIR="$SYSROOT" LOT_CRT1="$CRT1" LOT_BUILTINS="$BUILTINS"
    # 8 MB stack: wasm-ld's 64 KB default is the classic "mystery segfault"
    export LOT_LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608"
    # shims: asyncify fork thunk, MAP_ANON mmap over malloc, binary128 long double
    for f in wasm_fork wasm_mmap_anon wasm_ld128; do
        [ -f "$WEBDEPS_OBJS/$f.o" ] || $CC $CFLAGS -c "$REPO_ROOT/sysroot/$f.c" -o "$WEBDEPS_OBJS/$f.o"
    done
    export LOT_LINK_OBJS="$WEBDEPS_OBJS/wasm_fork.o $WEBDEPS_OBJS/wasm_mmap_anon.o $WEBDEPS_OBJS/wasm_ld128.o"
    # musl hides fork()/mmap() decls on wasm32; the shims provide the symbols
    printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n' > "$WEBDEPS_OBJS/fork-decls.h"
    export WEBDEPS_INC="-D_GNU_SOURCE -include $WEBDEPS_OBJS/fork-decls.h -include $REPO_ROOT/sysroot/wasm_mman.h"
    # macOS `ar` pads members and breaks wasm-ld ("section too large"): GNU-format llvm-ar
    printf '#!/bin/sh\nexec %s --format=gnu "$@"\n' "$AR" > "$WEBDEPS_BIN/ar"
    chmod +x "$WEBDEPS_BIN/ar"
    export WEBDEPS_AR="$WEBDEPS_BIN/ar"
    export PATH="$WEBDEPS_BIN:$PATH"
}

_webdeps_fetch() {  # url  → extracted dir under WEBDEPS_SRC (echoes path)
    _u="$1"; _f="/tmp/lot-src-$(basename "$_u")"
    [ -s "$_f" ] || curl -L --fail -o "$_f" "$_u"
    _d="$WEBDEPS_SRC/$(basename "$_u" .tar.gz)"
    rm -rf "$_d"; mkdir -p "$_d"
    tar xzf "$_f" -C "$_d" --strip-components=1
    echo "$_d"
}

webdeps_zlib() {
    [ -f /tmp/lot-build/zlib/stage/usr/lib/libz.a ] || {
        echo "==> zlib not staged — run: ./packages/build-package.sh zlib --dry-run --no-asyncify" >&2
        exit 1
    }
    export ZLIB_STAGE=/tmp/lot-build/zlib/stage/usr
}

webdeps_pcre2() {
    [ -f "$WEBDEPS_PREFIX/lib/libpcre2-8.a" ] && [ -x "$WEBDEPS_PREFIX/bin/pcre2-config" ] && return
    echo "==> webdeps: pcre2 $PCRE2_VER"
    _d=$(_webdeps_fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VER/pcre2-$PCRE2_VER.tar.gz")
    (cd "$_d" && ./configure --host=wasm32-unknown-linux-musl --prefix="$WEBDEPS_PREFIX" \
        --disable-shared --enable-static --disable-jit \
        --disable-pcre2grep-libz --disable-pcre2grep-libbz2 --disable-pcre2test-libreadline --disable-pcre2test-libedit \
        CC="$LOTCC" CFLAGS="$CFLAGS" AR="$WEBDEPS_AR" RANLIB="$RANLIB" > configure.log 2>&1 \
     && make -j8 libpcre2-8.la libpcre2-posix.la > make.log 2>&1 \
     && make install-libLTLIBRARIES install-nodist_includeHEADERS install-includeHEADERS install-binSCRIPTS > install.log 2>&1) \
     || { echo "pcre2 build failed — see $_d/*.log" >&2; exit 1; }
}

webdeps_expat() {
    [ -f "$WEBDEPS_PREFIX/lib/libexpat.a" ] && return
    echo "==> webdeps: expat $EXPAT_VER"
    _tag=$(echo "$EXPAT_VER" | tr . _)
    _d=$(_webdeps_fetch "https://github.com/libexpat/libexpat/releases/download/R_$_tag/expat-$EXPAT_VER.tar.gz")
    (cd "$_d" && ./configure --host=wasm32-unknown-linux-musl --prefix="$WEBDEPS_PREFIX" \
        --disable-shared --enable-static --without-xmlwf --without-examples --without-tests --without-docbook \
        CC="$LOTCC" CFLAGS="$CFLAGS" AR="$WEBDEPS_AR" RANLIB="$RANLIB" > configure.log 2>&1 \
     && make -j8 > make.log 2>&1 && make install > install.log 2>&1) \
     || { echo "expat build failed — see $_d/*.log" >&2; exit 1; }
}

# APR: threads ON (httpd.h needs apr_thread_mutex_t unconditionally; prefork
# never creates a thread), anonymous shm via MAP_ANON (the malloc shim — fine
# for one process), no sendfile (no Linux impl compiles for this target), and
# every AC_TRY_RUN answered for wasm32 ILP32 / 64-bit off_t.
webdeps_apr() {
    [ -f "$WEBDEPS_PREFIX/lib/libapr-1.a" ] && return
    echo "==> webdeps: apr $APR_VER"
    _d=$(_webdeps_fetch "https://archive.apache.org/dist/apr/apr-$APR_VER.tar.gz")
    _ptl=""; [ -f "$SYSROOT/lib/libpthread.a" ] && _ptl="-lpthread"
    (cd "$_d" && ./configure --host=wasm32-unknown-linux-musl --prefix="$WEBDEPS_PREFIX" \
        --disable-shared --enable-static --disable-dso --enable-threads \
        CC="$LOTCC" CFLAGS="$CFLAGS $WEBDEPS_INC" CPPFLAGS="$WEBDEPS_INC" AR="$WEBDEPS_AR" RANLIB="$RANLIB" \
        apr_cv_pthreads_cflags="-pthread" apr_cv_pthreads_lib="$_ptl" \
        ac_cv_pthread_attr_getdetachstate_one_arg=no ac_cv_pthread_getspecific_two_args=no \
        ac_cv_file__dev_zero=no ac_cv_func_shmget=no ac_cv_func_shm_open=no ac_cv_func_sem_open=no \
        ac_cv_func_mmap=yes ac_cv_func_munmap=yes ac_cv_func_fork=yes ac_cv_func_sendfile=no \
        ac_cv_func_setpgrp_void=yes apr_cv_process_shared_works=no apr_cv_mutex_robust_shared=no \
        apr_cv_tcp_nodelay_with_cork=yes ac_cv_struct_rlimit=yes ac_cv_o_nonblock_inherited=no \
        apr_cv_mutex_recursive=yes apr_cv_epoll=yes apr_cv_epoll_create1=yes apr_cv_dup3=yes \
        apr_cv_accept4=yes apr_cv_sock_cloexec=yes ac_cv_strerror_r_rc_int=yes apr_cv_use_lfs64=yes \
        apr_cv_gai_addrconfig=no ac_cv_negative_eai=yes apr_cv_type_rwlock_t=no \
        ac_cv_sizeof_off_t=8 ac_cv_sizeof_pid_t=4 ac_cv_sizeof_ssize_t=4 ac_cv_sizeof_size_t=4 \
        ac_cv_sizeof_long=4 ac_cv_sizeof_int=4 ac_cv_sizeof_short=2 ac_cv_sizeof_char=1 \
        ac_cv_sizeof_long_long=8 ac_cv_sizeof_voidp=4 ac_cv_sizeof_ino_t=8 ac_cv_sizeof_struct_iovec=8 \
        apr_cv_typematch_int64_t_int_d=no apr_cv_typematch_int64_t_long_ld=no apr_cv_typematch_int64_t_long_long_lld=yes \
        apr_cv_typematch_off_t_int_d=no apr_cv_typematch_off_t_long_ld=no apr_cv_typematch_off_t_long_long_lld=yes \
        apr_cv_typematch_size_t_unsigned_int_u=no apr_cv_typematch_size_t_unsigned_long_lu=yes \
        apr_cv_typematch_ssize_t_int_d=no apr_cv_typematch_ssize_t_long_ld=yes > configure.log 2>&1 \
     && make -j8 > make.log 2>&1 && make install > install.log 2>&1) \
     || { echo "apr build failed — see $_d/*.log" >&2; exit 1; }
    grep -q "define APR_HAS_THREADS  *1" "$WEBDEPS_PREFIX/include/apr-1/apr.h" || { echo "apr: threads not enabled?!" >&2; exit 1; }
}

webdeps_aprutil() {
    [ -f "$WEBDEPS_PREFIX/lib/libaprutil-1.a" ] && return
    echo "==> webdeps: apr-util $APRUTIL_VER"
    _d=$(_webdeps_fetch "https://archive.apache.org/dist/apr/apr-util-$APRUTIL_VER.tar.gz")
    (cd "$_d" && ./configure --host=wasm32-unknown-linux-musl --prefix="$WEBDEPS_PREFIX" \
        --disable-shared --enable-static --with-apr="$WEBDEPS_PREFIX" --with-expat="$WEBDEPS_PREFIX" \
        --without-crypto --without-sqlite3 --without-gdbm --without-ndbm --without-berkeley-db --without-ldap \
        CC="$LOTCC" CFLAGS="$CFLAGS $WEBDEPS_INC" CPPFLAGS="$WEBDEPS_INC" AR="$WEBDEPS_AR" RANLIB="$RANLIB" \
        ac_cv_func_fork=yes ac_cv_func_mmap=yes apu_cv_crypt_r_style=none > configure.log 2>&1 \
     && make -j8 > make.log 2>&1 && make install > install.log 2>&1) \
     || { echo "apr-util build failed — see $_d/*.log" >&2; exit 1; }
}

# install(1) on macOS has no -D: create the target directory first.
webdeps_install() {  # mode src dst
    mkdir -p "$(dirname "$3")"
    install -m "$1" "$2" "$3"
}

# Copy the shared demo site + stylesheet from the rootfs tree into a stage.
webdeps_demo_site() {  # stage-root  files...
    _st="$1"; shift
    mkdir -p "$_st/var/www/lot"
    for _f in "$@"; do cp -Rp "$REPO_ROOT/rootfs/var/www/lot/$_f" "$_st/var/www/lot/"; done
}
