#!/bin/sh
# Recipe: nginx — the web server, compiled to wasm32 for the guest.
#
#   nginx-demo                 serve /var/www/lot on :8080 (then: top bar → web view)
#   nginx -s stop
#
# Runs single-process (daemon off, master_process off in /etc/nginx/nginx.conf):
# every socket stays on this kernel's proven epoll path and no master/worker
# shared memory or accept mutex is needed. No sendfile (writev path), no TLS,
# no gzip; PCRE2 + zlib static from _webdeps.sh.
#
# Cross-compiling nginx: its configure COMPILES AND RUNS ~10 feature probes
# (epoll, sendfile, mmap, atomics, type sizes). wasm binaries can't run on the
# build host, so auto/feature is patched to consult an answer table and
# auto/types/sizeof gets the wasm32 ILP32 sizes. --crossbuild=Linux:6.1.0:wasm32
# keeps it from picking auto/os/darwin off the host's uname.

NAME="nginx"
VERSION="1.26.2"
DESCRIPTION="nginx web server — serves /var/www/lot with nginx-demo (web view, port 8080)"
SOURCE_URL="https://nginx.org/download/nginx-${VERSION}.tar.gz"
SOURCE_SHA256=""

build() {
    . "$RECIPES_DIR/_webdeps.sh"
    webdeps_env
    webdeps_zlib
    webdeps_pcre2

    cd "$SRC"

    # ── answers for the feature probes configure wants to execute ──────────
    cat > "$SRC/lot-run-test.sh" <<'EOF'
#!/bin/sh
# $1 = ngx_feature name. exit 0 = "found"; stdout is used for value tests.
case "$1" in
  "C compiler"|"gcc builtin atomic operations"|"C99 variadic macros"|"gcc variadic macros") exit 0 ;;
  "epoll") exit 0 ;;
  "mmap(MAP_ANON|MAP_SHARED)") exit 0 ;;              # sysroot/wasm_mmap_anon.c
  "sendfile()"|"sendfile64()") exit 1 ;;              # keep the writev path
  "prctl(PR_SET_DUMPABLE)"|"prctl(PR_SET_KEEPCAPS)") exit 1 ;;
  'mmap("/dev/zero", MAP_SHARED)'|"System V shared memory"|"POSIX semaphores") exit 1 ;;
  *) echo "lot-run-test: no answer for '$1' — assuming absent" >&2; exit 1 ;;
esac
EOF
    chmod +x "$SRC/lot-run-test.sh"
    sed -i.orig "s|if /bin/sh -c \$NGX_AUTOTEST >> \$NGX_AUTOCONF_ERR 2>&1; then|if $SRC/lot-run-test.sh \"\$ngx_feature\" >> \$NGX_AUTOCONF_ERR 2>\&1; then|" auto/feature
    sed -i.orig2 "s|ngx_feature_value=\`\$NGX_AUTOTEST\`|ngx_feature_value=\`$SRC/lot-run-test.sh \"\$ngx_feature\"\`|" auto/feature
    grep -q "lot-run-test" auto/feature || { echo "auto/feature patch failed" >&2; exit 1; }
    # wasm32: int/long/void*/size_t/sig_atomic_t = 4, long long/off_t/time_t = 8
    perl -0777 -i -pe 's|ngx_size=`\$NGX_AUTOTEST`|case "\$ngx_type" in int\|long\|"void *"\|size_t\|sig_atomic_t) ngx_size=4 ;; "long long"\|off_t\|time_t) ngx_size=8 ;; *) ngx_size=`\$NGX_AUTOTEST` ;; esac|' auto/types/sizeof
    grep -q 'ngx_size=4' auto/types/sizeof || { echo "auto/types/sizeof patch failed" >&2; exit 1; }

    ./configure --crossbuild=Linux:6.1.0:wasm32 \
        --prefix=/usr/local/nginx --sbin-path=/usr/local/bin/nginx \
        --conf-path=/etc/nginx/nginx.conf --pid-path=/var/run/nginx.pid \
        --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log \
        --with-cc="$LOTCC" \
        --with-cc-opt="$CFLAGS $WEBDEPS_INC -I$WEBDEPS_PREFIX/include -I$ZLIB_STAGE/include" \
        --with-ld-opt="-L$WEBDEPS_PREFIX/lib -L$ZLIB_STAGE/lib" \
        --with-http_stub_status_module \
        --without-http_gzip_module --without-http_ssi_module --without-http_userid_module \
        --without-http_geo_module --without-http_split_clients_module --without-http_referer_module \
        --without-http_fastcgi_module --without-http_uwsgi_module --without-http_scgi_module \
        --without-http_grpc_module --without-http_memcached_module \
        --without-http_upstream_hash_module --without-http_upstream_ip_hash_module \
        --without-http_upstream_least_conn_module --without-http_upstream_random_module \
        --without-http_upstream_keepalive_module --without-http_upstream_zone_module \
        --without-http_mirror_module \
        --without-mail_pop3_module --without-mail_imap_module --without-mail_smtp_module

    make -j8

    webdeps_install 755 objs/nginx "$STAGE/usr/local/bin/nginx"
    webdeps_install 755 "$REPO_ROOT/rootfs/usr/local/bin/nginx-demo" "$STAGE/usr/local/bin/nginx-demo"
    webdeps_install 644 "$REPO_ROOT/rootfs/etc/nginx/nginx.conf" "$STAGE/etc/nginx/nginx.conf"
    webdeps_install 644 conf/mime.types "$STAGE/etc/nginx/mime.types"
    mkdir -p "$STAGE/var/log/nginx" "$STAGE/usr/local/nginx"
    webdeps_demo_site "$STAGE" index.html lot.css
    rmdir "$STAGE/bin" 2>/dev/null || true
}
