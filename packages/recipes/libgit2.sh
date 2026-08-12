#!/bin/sh
# Recipe: libgit2 — static libgit2 for wasm32-linux-musl

NAME="libgit2"
VERSION="1.8.1"
DESCRIPTION="libgit2 static library"
SOURCE_URL="https://github.com/libgit2/libgit2/archive/refs/tags/v1.8.1.tar.gz"
SOURCE_SHA256=""

build() {
    command -v cmake >/dev/null 2>&1 || { echo "cmake is required"; exit 1; }

    perl -0pi -e 's/file\(GLOB UTIL_SRC \*\.c \*\.h allocators\/\*\.c allocators\/\*\.h hash\.h\)\nlist\(SORT UTIL_SRC\)/file(GLOB UTIL_SRC *.c *.h allocators\/*.c allocators\/*.h hash.h)\nif(CMAKE_SYSTEM_PROCESSOR STREQUAL "wasm32")\n    list(FILTER UTIL_SRC EXCLUDE REGEX "allocators\/win32_leakcheck\\.c")\nendif()\nlist(SORT UTIL_SRC)/s' src/util/CMakeLists.txt

    cmake -S . -B build \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER_TARGET=wasm32 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_SIZEOF_VOID_P=4 \
        -DCMAKE_C_COMPILER="$CLANG" \
        -DCMAKE_C_FLAGS="--target=wasm32 --sysroot=$SYSROOT -fuse-ld=lld -O2 -matomics -mbulk-memory -D_GNU_SOURCE -DNO_MMAP" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS $CRT1 -lc -lm $BUILTINS" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_CLI=OFF \
        -DUSE_THREADS=OFF \
        -DUSE_SSH=OFF \
        -DUSE_HTTPS=OFF \
        -DUSE_ICONV=OFF \
        -DUSE_NSEC=OFF \
        -DREGEX_BACKEND=regcomp

    cmake --build build -j4
    DESTDIR="$STAGE" cmake --install build

    if [ ! -f "$STAGE/usr/lib/pkgconfig/libgit2.pc" ]; then
        mkdir -p "$STAGE/usr/lib/pkgconfig"
        cat > "$STAGE/usr/lib/pkgconfig/libgit2.pc" << 'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: libgit2
Description: A portable, pure C implementation of Git
Version: 1.8.1
Cflags: -I${includedir}
Libs: -L${libdir} -lgit2
EOF
    fi
}