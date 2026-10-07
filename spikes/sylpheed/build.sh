#!/bin/sh
# Sylpheed (GTK 2 mail client) and the GTK 2 stack for the wasm guest, in the
# LibreOffice build container (wasm-cc driver, cpp-eh-sysroot, wasm-ld 20) with
# the native GLib/GTK tools added (spikes/sylpheed/Dockerfile):
#   ffi glib fribidi harfbuzz pixman cairo pango atk gdkpixbuf gtk openssl sylpheed
#   sh /lot/syl/build.sh [step...]          (default: all, in order)
# Reuses the Xfe build's zlib/libpng/freetype/expat/fontconfig (/work/fm/prefix)
# and the guest's X11 client libraries (/work/xprefix, from xfe's prep step).
# Mounts: /lot/toolchain /lot/sysroot /lot/spike (= spikes/libreoffice)
# /lot/syl (= spikes/sylpheed) /lot/packages (ro); /work = the lo-work volume.
set -eu
S=/work/gtk/src; B=/work/gtk/build; P=/work/gtk/prefix
FM=/work/fm/prefix; X=/work/xprefix
mkdir -p $S $B $P/lib/pkgconfig
export CC=/lot/spike/bin/wasm-cc CXX=/lot/spike/bin/wasm-c++
export AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm STRIP=llvm-strip OBJDUMP=llvm-objdump
XPC=/work/gtk/xpc   # sanitized copies of $X/lib/pkgconfig (see prep)
export PKG_CONFIG_LIBDIR=$P/lib/pkgconfig:$P/share/pkgconfig:$FM/lib/pkgconfig:$XPC
export PKG_CONFIG_PATH=
export CFLAGS="-O2" CXXFLAGS="-O2"
export CPPFLAGS="-include /lot/spike/xfe/wasm_fork_decl.h -I$P/include -I$FM/include -I$FM/include/freetype2"
export LDFLAGS="-L$P/lib -L$FM/lib -L$X/lib"
export CC_FOR_BUILD=gcc CC_BUILD=gcc CXX_FOR_BUILD=g++
HOST="--host=wasm32-unknown-linux-musl --build=aarch64-unknown-linux-gnu"
XDIRS="--x-includes=$X/include --x-libraries=$X/lib"
CROSS=/work/gtk/cross.ini
J=-j8

fetch() { [ -f "$S/$2" ] || curl -sfL -o "$S/$2" "$1$2"; }
unpack() { rm -rf $B/$1; mkdir -p $B/$1; tar xf $S/$2 -C $B/$1 --strip-components=1; cd $B/$1; }
mesonbuild() {   # mesonbuild <dir> <meson options...>; WRAP=default allows subprojects
  d=$1; shift
  meson setup _b --cross-file=$CROSS --prefix=$P --libdir=lib --buildtype=release \
      --default-library=static --wrap-mode=${WRAP:-nofallback} "$@"
  ninja -C _b $J
  # post-install scripts may try to run cross-built tools: report, don't fail
  meson install -C _b --no-rebuild 2>&1 | tail -5 || true
}

