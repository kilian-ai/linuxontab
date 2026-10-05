#!/bin/sh
# Configure LibreOffice for Linux on wasm32 (run inside the build container,
# in the source tree): sh /lot/spike/configure.sh
set -eu
B=/lot/spike/bin
# the nested native configure for the build tools needs Python headers, and
# Python 3.13 has no distutils for configure's own probe
export PYTHON_CFLAGS="$(python3-config --includes)" PYTHON_LIBS="$(python3-config --embed --libs)"
export PKG_CONFIG_LIBDIR=/work/xprefix/lib/pkgconfig   # host (wasm) .pc files: the X11 client libs
./autogen.sh \
  --host=wasm32-unknown-linux-musl --build=aarch64-unknown-linux-gnu \
  CC="$B/wasm-cc" CXX="$B/wasm-c++" \
  AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm OBJDUMP=llvm-objdump STRIP=llvm-strip \
  CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ \
  --x-includes=/work/xprefix/include --x-libraries=/work/xprefix/lib \
  --disable-dynamic-loading --enable-gen --disable-gtk3 --disable-gtk4 \
  --disable-qt5 --disable-qt6 --disable-kf5 --disable-kf6 \
  --without-java --disable-python --disable-scripting \
  --without-system-libs --without-system-headers \
  --disable-cups --disable-dbus --disable-gio --disable-dconf --disable-randr \
  --disable-gstreamer-1-0 --disable-avmedia --disable-pdfimport --disable-poppler \
  --disable-lpsolve --disable-coinmp --disable-firebird-sdbc --disable-postgresql-sdbc \
  --disable-mariadb-sdbc --disable-database-connectivity \
  --disable-extensions --disable-extension-integration --disable-extension-update \
  --disable-online-update --disable-sdremote --disable-report-builder --disable-ldap \
  --disable-gpgmepp --disable-nss --without-krb5 --without-gssapi \
  --disable-skia --disable-opencl --disable-opengl --disable-libcmis --disable-cve-tests \
  --disable-odk --disable-breakpad --disable-zxing --disable-ccache \
  --without-help --without-helppack-integration --without-myspell-dicts \
  --without-galleries --without-templates --disable-xmlhelp --without-doxygen \
  --with-theme=colibre --with-locales=en --with-lang= \
  --disable-debug --disable-symbols --enable-release-build=no \
  "$@"
