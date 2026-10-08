#!/bin/sh
# Prototype: Xfe (X File Explorer) + its stack for the wasm guest, in the
# LibreOffice build container (same wasm-cc wrapper / cpp-eh-sysroot):
#   zlib libpng freetype expat fontconfig libXft FOX Xfe
#   sh /lot/spike/xfe/build.sh [step...]     (default: all, in order)
# Mounts: /lot/toolchain /lot/sysroot /lot/spike (= spikes/libreoffice),
# /lot/packages (the repo's packages/, read-only); /work = a docker volume.
set -eu
S=/work/fm/src; B=/work/fm/build; P=/work/fm/prefix; R=/work/fm/root
mkdir -p $B $P $R
export CC=/lot/spike/bin/wasm-cc CXX=/lot/spike/bin/wasm-c++
export AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm STRIP=llvm-strip OBJDUMP=llvm-objdump
export PKG_CONFIG_LIBDIR=$P/lib/pkgconfig:/work/xprefix/lib/pkgconfig
# wasm-cc defines __linux__ (for LibreOffice), which makes Xfuncproto.h pick
# NARROWPROTO; the X libraries (packages/libX11 & co) were built without it,
# i.e. with wide prototypes. Keep the headers on the libraries' ABI.
export CFLAGS="-O2" CXXFLAGS="-O2" CPPFLAGS="-DNeedWidePrototypes=1 -I$P/include -I$P/include/freetype2" LDFLAGS="-L$P/lib -L/work/xprefix/lib"
XDIRS="--x-includes=/work/xprefix/include --x-libraries=/work/xprefix/lib"
export CC_BUILD=gcc CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++
HOST="--host=wasm32-unknown-linux-musl --build=aarch64-unknown-linux-gnu"
J=-j8