prep() {
  # The X packages' .pc files carry the build host's link tail in Libs.private
  # (/Users/.../crt1.o -lc -lm .../libclang_rt.builtins.a): with static
  # pkg-config every link probe failed. Use cleaned copies.
  rm -rf $XPC && mkdir -p $XPC
  for f in $X/lib/pkgconfig/*.pc; do
    sed -E 's#(/Users|/private)[^ ]*##g; s#(^Libs.private:.*) -lc( |$)#\1\2#; s#(^Libs.private:.*) -lm( |$)#\1\2#' "$f" > $XPC/$(basename "$f")
  done
  grep -l "Users" $XPC/*.pc && { echo "host paths left in X .pc files"; return 1; }
  mkdir -p $S && cd $S
  fetch https://download.gnome.org/sources/glib/2.84/ glib-2.84.4.tar.xz
  fetch https://github.com/fribidi/fribidi/releases/download/v1.0.17/ fribidi-1.0.17.tar.xz
  fetch https://github.com/harfbuzz/harfbuzz/releases/download/11.4.5/ harfbuzz-11.4.5.tar.xz
  fetch https://cairographics.org/releases/ pixman-0.46.4.tar.gz
  fetch https://cairographics.org/releases/ cairo-1.18.6.tar.xz
  fetch https://download.gnome.org/sources/pango/1.56/ pango-1.56.4.tar.xz
  fetch https://download.gnome.org/sources/atk/2.38/ atk-2.38.0.tar.xz
  fetch https://download.gnome.org/sources/gdk-pixbuf/2.42/ gdk-pixbuf-2.42.12.tar.xz
  fetch https://download.gnome.org/sources/gtk+/2.24/ gtk+-2.24.33.tar.xz
  fetch https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/ openssl-1.1.1w.tar.gz
  fetch https://sylpheed.sraoss.jp/sylpheed/v3.7/ sylpheed-3.7.0.tar.xz
  ls -la
  # meson: wasm32 "Linux"; answers for the checks that would run a program
  cat > $CROSS <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$P/lib/pkgconfig', '$P/share/pkgconfig', '$FM/lib/pkgconfig', '$XPC']
growing_stack = false
have_c99_vsnprintf = true
have_c99_snprintf = true
have_unix98_printf = true
va_val_copy = true

[built-in options]
# static archives only: pkg-config --static, so transitive deps (fontconfig -> expat) link
prefer_static = true
c_args = ['-O2', '-include', '/lot/spike/xfe/wasm_fork_decl.h', '-I$P/include', '-I$FM/include', '-I$FM/include/freetype2']
cpp_args = ['-O2', '-include', '/lot/spike/xfe/wasm_fork_decl.h', '-I$P/include', '-I$FM/include', '-I$FM/include/freetype2']
c_link_args = ['-L$P/lib', '-L$FM/lib', '-L$X/lib']
cpp_link_args = ['-L$P/lib', '-L$FM/lib', '-L$X/lib']
EOF
}

ffi() {
  # libffi has no wasm32 port outside emscripten: GObject's generic marshaller
  # only needs ffi_call, generated as a signature dispatch (ffi/gen-dispatch.py)
  mkdir -p $B/ffi && cd $B/ffi
  python3 /lot/syl/ffi/gen-dispatch.py > ffi_wasm.c
  $CC -O2 -I/lot/syl/ffi -c ffi_wasm.c -o ffi_wasm.o
  rm -f $P/lib/libffi.a && $AR rcs $P/lib/libffi.a ffi_wasm.o
  mkdir -p $P/include && cp /lot/syl/ffi/ffi.h $P/include/ffi.h
  printf '/* ffitarget.h: see ffi.h */\n' > $P/include/ffitarget.h
  printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: libffi\nDescription: libffi subset for wasm32\nVersion: 3.4.6\nLibs: -L${libdir} -lffi\nCflags: -I${includedir}\n' $P > $P/lib/pkgconfig/libffi.pc
}

glib() {
  unpack glib glib-2.84.4.tar.xz
  WRAP=default mesonbuild glib -Dtests=false -Dintrospection=disabled -Dlibmount=disabled \
      -Dselinux=disabled -Dxattr=false -Dnls=disabled -Dman-pages=disabled \
      -Ddocumentation=false -Dsysprof=disabled -Ddtrace=disabled -Dsystemtap=disabled \
      -Dglib_debug=disabled -Dlibelf=disabled -Dbsymbolic_functions=false \
      -Dpcre2:jit=disabled -Dpcre2:test=false -Dpcre2:grep=false
  [ -f $P/lib/pkgconfig/libpcre2-8.pc ]   # glib-2.0.pc requires it
}

fribidi() {
  unpack fribidi fribidi-1.0.17.tar.xz
  mesonbuild fribidi -Ddocs=false -Dbin=false -Dtests=false
}

harfbuzz() {
  unpack harfbuzz harfbuzz-11.4.5.tar.xz
  mesonbuild harfbuzz -Dglib=enabled -Dgobject=disabled -Dfreetype=enabled -Dcairo=disabled \
      -Dicu=disabled -Dgraphite2=disabled -Dintrospection=disabled -Dtests=disabled \
      -Dutilities=disabled -Ddocs=disabled -Dbenchmark=disabled -Dcpp_std=c++17
}

