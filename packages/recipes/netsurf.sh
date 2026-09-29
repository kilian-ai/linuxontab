#!/bin/sh
# Recipe: netsurf — the NetSurf 3.11 web browser on the guest's X server.
#
#   xtiny &                            # the X server (then: top bar → X display)
#   netsurf &                          # start page
#   netsurf https://news.ycombinator.com/ &
#
# NetSurf's framebuffer frontend on libnsfb's X (xcb) surface, with its
# built-in bitmap font. HTML/CSS layout, HTTPS (libcurl + OpenSSL 1.1.1w),
# PNG/JPEG/GIF/BMP/SVG, and JavaScript through NetSurf's Duktape engine:
# scripts run while a page loads (document.write, building the DOM before
# layout), and event handlers, timers, form-field and title updates work.
# Like upstream NetSurf 3.11, other DOM changes made after the page has
# been laid out are not re-rendered, so script-driven single-page apps
# still don't work. The default search (address bar and start page) is
# DuckDuckGo's lite endpoint. To turn scripts off, put
# "enable_javascript:0" in /usr/local/share/netsurf/Choices.
#
# Everything is cross-built here: NetSurf's own libraries come from the
# netsurf-all bundle; the rest (OpenSSL, libcurl, libpng, libjpeg, expat,
# xcb-util×4) is built once into $DEPS and reused (stamp per library).
# Our libxcb/libXau/zlib/xorgproto packages seed that prefix.
#
# Host prerequisites (macOS): Homebrew bison >= 3 (libnslog's grammar and
# nsgenbind), flex (Xcode's is fine) and libpng (NetSurf's build-time image
# converter runs on the host).
#
# Source patches: packages/patches/netsurf-3.11-lot.patch
#   - libnsfb X surface: check MIT-SHM is present before querying it (xcb
#     closes the connection on a request for a missing extension); send
#     image puts in bands under the server's max request length (xcb does
#     not split, a full 760x500 frame is 1.5 MB); name the window NetSurf;
#     follow window resizes (ConfigureNotify -> NSFB_EVENT_RESIZE, and
#     x_set_geometry reallocates the image and pixmap after start-up), so
#     maximising the window in xtiny re-lays out the browser
#   - utils/config.h: no mmap on wasm (NetSurf's read() path)
#   - default search provider and start-page form: DuckDuckGo lite
#   - framebuffer frontend: JavaScript on by default (the core default is
#     off even when Duktape is built in)
# Build-level fixes are commented where they happen below.

NAME="netsurf"
VERSION="3.11-r2"   # r1: follows window resizes (maximise); r2: JavaScript (Duktape)
DESCRIPTION="NetSurf 3.11 web browser on the X desktop — HTML/CSS, HTTPS, PNG/JPEG/GIF/SVG, basic JavaScript (run xtiny first)"
SOURCE_URL="https://download.netsurf-browser.org/netsurf/releases/source-full/netsurf-all-3.11.tar.gz"
SOURCE_SHA256="4dea880ff3c2f698bfd62c982b259340f9abcd7f67e6c8eb2b32c61f71644b7b"
DEPENDS="xtiny"

