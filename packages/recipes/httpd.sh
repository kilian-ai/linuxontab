#!/bin/sh
# Recipe: httpd — Apache HTTP Server 2.4, compiled to wasm32 for the guest.
#
#   httpd-demo                 serve /var/www/lot on :8081 (then: top bar → web view)
#   httpd -k stop
#
# Runs as `httpd -X`: prefork MPM, ONE process, no children. The scoreboard
# and mutexes live in anonymous memory via the MAP_ANON malloc shim
# (sysroot/wasm_mmap_anon.c) — correct for one process, not shared across
# forks, which is why the launcher never runs a real prefork pool.
#
# Static everything: APR (threads on — httpd.h uses apr_thread_mutex_t
# unconditionally — no sendfile, no DSO), apr-util (expat only), PCRE2.
# Modules are compiled in (--enable-modules=none + an explicit static list);
# no mod_so because there is no dlopen on wasm32.
#
# Cross-compile notes: APR's configure has ~40 AC_TRY_RUN probes, answered in
# _webdeps.sh for wasm32 (ILP32, 64-bit off_t/time_t). httpd's own
# gen_test_char must RUN at build time to emit server/test_char.h, so its
# Makefile rule is rewritten to build it with the host cc.

NAME="httpd"
VERSION="2.4.62"
DESCRIPTION="Apache httpd 2.4 web server — serves /var/www/lot with httpd-demo (web view, port 8081)"
SOURCE_URL="https://archive.apache.org/dist/httpd/httpd-${VERSION}.tar.gz"
SOURCE_SHA256=""

build() {
    . "$RECIPES_DIR/_webdeps.sh"
    webdeps_env
    webdeps_pcre2
    webdeps_expat
    webdeps_apr
    webdeps_aprutil

    cd "$SRC"

    # This kernel has no setuid() (ENOSYS; setgid works). mod_unixd treats a
    # failed privilege drop as fatal, so the -X process died at startup with
    # "AH02162: setuid: unable to change to uid: 65534". Everything in a
    # browser tab is root anyway: tolerate ENOSYS and stay as we are.
    perl -0777 -i -pe 's/setgid\(ap_unixd_config\.group_id\) == -1\)/(setgid(ap_unixd_config.group_id) == -1 \&\& errno != ENOSYS))/; s/initgroups\(name, ap_unixd_config\.group_id\) == -1\)/(initgroups(name, ap_unixd_config.group_id) == -1 \&\& errno != ENOSYS))/; s/setuid\(ap_unixd_config\.user_id\) == -1\)\)/(setuid(ap_unixd_config.user_id) == -1 \&\& errno != ENOSYS)))/g' modules/arch/unix/mod_unixd.c
    [ "$(grep -c 'errno != ENOSYS' modules/arch/unix/mod_unixd.c)" = 4 ] || { echo "mod_unixd.c ENOSYS patch failed" >&2; exit 1; }

    ./configure --host=wasm32-unknown-linux-musl \
        --prefix=/usr/local/apache2 --sbindir=/usr/local/bin --sysconfdir=/etc/httpd \
        --with-apr="$WEBDEPS_PREFIX" --with-apr-util="$WEBDEPS_PREFIX" \
        --with-pcre="$WEBDEPS_PREFIX/bin/pcre2-config" \
        --with-mpm=prefork --enable-mpms-shared=no --disable-shared \
        --enable-modules=none \
        --enable-mods-static="authz_core authz_host authn_core access_compat mime log_config dir alias autoindex status info unixd headers env setenvif filter" \
        CC="$LOTCC" CFLAGS="$CFLAGS $WEBDEPS_INC" CPPFLAGS="$WEBDEPS_INC" AR="$WEBDEPS_AR" RANLIB="$RANLIB" \
        ap_cv_void_ptr_lt_long=no ac_cv_func_fork=yes ac_cv_func_mmap=yes ac_cv_func_munmap=yes

    # gen_test_char runs on the build host
    perl -0777 -i -pe 's|gen_test_char: \$\(gen_test_char_OBJECTS\)\n\t\$\(LINK\) \$\(EXTRA_LDFLAGS\) \$\(gen_test_char_OBJECTS\) \$\(EXTRA_LIBS\)|gen_test_char: gen_test_char.c\n\tcc \$(INCLUDES) \$(EXTRA_INCLUDES) -I'"$WEBDEPS_PREFIX"'/include/apr-1 -o gen_test_char gen_test_char.c|' server/Makefile
    grep -q "gen_test_char: gen_test_char.c" server/Makefile || { echo "gen_test_char patch failed" >&2; exit 1; }

    make -j8

    webdeps_install 755 httpd "$STAGE/usr/local/bin/httpd"
    webdeps_install 755 "$REPO_ROOT/rootfs/usr/local/bin/httpd-demo" "$STAGE/usr/local/bin/httpd-demo"
    webdeps_install 644 "$REPO_ROOT/rootfs/etc/httpd/httpd.conf" "$STAGE/etc/httpd/httpd.conf"
    webdeps_install 644 docs/conf/mime.types "$STAGE/etc/httpd/mime.types"
    mkdir -p "$STAGE/var/log/httpd" "$STAGE/usr/local/apache2"
    webdeps_demo_site "$STAGE" apache.html lot.css files
    rmdir "$STAGE/bin" 2>/dev/null || true
}