pixman() {
  unpack pixman pixman-0.46.4.tar.gz
  mesonbuild pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled \
      -Dopenmp=disabled -Dtimers=false
}

cairo() {
  unpack cairo cairo-1.18.6.tar.xz
  mesonbuild cairo -Dxlib=enabled -Dxcb=disabled -Dxlib-xcb=disabled -Dpng=enabled \
      -Dfreetype=enabled -Dfontconfig=enabled -Dglib=enabled -Dzlib=enabled \
      -Dtests=disabled -Dspectre=disabled -Dsymbol-lookup=disabled -Dgtk_doc=false \
      -Dlzo=disabled -Dquartz=disabled -Ddwrite=disabled
}

pango() {
  unpack pango pango-1.56.4.tar.xz
  mesonbuild pango -Dintrospection=disabled -Dfontconfig=enabled -Dfreetype=enabled \
      -Dcairo=enabled -Dxft=disabled -Dlibthai=disabled -Dbuild-testsuite=false \
      -Dbuild-examples=false -Ddocumentation=false -Dman-pages=false -Dsysprof=disabled
}

atk() {
  unpack atk atk-2.38.0.tar.xz
  mesonbuild atk -Dintrospection=false -Ddocs=false
}

gdkpixbuf() {
  unpack gdkpixbuf gdk-pixbuf-2.42.12.tar.xz
  mesonbuild gdkpixbuf -Dpng=enabled -Djpeg=disabled -Dtiff=disabled -Dgif=enabled \
      -Dothers=enabled -Dbuiltin_loaders=all -Dintrospection=disabled -Dman=false \
      -Dgtk_doc=false -Ddocs=false -Dinstalled_tests=false -Dtests=false -Dgio_sniffing=false \
      -Drelocatable=false \
      "-Dc_link_args=['-L$P/lib', '-L$FM/lib', '-L$X/lib', '-lpng16', '-lz']"   # tools: the builtin loader's libpng
}

gtk() {
  unpack gtk gtk+-2.24.33.tar.xz
  # 2.24.33 does not build without XKB: one get_xkb() call is unguarded
  python3 - gdk/x11/gdkkeys-x11.c <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  if (KEYMAP_USE_XKB (keymap))\n    get_xkb (keymap_x11);\n\n  retval = TRUE;"
assert s.count(old) == 1, "gdkkeys-x11.c anchor"
open(p, "w").write(s.replace(old, "#ifdef HAVE_XKB\n" + old.split("\n\n")[0] + "\n#endif\n\n  retval = TRUE;"))
PY
  # clang makes these errors; on wasm a call through a wrongly-typed function
  # pointer traps, so each one is reviewed (see README) rather than silenced
  export CFLAGS="$CFLAGS -Wno-error=incompatible-function-pointer-types -Wno-error=int-conversion"
  ./configure $HOST $XDIRS --prefix=$P --disable-shared --enable-static \
      --with-gdktarget=x11 --disable-introspection --disable-cups --disable-papi \
      --disable-gtk-doc --disable-glibtest --disable-modules --with-included-immodules \
      --without-libjasper --without-libtiff --without-libjpeg --disable-xinerama \
      --disable-visibility \
      GDK_PIXBUF_CSOURCE=/usr/bin/gdk-pixbuf-csource \
      GTK_UPDATE_ICON_CACHE=/usr/bin/gtk-update-icon-cache \
      ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes \
      ac_cv_func_XkbQueryExtension=no   # only stubbed in libX11compat: no XKB
  make $J -C gdk
  make $J -C gtk libgtk-x11-2.0.la
  make -C gdk install
  make -C gtk install-libLTLIBRARIES install-gtkincludeHEADERS install-nodist_gtkincludeHEADERS \
       install-gtkunixprintincludeHEADERS 2>/dev/null || make -C gtk install-data
  make install-pkgconfigDATA 2>/dev/null || true
  for f in gdk-2.0 gdk-x11-2.0 gtk+-2.0 gtk+-x11-2.0; do [ -f $f.pc ] && cp $f.pc $P/lib/pkgconfig/; done
}

openssl() {
  unpack openssl openssl-1.1.1w.tar.gz
  ./Configure linux-generic32 no-asm no-shared no-dso no-engine no-async no-tests \
      no-ui-console -DOPENSSL_NO_SECURE_MEMORY --prefix=$P --openssldir=/etc/ssl -O2
  make $J build_libs
  make install_dev
}

