#!/bin/sh
# Recipe: nix — Nix package manager CLI/daemon binary
#
# Goal: build a wasm32-linux-musl binary suitable for LinuxOnTab guest.
# This is an initial porting recipe and may require iterative dependency
# enable/disable tuning as upstream Nix assumptions are surfaced.

NAME="nix"
VERSION="2.24.11"
DESCRIPTION="Nix package manager CLI and daemon"
SOURCE_URL="https://github.com/NixOS/nix/archive/refs/tags/${VERSION}.tar.gz"

build() {
    # Meson-first path: upstream is migrating off autotools and this avoids
    # local autoreconf incompatibilities on macOS host setups.
    command -v meson >/dev/null 2>&1 || { echo "meson is required"; exit 1; }
    if [ ! -f "$SYSROOT/include/c++/v1/string" ] && [ -d /nix/store/0yfbk210bwhffl65fdrsr76ll7hdic8y-sysroot ]; then
        export SYSROOT=/nix/store/0yfbk210bwhffl65fdrsr76ll7hdic8y-sysroot
    fi
    if [ -x /opt/homebrew/opt/bison/bin/bison ]; then
        export PATH="/opt/homebrew/opt/bison/bin:$PATH"
    fi

    export PKG_CONFIG_PATH="/tmp/lot-build/libarchive/stage/usr/lib/pkgconfig:/tmp/lot-build/libgit2/stage/usr/lib/pkgconfig:/tmp/lot-build/libeditline/stage/usr/lib/pkgconfig:/tmp/lot-build/openssl/stage/usr/lib/pkgconfig:/tmp/lot-build/libsodium/stage/usr/lib/pkgconfig:/tmp/lot-build/brotli/stage/usr/lib/pkgconfig:/tmp/lot-build/libcurl/stage/usr/lib/pkgconfig:/tmp/lot-build/sqlite3/stage/usr/lib/pkgconfig:/tmp/lot-build/nlohmann_json/stage/usr/lib/pkgconfig:/tmp/lot-build/toml11/stage/usr/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
    export C_INCLUDE_PATH="/tmp/lot-build/boost/stage/usr/include:/tmp/lot-build/libarchive/stage/usr/include:/tmp/lot-build/libgit2/stage/usr/include:/tmp/lot-build/libeditline/stage/usr/include:/tmp/lot-build/openssl/stage/usr/include:/tmp/lot-build/libsodium/stage/usr/include:/tmp/lot-build/brotli/stage/usr/include:/tmp/lot-build/libcurl/stage/usr/include:/tmp/lot-build/sqlite3/stage/usr/include:/tmp/lot-build/nlohmann_json/stage/usr/include:/tmp/lot-build/toml11/stage/usr/include"
    export CPLUS_INCLUDE_PATH="$C_INCLUDE_PATH"

    export BOOST_ROOT="/tmp/lot-build/boost/stage/usr"
    export BOOST_INCLUDEDIR="$BOOST_ROOT/include"
    export BOOST_LIBRARYDIR="$BOOST_ROOT/lib"

    CROSS_FILE="$SRC/meson-cross-wasm.ini"
    cat > "$CROSS_FILE" << EOF
[binaries]
c = ['$CLANG', '--target=wasm32', '--sysroot=$SYSROOT', '-fuse-ld=lld', '-nostdlib', '$BUILTINS']
cpp = ['$CLANG', '--target=wasm32', '--sysroot=$SYSROOT', '-fuse-ld=lld', '-nostdlib', '$BUILTINS']
ar = '$AR'
pkg-config = 'pkg-config'
cmake = 'cmake'

[host_machine]
system = 'linux'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'

[built-in options]
c_args = ['-O2', '-matomics', '-mbulk-memory', '-D_GNU_SOURCE', '-D_LIBCPP_HAS_THREAD_API_PTHREAD']
cpp_args = ['-O2', '-matomics', '-mbulk-memory', '-D_GNU_SOURCE', '-D_LIBCPP_HAS_THREAD_API_PTHREAD']
c_link_args = ['-L/tmp/lot-build/libarchive/stage/usr/lib', '-L/tmp/lot-build/libgit2/stage/usr/lib', '-L/tmp/lot-build/libeditline/stage/usr/lib', '-L/tmp/lot-build/openssl/stage/usr/lib', '-L/tmp/lot-build/libsodium/stage/usr/lib', '-L/tmp/lot-build/brotli/stage/usr/lib', '-L/tmp/lot-build/libcurl/stage/usr/lib', '-L/tmp/lot-build/sqlite3/stage/usr/lib']
cpp_link_args = ['-L/tmp/lot-build/libarchive/stage/usr/lib', '-L/tmp/lot-build/libgit2/stage/usr/lib', '-L/tmp/lot-build/libeditline/stage/usr/lib', '-L/tmp/lot-build/openssl/stage/usr/lib', '-L/tmp/lot-build/libsodium/stage/usr/lib', '-L/tmp/lot-build/brotli/stage/usr/lib', '-L/tmp/lot-build/libcurl/stage/usr/lib', '-L/tmp/lot-build/sqlite3/stage/usr/lib']
EOF

    # Build from the root Meson graph so inter-library dependencies (nix-util,
    # nix-store, etc.) resolve through Meson subprojects.
    if grep -q "dependency(" src/libexpr/meson.build; then
        perl -0777 -i -pe "s/method\s*:\s*'cmake'/method : 'pkg-config'/g" src/libexpr/meson.build
    fi

    # For bootstrap builds, skip optional docs and tests subprojects that pull
    # host-only tooling (doxygen, test frameworks) not needed for core binary.
    perl -0777 -i -pe "s/^subproject\('internal-api-docs'\)\n//mg; s/^subproject\('external-api-docs'\)\n//mg; s/^subproject\('nix-util-test-support'\)\n//mg; s/^subproject\('nix-util-tests'\)\n//mg; s/^subproject\('nix-store-test-support'\)\n//mg; s/^subproject\('nix-store-tests'\)\n//mg; s/^subproject\('nix-fetchers-tests'\)\n//mg; s/^subproject\('nix-expr-test-support'\)\n//mg; s/^subproject\('nix-expr-tests'\)\n//mg; s/^subproject\('nix-flake-tests'\)\n//mg" meson.build

    # WASM sysroot in this environment provides clone() but not mmap/munmap.
    # Patch the __wasm__ doFork path to use malloc/free stack storage.
    perl -0777 -i -pe 's@#if defined\(__linux__\) \|\| defined\(__wasm__\)\n# include <sys/mman.h>\n#endif@#ifdef __linux__\n# include <sys/mman.h>\n#endif@s' src/libutil/unix/processes.cc
    perl -0777 -i -pe 's@(using ChildWrapperFunction = std::function<void\(\)>;\n)@$1\n#if defined(__linux__) || defined(__wasm__)\nstatic int childEntry(void * arg);\n#endif\n\n#ifdef __wasm__\nextern "C" int clone(int (*)(void *), void *, int, void *, ...);\n#endif\n@s' src/libutil/unix/processes.cc
    perl -0777 -i -pe 's@#if defined\(__wasm__\)\n\s*\(void\)allowVfork;\n\s*size_t stackSize = 1 \* 1024 \* 1024;\n\s*auto stack = static_cast<char \*>\(mmap\(0, stackSize,\n\s*PROT_WRITE \| PROT_READ, MAP_PRIVATE \| MAP_ANONYMOUS \| MAP_STACK, -1, 0\)\);\n\s*if \(stack == MAP_FAILED\) return -1;\n\s*pid_t pid = clone\(childEntry, stack \+ stackSize, SIGCHLD, &fun\);\n\s*munmap\(stack, stackSize\);\n\s*return pid;\n#elif __linux__@#if defined(__wasm__)\n    (void)allowVfork;\n    constexpr size_t stackSize = 1 * 1024 * 1024;\n    auto stack = static_cast<char *>(std::malloc(stackSize));\n    if (!stack) return -1;\n    pid_t pid = clone(childEntry, stack + stackSize, SIGCHLD, &fun, nullptr);\n    std::free(stack);\n    return pid;\n#elif __linux__@s' src/libutil/unix/processes.cc
    perl -0777 -i -pe 's@#ifdef __linux__\n\s*pid_t pid = allowVfork \? vfork\(\) : fork\(\);\n#else\n\s*pid_t pid = fork\(\);\n#endif@#if defined(__wasm__)\n    (void)allowVfork;\n    constexpr size_t stackSize = 1 * 1024 * 1024;\n    auto stack = static_cast<char *>(std::malloc(stackSize));\n    if (!stack) return -1;\n    pid_t pid = clone(childEntry, stack + stackSize, SIGCHLD, &fun, nullptr);\n    std::free(stack);\n    return pid;\n#elif defined(__linux__)\n    pid_t pid = allowVfork ? vfork() : fork();\n#else\n    pid_t pid = fork();\n#endif@s' src/libutil/unix/processes.cc
    perl -0777 -i -pe 's@#if __linux__\nstatic int childEntry@#if defined(__linux__) || defined(__wasm__)\nstatic int childEntry@s' src/libutil/unix/processes.cc
    perl -0777 -i -pe 's@\Q#if __linux__ || defined(__wasm__)\E@#if defined(__linux__) || defined(__wasm__)@g' src/libutil/unix/processes.cc

    # Avoid unresolved TLS relocations during wasm prelink of libstore.
    perl -0777 -i -pe 's@extern thread_local std::function<bool\(\)> interruptCheck;@#ifdef __wasm__\nextern std::function<bool()> interruptCheck;\n#else\nextern thread_local std::function<bool()> interruptCheck;\n#endif@s' src/libutil/unix/signals-impl.hh
    perl -0777 -i -pe 's@thread_local std::function<bool\(\)> unix::interruptCheck;@#ifdef __wasm__\nstd::function<bool()> unix::interruptCheck;\n#else\nthread_local std::function<bool()> unix::interruptCheck;\n#endif@s' src/libutil/unix/signals.cc

    # Avoid ambiguity with libc splice() overloads when compiling daemon.cc.
    perl -0777 -i -pe 's@static ssize_t splice\(@static ssize_t splice_nointr(@g; s@auto res = splice\(@auto res = splice_nointr(@g' src/nix/unix/daemon.cc

    meson setup build-meson . --cross-file "$CROSS_FILE" --buildtype=release --prefix=/usr -Ddefault_library=static
    perl -i -pe 's/-Wl,--start-group\s*//g; s/-Wl,--end-group\s*//g' build-meson/build.ninja
    meson compile -C build-meson

    # Install and normalize entrypoints into /bin for apk metadata compatibility.
    DESTDIR="$STAGE" meson install -C build-meson
    if [ -x "$STAGE/usr/bin/nix" ]; then
        install -Dm755 "$STAGE/usr/bin/nix" "$STAGE/bin/nix"
        ln -sf nix "$STAGE/bin/nix-daemon"
        ln -sf nix "$STAGE/bin/nix-store"
        ln -sf nix "$STAGE/bin/nix-env"
    fi
}