build() {
    BISON_DIR=/opt/homebrew/opt/bison/bin
    HOST_PNG=/opt/homebrew/opt/libpng
    [ -x "$BISON_DIR/bison" ] || { echo "netsurf: need Homebrew bison >= 3 ($BISON_DIR)" >&2; exit 1; }
    [ -f "$HOST_PNG/include/png.h" ] || { echo "netsurf: need Homebrew libpng ($HOST_PNG) for the host image tool" >&2; exit 1; }
    export PATH="$BISON_DIR:$PATH"

    DEPS=/tmp/lot-build/netsurf-deps
    NSP="$SRC/inst"                       # NetSurf's own libraries (fresh per build)
    mkdir -p "$DEPS/lib/pkgconfig" "$DEPS/include" "$NSP"
    export PKG_CONFIG_LIBDIR="$NSP/lib/pkgconfig:$DEPS/lib/pkgconfig"
    export PKG_CONFIG_PATH=
    LINKRT="$CRT1 -lc -lm $BUILTINS"

    fetch() {   # file url sha256
        [ -f "/tmp/lot-src-$1" ] || curl -sL --fail -o "/tmp/lot-src-$1" "$2" || { echo "download failed: $2" >&2; exit 1; }
        [ "$(shasum -a 256 "/tmp/lot-src-$1" | cut -d' ' -f1)" = "$3" ] || { echo "checksum mismatch: $1" >&2; exit 1; }
    }
    unpack() {  # file dir
        rm -rf "$2" && mkdir -p "$2" && tar xf "/tmp/lot-src-$1" -C "$2" --strip-components=1
    }
    # Static linking needs no .la files, and our packages' .la point at the
    # guest's /usr/lib — libtool then fails on them.
    drop_la() { find "$DEPS/lib" -name "*.la" -delete; }
    # .pc files from our package builds carry the C runtime (crt1, -lc,
    # builtins) in their link lines; NetSurf links libnsfb's deps with
    # --whole-archive, which then force-links libc twice.
    clean_pc() {
        for pc in "$DEPS"/lib/pkgconfig/*.pc; do
            sed -i '' -E "s#^prefix=/usr\$#prefix=$DEPS#" "$pc"
            sed -i '' -E "/^Libs(\.private)?:/ { s#[^ ]*crt1\.o##g; s#[^ ]*libclang_rt\.builtins\.a##g; s#(^|[ ])-lc( |\$)#\1\2#g; s#(^|[ ])-lm( |\$)#\1\2#g; }" "$pc"
        done
    }
    # macOS ar pads wasm members ("section too large"): archives are always
    # rebuilt from the objects with llvm-ar.
    rearchive() { rm -f "$1"; shift; "$AR" crs "$@"; }

    # ── seed from our packages ────────────────────────────────────────────
    if [ ! -f "$DEPS/.seeded" ]; then
        for p in zlib libxcb libXau libXdmcp xorgproto; do
            t=$(ls "$REPO_ROOT"/packages/$p-*.tar.gz | head -1); T=$(mktemp -d)
            tar xzf "$t" -C "$T" && cp -R "$T/pkg-$p/usr/." "$DEPS/"; rm -rf "$T"
        done
        # libxcb's .pc leaves xcbproto_version empty (xcb-util's configure
        # requires >= 1.6); libxcb 1.17.0 is built against xcb-proto 1.17.
        sed -i '' -E "s#^xcbproto_version=.*#xcbproto_version=1.17.0#" "$DEPS/lib/pkgconfig/xcb.pc"
        # xorgproto shipped headers but no .pc; xau.pc requires xproto.
        printf 'prefix=%s\nincludedir=${prefix}/include\nName: Xproto\nDescription: X11 core protocol headers\nVersion: 7.0.33\nCflags: -I${includedir}\n' "$DEPS" > "$DEPS/lib/pkgconfig/xproto.pc"
        printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\nName: zlib\nDescription: zlib\nVersion: 1.3.2\nLibs: -L${libdir} -lz\nCflags: -I${includedir}\n' "$DEPS" > "$DEPS/lib/pkgconfig/zlib.pc"
        # musl has iconv in libc; NetSurf's link still asks for -liconv.
        echo "int lot_iconv_is_in_libc;" > "$SRC/iconv.c" && $CC $CFLAGS -c "$SRC/iconv.c" -o "$SRC/iconv.o"
        rearchive "$DEPS/lib/libiconv.a" "$DEPS/lib/libiconv.a" "$SRC/iconv.o"
        drop_la; clean_pc; touch "$DEPS/.seeded"
    fi

    # ── OpenSSL 1.1.1w (python3.sh's proven wasm32 configuration) ─────────
    if [ ! -f "$DEPS/.openssl" ]; then
        fetch openssl-1.1.1w.tar.gz https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8
        unpack openssl-1.1.1w.tar.gz "$SRC/dep-openssl"; ( cd "$SRC/dep-openssl"
        CC="$CC" AR="$AR" RANLIB="$RANLIB" ./Configure linux-generic32 no-asm no-shared no-dso no-engine \
            no-async no-tests no-ui-console -DOPENSSL_NO_SECURE_MEMORY \
            no-bf no-cast no-idea no-rc2 no-rc4 no-rc5 no-md2 no-md4 no-mdc2 \
            no-seed no-camellia no-whirlpool no-blake2 \
            -DOPENSSL_DEV_NO_ATOMICS -D__STDC_NO_ATOMICS__=1 --prefix="$DEPS" $CFLAGS > configure.log 2>&1 \
          && make -j8 build_libs > make.log 2>&1 ) || { echo "openssl build failed" >&2; exit 1; }
        cp "$SRC"/dep-openssl/libssl.a "$SRC"/dep-openssl/libcrypto.a "$DEPS/lib/"
        cp -R "$SRC/dep-openssl/include/openssl" "$DEPS/include/"
        for m in libssl libcrypto openssl; do sed "s#^prefix=.*#prefix=$DEPS#" "$SRC/dep-openssl/$m.pc" > "$DEPS/lib/pkgconfig/$m.pc"; done
        touch "$DEPS/.openssl"
    fi

    # ── libcurl 8.13.0 with OpenSSL (the curl package is HTTP-only) ───────
    if [ ! -f "$DEPS/.curl" ]; then
        fetch curl-8.13.0.tar.gz https://curl.se/download/curl-8.13.0.tar.gz c261a4db579b289a7501565497658bbd52d3138fdbaccf1490fa918129ab45bc
        unpack curl-8.13.0.tar.gz "$SRC/dep-curl"; ( cd "$SRC/dep-curl"
        ./configure --host=wasm32-unknown-linux-musl --prefix="$DEPS" --enable-static --disable-shared \
            --with-openssl="$DEPS" --with-zlib="$DEPS" --with-ca-bundle=/etc/ssl/cert.pem \
            --without-libpsl --without-libidn2 --without-librtmp --without-brotli --without-zstd \
            --without-nghttp2 --without-nghttp3 --disable-unix-sockets --disable-socketpair \
            --disable-threaded-resolver --disable-ipv6 --disable-docs --disable-manual --disable-ldap --disable-ldaps \
            CC="$CC" CFLAGS="$CFLAGS -D_GNU_SOURCE" CPPFLAGS="-I$DEPS/include" LDFLAGS="$LDFLAGS -L$DEPS/lib" \
            LIBS="-lssl -lcrypto -lz $LINKRT" > configure.log 2>&1 \
          && make -j8 -C lib > make.log 2>&1 && make -C include install > /dev/null 2>&1 ) || { echo "libcurl build failed" >&2; exit 1; }
        rearchive "$DEPS/lib/libcurl.a" "$DEPS/lib/libcurl.a" $(find "$SRC/dep-curl/lib" -name "libcurl_la-*.o" ! -path "*/.libs/*" | sort)
        sed -E "s#^prefix=.*#prefix=$DEPS#" "$SRC/dep-curl/libcurl.pc" > "$DEPS/lib/pkgconfig/libcurl.pc"
        touch "$DEPS/.curl"
    fi

    # ── libpng 1.6.44 / IJG libjpeg 9f ─────────────────────────────────────
    if [ ! -f "$DEPS/.png" ]; then
        fetch libpng-1.6.44.tar.gz https://download.sourceforge.net/libpng/libpng-1.6.44.tar.gz 8c25a7792099a0089fa1cc76c94260d0bb3f1ec52b93671b572f8bb61577b732
        unpack libpng-1.6.44.tar.gz "$SRC/dep-png"; ( cd "$SRC/dep-png"
        ./configure --host=wasm32-unknown-linux-musl --prefix="$DEPS" --enable-static --disable-shared --disable-tools --disable-tests \
            CC="$CC" CFLAGS="$CFLAGS" CPPFLAGS="-I$DEPS/include" LDFLAGS="$LDFLAGS -L$DEPS/lib" LIBS="-lz $LINKRT" > configure.log 2>&1 \
          && make -j8 libpng16.la libpng16.pc > make.log 2>&1 ) || { echo "libpng build failed" >&2; exit 1; }
        # the library objects sit next to the sources, not in .libs/
        ( cd "$SRC/dep-png" && rearchive "$DEPS/lib/libpng16.a" "$DEPS/lib/libpng16.a" \
            $(ls png*.o | grep -vE '^(pngtest|pngfix|pngimage|pngstest|pngcp|pngunknown|pngvalid|timepng|makepng)\.o$') )
        ln -sf libpng16.a "$DEPS/lib/libpng.a"
        cp "$SRC"/dep-png/png.h "$SRC"/dep-png/pngconf.h "$SRC"/dep-png/pnglibconf.h "$DEPS/include/"
        sed -E "s#^prefix=.*#prefix=$DEPS#; s#^Libs\.private:.*#Libs.private: -lz -lm#" "$SRC/dep-png/libpng16.pc" > "$DEPS/lib/pkgconfig/libpng16.pc"
        cp "$DEPS/lib/pkgconfig/libpng16.pc" "$DEPS/lib/pkgconfig/libpng.pc"
        touch "$DEPS/.png"
    fi
    if [ ! -f "$DEPS/.jpeg" ]; then
        fetch jpegsrc.v9f.tar.gz https://www.ijg.org/files/jpegsrc.v9f.tar.gz 04705c110cb2469caa79fb71fba3d7bf834914706e9641a4589485c1f832565b
        unpack jpegsrc.v9f.tar.gz "$SRC/dep-jpeg"; ( cd "$SRC/dep-jpeg"
        ./configure --host=wasm32-unknown-linux-musl --prefix="$DEPS" --enable-static --disable-shared \
            CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" LIBS="$LINKRT" > configure.log 2>&1 \
          && make -j8 libjpeg.la > make.log 2>&1 ) || { echo "libjpeg build failed" >&2; exit 1; }
        ( cd "$SRC/dep-jpeg" && rearchive "$DEPS/lib/libjpeg.a" "$DEPS/lib/libjpeg.a" $(find . -maxdepth 1 -name "*.o" | sort) )
        cp "$SRC"/dep-jpeg/jpeglib.h "$SRC"/dep-jpeg/jconfig.h "$SRC"/dep-jpeg/jmorecfg.h "$SRC"/dep-jpeg/jerror.h "$DEPS/include/"
        printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\nName: libjpeg\nDescription: IJG JPEG library 9f\nVersion: 9.6.0\nLibs: -L${libdir} -ljpeg\nCflags: -I${includedir}\n' "$DEPS" > "$DEPS/lib/pkgconfig/libjpeg.pc"
        touch "$DEPS/.jpeg"
    fi

    # ── expat 2.6.4 (libdom's XML binding) ────────────────────────────────
    if [ ! -f "$DEPS/.expat" ]; then
        fetch expat-2.6.4.tar.xz https://github.com/libexpat/libexpat/releases/download/R_2_6_4/expat-2.6.4.tar.xz a695629dae047055b37d50a0ff4776d1d45d0a4c842cf4ccee158441f55ff7ee
        unpack expat-2.6.4.tar.xz "$SRC/dep-expat"; ( cd "$SRC/dep-expat"
        ./configure --host=wasm32-unknown-linux-musl --prefix="$DEPS" --enable-static --disable-shared \
            --without-xmlwf --without-examples --without-tests --without-docbook --without-getrandom --without-sys-getrandom \
            CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" LIBS="$LINKRT" > configure.log 2>&1 \
          && { make -k -j8 -C lib > make.log 2>&1 || true; } ) || { echo "expat configure failed" >&2; exit 1; }
        rearchive "$DEPS/lib/libexpat.a" "$DEPS/lib/libexpat.a" $(find "$SRC/dep-expat/lib" -name "*.o" ! -path "*/.libs/*" | sort)
        cp "$SRC"/dep-expat/lib/expat.h "$SRC"/dep-expat/lib/expat_external.h "$DEPS/include/"
        sed -E "s#^prefix=.*#prefix=$DEPS#; s#^Libs\.private:.*#Libs.private: -lm#" "$SRC/dep-expat/expat.pc" > "$DEPS/lib/pkgconfig/expat.pc"
        touch "$DEPS/.expat"
    fi

    # ── xcb-util, -image, -keysyms, -wm (libnsfb's X surface) ─────────────
    for spec in xcb-util:0.4.1:5abe3bbbd8e54f0fa3ec945291b7e8fa8cfd3cccc43718f8758430f94126e512 \
                xcb-util-image:0.4.1:ccad8ee5dadb1271fd4727ad14d9bd77a64e505608766c4e98267d9aede40d3d \
                xcb-util-keysyms:0.4.1:7c260a5294412aed429df1da2f8afd3bd07b7cba3fec772fba15a613a6d5c638 \
                xcb-util-wm:0.4.2:62c34e21d06264687faea7edbf63632c9f04d55e72114aa4a57bb95e4f888a0b; do
        n=${spec%%:*}; rest=${spec#*:}; v=${rest%%:*}; sha=${rest#*:}
        [ -f "$DEPS/.$n" ] && continue
        fetch "$n-$v.tar.xz" "https://xorg.freedesktop.org/archive/individual/lib/$n-$v.tar.xz" "$sha"
        unpack "$n-$v.tar.xz" "$SRC/dep-$n"; ( cd "$SRC/dep-$n"
        ./configure --host=wasm32-unknown-linux-musl --prefix="$DEPS" --enable-static --disable-shared \
            CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" LIBS="$LINKRT" > configure.log 2>&1 ) || { echo "$n configure failed" >&2; exit 1; }
        # -k: the test programs fail to link and don't matter; the library
        # is repacked from its objects below.
        ( cd "$SRC/dep-$n" && { make -k -j8 > make.log 2>&1; make -k install > install.log 2>&1; } ) || true
        for a in $(cd "$SRC/dep-$n" && find . -name "*.a" -path "*/.libs/*"); do
            objdir="$SRC/dep-$n/$(dirname "$(dirname "$a")")"
            objs=$(find "$objdir" -maxdepth 1 -name "*.o" | sort); [ -n "$objs" ] || objs=$(find "$objdir/.libs" -maxdepth 1 -name "*.o" | sort)
            rearchive "$DEPS/lib/$(basename "$a")" "$DEPS/lib/$(basename "$a")" $objs
        done
        drop_la; clean_pc; touch "$DEPS/.$n"
    done
    drop_la; clean_pc

    # ── NetSurf's own libraries, then the browser ─────────────────────────
    patch -p1 < "$REPO_ROOT/packages/patches/netsurf-3.11-lot.patch" || { echo "netsurf patch failed" >&2; exit 1; }
    BUILD=$(cc -dumpmachine)
    # libdom finds expat.h without pkg-config
    export CFLAGS="$CFLAGS -D_GNU_SOURCE -I$DEPS/include"
    for L in buildsystem libnslog libwapcaplet libparserutils libcss libhubbub libdom libnsbmp libnsgif libnsutils libutf8proc libnspsl libsvgtiny libnsfb; do
        # CFLAGS travels in the environment: on the command line it would
        # override the Makefiles' own include paths.
        make -C "$SRC/$L" install HOST=wasm32-unknown-linux-musl BUILD="$BUILD" PREFIX="$NSP" NSSHARED="$SRC/buildsystem" \
            CC="$CC" AR="$AR" BUILD_CC=cc COMPONENT_TYPE=lib-static Q= WARNFLAGS="-Wall -W -Wno-error" > "$SRC/nslib-$L.log" 2>&1 \
            || { echo "netsurf: $L failed" >&2; grep -E "error" "$SRC/nslib-$L.log" | head -5 >&2; exit 1; }
    done

    # nsgenbind generates the Duktape bindings from WebIDL at build time, so
    # it is a host tool: native compiler, none of the wasm CFLAGS/LDFLAGS.
    env CFLAGS= LDFLAGS= make -C "$SRC/nsgenbind" install PREFIX="$SRC/hosttools" \
        NSSHARED="$SRC/buildsystem" HOST="$BUILD" BUILD="$BUILD" CC=cc Q= > "$SRC/nsgenbind.log" 2>&1 \
        || { echo "netsurf: nsgenbind (host tool) failed" >&2; tail -5 "$SRC/nsgenbind.log" >&2; exit 1; }
    export PATH="$SRC/hosttools/bin:$PATH"

    SHIMS="$SRC/shims"; mkdir -p "$SHIMS"
    for f in wasm_dlmalloc wasm_ld128; do $CC $CFLAGS -c "$REPO_ROOT/sysroot/$f.c" -o "$SHIMS/$f.o"; done
    # libpng reports errors by longjmp through the function NetSurf's png.c
    # registers; a plain wasm32 longjmp is a trapping stub. The sjlj pass
    # rewrites every use of longjmp (address-taken too) in what it compiles.
    SJLJ="-mexception-handling -mllvm -wasm-enable-sjlj"
    $CC $CFLAGS $SJLJ -c "$REPO_ROOT/sysroot/sjlj_rt_wasmeh.c" -o "$SHIMS/sjlj_rt.o"
    export CFLAGS="$CFLAGS $SJLJ"
    # Link flags in the environment so NetSurf appends its libraries; wasm-ld
    # resolves archives regardless of order. dlmalloc: page and image
    # buffers pass 128 KB, where musl mallocng needs mmap and traps. -lXau:
    # NetSurf asks pkg-config for non-static flags, which omit xcb's.
    export LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608 $SHIMS/wasm_dlmalloc.o $SHIMS/wasm_ld128.o $SHIMS/sjlj_rt.o -L$DEPS/lib -lXau $LINKRT"
    make -C "$SRC/netsurf" TARGET=framebuffer HOST=wasm32-unknown-linux-musl BUILD="$BUILD" PREFIX="$NSP" \
        NSSHARED="$SRC/buildsystem" CC="$CC" AR="$AR" Q= WARNFLAGS="-Wall -W -Wno-error" \
        BUILD_CC="cc -I$HOST_PNG/include -L$HOST_PNG/lib" \
        NETSURF_FB_FRONTEND=x NETSURF_FB_FONTLIB=internal NETSURF_USE_DUKTAPE=YES \
        NETSURF_USE_JPEG=YES NETSURF_USE_PNG=YES NETSURF_USE_NSSVG=YES NETSURF_USE_WEBP=NO NETSURF_USE_JPEGXL=NO \
        NETSURF_USE_ROSPRITE=NO NETSURF_USE_LIBICONV_PLUG=NO NETSURF_USE_OPENSSL=YES NETSURF_USE_VIDEO=NO \
        NETSURF_FB_RESPATH=/usr/local/share/netsurf > "$SRC/netsurf-make.log" 2>&1 \
        || { echo "netsurf build failed" >&2; grep -E "error:|undefined symbol" "$SRC/netsurf-make.log" | head -8 >&2; exit 1; }

    mkdir -p "$STAGE/usr/local/libexec" "$STAGE/usr/local/bin" "$STAGE/usr/local/share/netsurf"
    install -m755 "$SRC/netsurf/nsfb" "$STAGE/usr/local/libexec/nsfb"
    for f in Messages adblock.css credits.html default.css favicon.png internal.css licence.html netsurf.png quirks.css welcome.html; do
        cp -L "$SRC/netsurf/frontends/framebuffer/res/$f" "$STAGE/usr/local/share/netsurf/$f"
    done
    cat > "$STAGE/usr/local/bin/netsurf" <<'LAUNCHER'
#!/bin/sh
# NetSurf web browser on the X server. Needs an X server: run `xtiny &` first.
#   netsurf                 # start page
#   netsurf https://news.ycombinator.com/
: "${DISPLAY:=:1}"; export DISPLAY
mkdir -p "${HOME:-/root}/.netsurf" 2>/dev/null
# 760x500 fits xtiny's 800x600 desktop with the window frame and taskbar.
# stdin from /dev/null: an X client left holding the console busy-reads it.
exec /usr/local/libexec/nsfb -f x -b 32 -w 760 -h 500 "$@" </dev/null
LAUNCHER
    chmod 755 "$STAGE/usr/local/bin/netsurf"
    rmdir "$STAGE/bin" 2>/dev/null || true
}