sylpheed() {
  # the xlibi18n calls GDK makes that our libX11 lacks
  $CC -O2 -c /lot/syl/gtk_x11_compat.c -o $B/gtk_x11_compat.o
  rm -f $P/lib/libgtkx11compat.a && $AR rcs $P/lib/libgtkx11compat.a $B/gtk_x11_compat.o
  # marks the module for the runtime: post-processed with --fpcast-emu below
  printf '__attribute__((export_name("__lot_fpcast"))) void __lot_fpcast(void) {}\n' > $B/lot_fpcast.c
  $CC -O2 -c $B/lot_fpcast.c -o $B/lot_fpcast.o
  export LIBS="$B/lot_fpcast.o -lgtkx11compat -lexpat"
  unpack sylpheed sylpheed-3.7.0.tar.xz
  # 3.7 sends no SNI: Gmail and other shared TLS front ends answer with a
  # "No SNI provided" self-signed certificate. Name the host (3.8 does too).
  python3 - libsylph/ssl.c <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "\tSSL_set_fd(sockinfo->ssl, sockinfo->sock);\n"
assert s.count(old) == 1, "ssl.c anchor"
s = s.replace(old, "\tif (sockinfo->hostname)\n\t\tSSL_set_tlsext_host_name(sockinfo->ssl, sockinfo->hostname);\n" + old)
open(p, "w").write(s)
PY
  ./configure $HOST $XDIRS --prefix=/usr --disable-shared --enable-static \
      --disable-gpgme --disable-oniguruma --disable-gtkspell --disable-ldap \
      --disable-jpilot --disable-compface --disable-updatecheck --disable-nls \
      --enable-ssl --with-ssl-dir=$P \
      ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes
  make $J
  make install DESTDIR=/work/gtk/sylroot
  # GTK 2 and Sylpheed call through mismatched function pointer types
  # (one-argument class_init/instance_init, short signal handlers,
  # gtk_widget_destroy as a GtkCallback): every indirect call goes through
  # binaryen's i64 thunks instead of trapping. The runtime adapts its own
  # JS-side table calls for modules exporting __lot_fpcast (worker.ts).
  wasm-opt --enable-threads --enable-bulk-memory --enable-exception-handling \
      --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
      --fpcast-emu --pass-arg=max-func-params@20 -O2 /work/gtk/sylroot/usr/bin/sylpheed -o /work/gtk/sylroot/usr/bin/sylpheed.fp
  mv /work/gtk/sylroot/usr/bin/sylpheed.fp /work/gtk/sylroot/usr/bin/sylpheed
  ls -la /work/gtk/sylroot/usr/bin/sylpheed
}

gtktest() {
  # spikes/sylpheed/test/gtkbtn.c: GTK 2 button/dialog event probe for xtiny
  mkdir -p $B/gtktest && cd $B/gtktest
  $CC -O2 $CPPFLAGS $(pkg-config --static --cflags gtk+-2.0) -c /lot/syl/test/gtkbtn.c -o gtkbtn.o
  $CC -o gtkbtn gtkbtn.o $B/lot_fpcast.o $LDFLAGS $(pkg-config --static --libs gtk+-2.0) -lgtkx11compat -lexpat
  wasm-opt --enable-threads --enable-bulk-memory --enable-exception-handling \
      --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
      --fpcast-emu --pass-arg=max-func-params@20 -O2 gtkbtn -o /work/gtk/gtkbtn
  ls -la /work/gtk/gtkbtn
}

# each step in its own shell: set -e is ignored inside anything called
# from an || list, which silently turned failed steps into "ok"
if [ "${1:-}" = __step ]; then $2; exit 0; fi
steps="${*:-prep ffi glib fribidi harfbuzz pixman cairo pango atk gdkpixbuf gtk openssl sylpheed}"
for s in $steps; do
  echo "=== $s"
  if sh "$0" __step "$s" > $B/$s.log 2>&1; then echo "ok: $s"
  else echo "FAILED: $s (see $B/$s.log)"; tail -30 $B/$s.log; exit 1; fi
done