prep() {
  # the guest's X11 client libraries, from their packages
  rm -rf /work/xprefix /tmp/xp && mkdir -p /work/xprefix /tmp/xp
  for t in libX11-1.8.10 libxcb-1.17.0 libXau-1.0.12 libXdmcp-1.1.5 libXext-1.3.6 libXrender-0.9.12 \
           libXrandr-1.5.4 xorgproto-2024.1; do
    tar xzf /lot/packages/$t.tar.gz -C /tmp/xp 2>/dev/null
  done
  for d in /tmp/xp/pkg-*; do cp -R $d/usr/. /work/xprefix/; done
  rm -f /work/xprefix/lib/*.la
  sed -i "s|^prefix=/usr|prefix=/work/xprefix|" /work/xprefix/lib/pkgconfig/*.pc
  for p in xproto:7.0.33 xextproto:7.3.0 renderproto:0.11.1 randrproto:1.6.0 kbproto:1.0.7; do
    printf "prefix=/work/xprefix\nincludedir=\${prefix}/include\n\nName: %s\nDescription: X11 protocol headers\nVersion: %s\nCflags: -I\${includedir}\n" \
      ${p%%:*} ${p##*:} > /work/xprefix/lib/pkgconfig/${p%%:*}.pc
  done
  sh /lot/spike/build-shims.sh
  mkdir -p $S && cd $S
  [ -f zlib-1.3.1.tar.gz ] || curl -sfLO https://zlib.net/fossils/zlib-1.3.1.tar.gz
  [ -f libpng-1.6.47.tar.xz ] || curl -sfL -o libpng-1.6.47.tar.xz https://download.sourceforge.net/libpng/libpng-1.6.47.tar.xz
  [ -f freetype-2.13.3.tar.xz ] || curl -sfL -o freetype-2.13.3.tar.xz https://downloads.sourceforge.net/project/freetype/freetype2/2.13.3/freetype-2.13.3.tar.xz
  [ -f expat-2.8.5.tar.xz ] || curl -sfLO https://github.com/libexpat/libexpat/releases/download/R_2_8_5/expat-2.8.5.tar.xz
  [ -f fontconfig-2.16.0.tar.xz ] || curl -sfLO https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.16.0.tar.xz
  [ -f libXft-2.3.9.tar.xz ] || curl -sfLO https://www.x.org/releases/individual/lib/libXft-2.3.9.tar.xz
  [ -f fox-1.6.59.tar.gz ] || curl -sfLO http://fox-toolkit.org/ftp/fox-1.6.59.tar.gz
  [ -f xfe-2.1.11.tar.xz ] || curl -sfL -o xfe-2.1.11.tar.xz https://downloads.sourceforge.net/project/xfe/xfe/2.1.11/xfe-2.1.11.tar.xz
  ls -la
}
stage() {
  # the package tree: xfe (asyncified later by build-package), its data with
  # the default icon theme, DejaVu fonts, fontconfig setup, menu entry
  O=/work/fm/stage
  rm -rf $O && mkdir -p $O/usr/local/bin $O/usr/share/xfe/icons $O/usr/share/fonts/dejavu \
      $O/etc/fonts $O/var/cache/fontconfig $O/usr/share/applications
  install -m755 /work/fm/xferoot/usr/bin/xfe $O/usr/local/bin/xfe
  cp /work/fm/xferoot/usr/share/xfe/xferc $O/usr/share/xfe/xferc
  cat /lot/spike/xfe/xferc.lot >> $O/usr/share/xfe/xferc
  cp -R /work/fm/xferoot/usr/share/xfe/icons/default-theme $O/usr/share/xfe/icons/
  cp /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
     /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf $O/usr/share/fonts/dejavu/
  cp /usr/share/doc/fonts-dejavu-core/copyright $O/usr/share/fonts/dejavu/LICENSE 2>/dev/null || true
  cp /lot/spike/xfe/fonts.conf $O/etc/fonts/fonts.conf
  cp /lot/spike/xfe/xfe.desktop $O/usr/share/applications/xfe.desktop
  ls -laR $O | head -30
}

unpack() { rm -rf $B/$1; mkdir -p $B/$1; tar xf $S/$2 -C $B/$1 --strip-components=1; cd $B/$1; }

zlib() {
  unpack zlib zlib-1.3.1.tar.gz
  CHOST=wasm32 ./configure --static --prefix=$P
  make $J libz.a && make install
}
libpng() {
  unpack libpng libpng-1.6.47.tar.xz
  ./configure $HOST --prefix=$P --disable-shared --enable-static --disable-hardware-optimizations --disable-tools
  make $J libpng16.la && make install-libLTLIBRARIES install-pkgincludeHEADERS install-nodist_pkgincludeHEADERS install-pkgconfigDATA install-header-links install-library-links install-libpng-pc 2>/dev/null || make install
}
freetype() {
  unpack freetype freetype-2.13.3.tar.xz
  ./configure $HOST --prefix=$P --disable-shared --enable-static --with-zlib=yes --with-png=no \
      --with-brotli=no --with-bzip2=no --with-harfbuzz=no
  make $J && make install
}
expat() {
  unpack expat expat-2.8.5.tar.xz
  ./configure $HOST --prefix=$P --disable-shared --enable-static --without-docbook \
      --without-examples --without-tests --without-xmlwf
  make $J && make install
}
fontconfig() {
  unpack fontconfig fontconfig-2.16.0.tar.xz
  ./configure $HOST --prefix=$P --sysconfdir=/etc --localstatedir=/var \
      --with-default-fonts=/usr/share/fonts --with-cache-dir=/var/cache/fontconfig \
      --with-baseconfigdir=/etc/fonts --with-templatedir=/usr/share/fontconfig/conf.avail \
      --disable-shared --enable-static --disable-docs --disable-cache-build --disable-nls
  make $J && make install DESTDIR=$R
  cp -R $R$P/. $P/
}
libxft() {
  unpack libxft libXft-2.3.9.tar.xz
  ./configure $HOST --prefix=$P --disable-shared --enable-static
  make $J && make install
}
fox() {
  unpack fox fox-1.6.59.tar.gz
  # reswrap runs at build time: it must be a native program
  g++ -O2 -o /work/fm/reswrap-native utils/reswrap.cpp
  # Asyncify (which provides fork on the guest) cannot rewind through a
  # function containing try/catch, and every widget message goes through
  # tryHandle: dispatch directly, letting resource exceptions propagate
  sed -i 's|  try { return handle(sender,sel,ptr); } catch(const FXResourceException\&) { return 0; }|  return handle(sender,sel,ptr);  /* LinuxOnTab: no try (asyncify fork) */|' src/FXObject.cpp
  grep -q "LinuxOnTab: no try" src/FXObject.cpp
  # Xfe redefines ~35 FOX methods (foxhacks.cpp): make FOX's copies weak
  rm -rf /tmp/xfe-2.1.11 && tar xf $S/xfe-2.1.11.tar.xz -C /tmp xfe-2.1.11/src
  python3 /lot/spike/xfe/weaken-fox.py src /tmp/xfe-2.1.11/src
  ./configure $HOST $XDIRS --prefix=$P --disable-shared --enable-static --enable-release \
      --with-xft=yes --disable-jpeg --disable-tiff --disable-bz2lib --enable-png --enable-zlib \
      --with-opengl=no --with-xshm=no --with-xcursor=no --with-xrandr=no --with-xfixes=no \
      --with-xinput=no --with-xim=no
  grep -q "X_DISPLAY_MISSING 1" config.h 2>/dev/null && { echo "configure did not find X"; return 1; }
  grep -q "X_DISPLAY_MISSING=1" Makefile && { echo "configure did not find X"; return 1; }
  make -C utils reswrap || true
  cp /work/fm/reswrap-native utils/reswrap
  touch utils/reswrap
  make $J -C include
  make $J -C src
  make -C include install
  make -C src install
  mkdir -p $P/bin $P/lib/pkgconfig
  install -m755 fox-config $P/bin/fox-config
  install -m644 fox.pc $P/lib/pkgconfig/fox.pc
}
xfe() {
  # our libX11 is built without xlibi18n: the symbols it still references
  $CC -O2 -c /lot/spike/xfe/x11_compat.c -o $B/x11_compat.o
  $CC -O2 $CPPFLAGS -I/work/xprefix/include -c /lot/spike/xfe/x11_im_compat.c -o $B/x11_im_compat.o
  $CC -O2 -c /lot/sysroot/wasm_syscall_cp.c -o $B/wasm_syscall_cp.o
  rm -f $P/lib/libX11compat.a
  $AR rcs $P/lib/libX11compat.a $B/x11_compat.o $B/x11_im_compat.o $B/wasm_syscall_cp.o
  rm -f $P/lib/*.la                  # static only; stale .la break libtool links
  # static libs: name every dependency for configure's link tests and the link
  $CC -O2 -c /lot/sysroot/wasm_fork.c -o $B/wasm_fork.o
  # Xfe checks the GNU-mode "linux" macro (97 places), not __linux__
  export CPPFLAGS="$CPPFLAGS -Dlinux=1 -include /lot/spike/xfe/wasm_fork_decl.h"
  export LIBS="$B/wasm_fork.o -lFOX-1.6 -lXft -lfontconfig -lexpat -lfreetype -lpng -lz -lXrender -lXrandr -lXext -lX11 -lxcb -lXau -lX11compat"
  unpack xfe xfe-2.1.11.tar.xz
  # cross-compiling, autoconf cannot run its malloc(0) probe and assumes the
  # worst (rpl_malloc); musl's malloc(0) is fine
  PATH=$P/bin:$PATH ./configure $HOST $XDIRS --prefix=/usr --disable-sn --disable-nls \
      ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes
  PATH=$P/bin:$PATH make $J
  # the .desktop files come from msgfmt (gettext, not installed): use the templates
  for f in *.desktop.in; do sed 's/^_//' "$f" > "${f%.in}"; done
  make install DESTDIR=/work/fm/xferoot
}

# each step in its own shell: set -e is ignored inside anything called
# from an || list, which silently turned failed steps into "ok"
if [ "${1:-}" = __step ]; then $2; exit 0; fi
steps="${*:-prep zlib libpng freetype expat fontconfig libxft fox xfe stage}"
for s in $steps; do
  echo "=== $s"
  if sh "$0" __step "$s" > $B/$s.log 2>&1; then echo "ok: $s"
  else echo "FAILED: $s (see $B/$s.log)"; tail -25 $B/$s.log; exit 1; fi
done
