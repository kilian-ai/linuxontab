#!/bin/sh
# local/build-wasm-toolchain.sh
# Build the wasm32-linux-musl toolchain components as guest-runnable WASM packages.
#
# Produces WASM binaries that run *inside* the LinuxOnTab WASM kernel, implementing
# the same compilation pipeline the host Nix build uses:
#   Phase 1: wasm-opt  (binaryen)            — asyncify + optimize
#   Phase 2: wasm-ld   (LLVM/lld)            — WebAssembly linker
#   Phase 3: clang     (LLVM, WASM backend)  — C/C++ compiler
#
# Usage:
#   ./local/build-wasm-toolchain.sh [phase...]
#   ./local/build-wasm-toolchain.sh 1            # only wasm-opt
#   ./local/build-wasm-toolchain.sh 1 2          # wasm-opt + wasm-ld
#   ./local/build-wasm-toolchain.sh              # all phases
#
# Optional env overrides:
#   LOT_CLANG, LOT_CPP_SYSROOT, LOT_MUSL_SYSROOT, LOT_WASM_LD, LOT_WASM_OPT
#   LOT_BUILD_DIR  (default: /tmp/lot-wasm-toolchain)
#   LOT_JOBS       (default: nproc)
#
# Requirements:
#   - Nix with nixpkgs (for cmake + ninja via nix-shell)
#   - brew install binaryen  (for wasm-opt on host, used to asyncify)
#
# The asyncified output binaries are copied to rootfs/usr/wasm-toolchain/bin/
# and packaged as wasm-toolchain-*.tar.gz in packages/.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${LOT_BUILD_DIR:-/tmp/lot-wasm-toolchain}"
PHASES="${*:-1 2 3}"

# ── Locate host toolchain ──────────────────────────────────────────────────────
_nix_find() { find /nix/store -maxdepth 5 "$@" 2>/dev/null | sort | head -1; }

CLANG="${LOT_CLANG:-$(_nix_find -type f -name 'clang-19' -path '*/bin/clang-19' -path '*-clang*' ! -path '*wrapper*' -path '*sa4f4*')}"
# Fallback: look for any clang-19 that has the WASM32 target
if [ -z "$CLANG" ]; then
    CLANG=$(_nix_find -type f -name 'clang-19' -path '*/bin/clang-19' ! -path '*wrapper*' | \
        while read f; do
            "$f" -target wasm32 -x c /dev/null -S -o /dev/null 2>/dev/null && echo "$f" && break
        done)
fi
CLANGXX="${CLANG%clang-19}clang++"
LLVM_AR="${LOT_LLVM_AR:-$(_nix_find -name 'llvm-ar' -path '*llvm-19*' ! -path '*.src*')}"
WASM_LD="${LOT_WASM_LD:-$(_nix_find -name 'wasm-ld' -path '*lld-19*')}"
WASM_OPT="${LOT_WASM_OPT:-$(command -v wasm-opt 2>/dev/null || true)}"
CPP_SYSROOT="${LOT_CPP_SYSROOT:-$(_nix_find -maxdepth 1 -type d -name '*sysroot' -path '*/nix/store/*' | grep -v musl-sysroot | head -1)}"
# Fallback: known hash
[ -d "${CPP_SYSROOT:-}" ] || CPP_SYSROOT=/nix/store/0yfbk210bwhffl65fdrsr76ll7hdic8y-sysroot
MUSL_SYSROOT="${LOT_MUSL_SYSROOT:-$(_nix_find -maxdepth 1 -type d -name '*musl-sysroot')}"
BUILTINS="$MUSL_SYSROOT/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
# LLVM 19.1.7 source (pre-extracted in Nix store — used for recompiling C++ runtime objects)
LLVM_SRC="${LOT_LLVM_SRC:-$(_nix_find -maxdepth 1 -type d -name '*llvm-project*' -name '*.src*')}"
[ -d "${LLVM_SRC:-}" ] || LLVM_SRC=/nix/store/x0ylwhacc1g9myrp59j0jz6d53fnh2zx-llvm-project-19.1.7.src.tar.xz
JOBS="${LOT_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

echo "==> Toolchain"
echo "    CLANG      : $CLANG"
echo "    CLANGXX    : $CLANGXX"
echo "    LLVM_AR    : $LLVM_AR"
echo "    WASM_LD    : $WASM_LD"
echo "    WASM_OPT   : $WASM_OPT"
echo "    CPP_SYSROOT: $CPP_SYSROOT"
echo "    MUSL_SYSROOT: $MUSL_SYSROOT"
echo "    LLVM_SRC   : $LLVM_SRC"
echo "    JOBS       : $JOBS"
echo ""

[ -x "$CLANG" ]        || { echo "error: clang-19 not found"; exit 1; }
[ -x "$CLANGXX" ]      || { echo "error: clang++-19 not found"; exit 1; }
[ -x "$WASM_LD" ]      || { echo "error: wasm-ld (lld-19) not found"; exit 1; }
[ -x "$WASM_OPT" ]     || { echo "error: wasm-opt not found (brew install binaryen)"; exit 1; }
[ -d "$CPP_SYSROOT" ]  || { echo "error: C++ sysroot not found (expected: $CPP_SYSROOT)"; exit 1; }
[ -f "$BUILTINS" ]     || { echo "error: clang builtins not found at $BUILTINS"; exit 1; }

mkdir -p "$BUILD_DIR"

export PATH="$(dirname "$WASM_LD"):$PATH"

# Link-support archives built per-phase (set by build_link_support)
LIBLLVM_SUPPORT=""
LIBMUSL_STUBS=""

# ── Shared: patch libc++.a and libc++abi.a to fix atomics + WASM EH compatibility
# The sysroot libraries were compiled without -matomics/-mbulk-memory, which makes
# them incompatible with --shared-memory (required by the WASM kernel). Also need
# WASM native EH support for binaryen's try/catch usage.
#
# Strategy:
#   1. Recompile all objects with [-] shared-mem from LLVM 19.1.7 source with
#      -matomics -mbulk-memory and (for EH objects) -D__WASM_EXCEPTIONS__
#   2. Compile Unwind-wasm.c (WASM EH runtime) with -fwasm-exceptions
#   3. Replace problematic objects in archive copies
#
# Asyncify compatibility: tested OK — wasm-opt --asyncify handles EH feature fine.
patch_sysroot() {
    PATCHED_LIBCXXABI="$BUILD_DIR/libcxxabi-patched.a"
    PATCHED_LIBCXX="$BUILD_DIR/libcxx-patched.a"
    PATCH_DIR="$BUILD_DIR/sysroot-patch"
    mkdir -p "$PATCH_DIR"

    echo "==> Patching C++ sysroot (recompiling runtime objects with atomics + WASM EH)..."

    # Write a reusable compile helper script (avoids multiline-variable shell pitfalls)
    # Usage: sh $PATCH_DIR/cx.sh SRC OUT [EXTRA_FLAG...]
    cat > "$PATCH_DIR/cx.sh" << CXEOF
#!/bin/sh
SRC="\$1"; OUT="\$2"; shift 2
"$CLANGXX" \\
    -target wasm32-unknown-linux-musl \\
    --sysroot="$CPP_SYSROOT" \\
    -matomics -mbulk-memory \\
    -resource-dir "$MUSL_SYSROOT/lib/clang/19" \\
    -std=c++20 -Os -DNDEBUG \\
    -D_LIBCPP_BUILDING_LIBRARY -D_LIBCXXABI_BUILDING_LIBRARY \\
    -isystem "$CPP_SYSROOT/include/c++/v1" \\
    -I "$LLVM_SRC/libcxxabi/src" \\
    -I "$LLVM_SRC/libcxxabi/include" \\
    -I "$LLVM_SRC/libunwind/include" \\
    -I "$LLVM_SRC/libcxx/src" \\
    -I "$MUSL_SYSROOT/include/include" \\
    "\$@" -c "\$SRC" -o "\$OUT"
CXEOF
    chmod +x "$PATCH_DIR/cx.sh"

    _cobj() {
        src="$1"; out="$2"; shift 2
        printf "    %s... " "$(basename "$out")"
        sh "$PATCH_DIR/cx.sh" "$src" "$out" "$@" 2>&1 && echo "OK" || { echo "FAIL"; sh "$PATCH_DIR/cx.sh" "$src" "$out" "$@"; exit 1; }
    }

    # ── libcxxabi objects ──────────────────────────────────────────────────────
    ABILIB="$LLVM_SRC/libcxxabi/src"
    _cobj "$ABILIB/cxa_default_handlers.cpp" "$PATCH_DIR/cxa_default_handlers.cpp.o"
    # WASM EH variant: __WASM_EXCEPTIONS__ selects WASM EH code paths in cxa_exception.cpp
    _cobj "$ABILIB/cxa_exception.cpp"        "$PATCH_DIR/cxa_exception.cpp.o"       "-D__WASM_EXCEPTIONS__"
    _cobj "$ABILIB/cxa_exception_storage.cpp" "$PATCH_DIR/cxa_exception_storage.cpp.o"
    _cobj "$ABILIB/cxa_guard.cpp"            "$PATCH_DIR/cxa_guard.cpp.o"
    _cobj "$ABILIB/cxa_handlers.cpp"         "$PATCH_DIR/cxa_handlers.cpp.o"
    _cobj "$ABILIB/stdlib_stdexcept.cpp"     "$PATCH_DIR/stdlib_stdexcept.cpp.o"
    _cobj "$ABILIB/cxa_personality.cpp"      "$PATCH_DIR/cxa_personality.cpp.o"     "-D__WASM_EXCEPTIONS__"

    # ── Unwind-wasm.o: WASM EH runtime (_Unwind_RaiseException etc.) ─────────
    # Must use -fwasm-exceptions (emits WASM EH instructions via __builtin_wasm_throw)
    # thread_local kept intact — TLS works in wasm32-musl (each Worker is single-threaded)
    printf "    Unwind-wasm.o... "
    cat > "$PATCH_DIR/unwind.sh" << UWEOF
#!/bin/sh
"$CLANGXX" \\
    -target wasm32-unknown-linux-musl \\
    --sysroot="$MUSL_SYSROOT" \\
    -matomics -mbulk-memory -fwasm-exceptions \\
    -D__WASM_EXCEPTIONS__ -D_LIBUNWIND_HIDE_SYMBOLS -DNDEBUG \\
    -resource-dir "$MUSL_SYSROOT/lib/clang/19" \\
    -I "$LLVM_SRC/libunwind/include" \\
    -I "$LLVM_SRC/libunwind/src" \\
    -x c -Os \\
    -c "$LLVM_SRC/libunwind/src/Unwind-wasm.c" -o "$PATCH_DIR/Unwind-wasm.o"
UWEOF
    chmod +x "$PATCH_DIR/unwind.sh"
    sh "$PATCH_DIR/unwind.sh" 2>&1 && echo "OK" || { echo "FAIL"; exit 1; }

    # ── Patch libcxxabi.a ──────────────────────────────────────────────────────
    cp "$CPP_SYSROOT/lib/libc++abi.a" "$PATCHED_LIBCXXABI"
    for obj in cxa_default_handlers cxa_exception cxa_exception_storage cxa_guard \
               cxa_handlers stdlib_stdexcept cxa_personality; do
        "$LLVM_AR" d "$PATCHED_LIBCXXABI" "${obj}.cpp.o" 2>/dev/null || true
    done
    "$LLVM_AR" d "$PATCHED_LIBCXXABI" Unwind-wasm.o 2>/dev/null || true
    "$LLVM_AR" r "$PATCHED_LIBCXXABI" \
        "$PATCH_DIR/cxa_default_handlers.cpp.o" \
        "$PATCH_DIR/cxa_exception.cpp.o" \
        "$PATCH_DIR/cxa_exception_storage.cpp.o" \
        "$PATCH_DIR/cxa_guard.cpp.o" \
        "$PATCH_DIR/cxa_handlers.cpp.o" \
        "$PATCH_DIR/stdlib_stdexcept.cpp.o" \
        "$PATCH_DIR/cxa_personality.cpp.o" \
        "$PATCH_DIR/Unwind-wasm.o"
    echo "    patched: $(basename "$PATCHED_LIBCXXABI")"

    # ── libc++ objects ─────────────────────────────────────────────────────────
    CXXLIB="$LLVM_SRC/libcxx/src"
    _cobj "$CXXLIB/atomic.cpp"                            "$PATCH_DIR/atomic.cpp.o"
    _cobj "$CXXLIB/barrier.cpp"                           "$PATCH_DIR/barrier.cpp.o"
    _cobj "$CXXLIB/call_once.cpp"                         "$PATCH_DIR/call_once.cpp.o"
    _cobj "$CXXLIB/filesystem/directory_entry.cpp"        "$PATCH_DIR/directory_entry.cpp.o"
    _cobj "$CXXLIB/filesystem/directory_iterator.cpp"     "$PATCH_DIR/directory_iterator.cpp.o"
    _cobj "$CXXLIB/filesystem/filesystem_error.cpp"       "$PATCH_DIR/filesystem_error.cpp.o"
    _cobj "$CXXLIB/future.cpp"                            "$PATCH_DIR/future.cpp.o"
    _cobj "$CXXLIB/ios.cpp"                               "$PATCH_DIR/ios.cpp.o"
    _cobj "$CXXLIB/locale.cpp"                            "$PATCH_DIR/locale.cpp.o"
    _cobj "$CXXLIB/memory.cpp"                            "$PATCH_DIR/memory.cpp.o"
    _cobj "$CXXLIB/memory_resource.cpp"                   "$PATCH_DIR/memory_resource.cpp.o"
    _cobj "$CXXLIB/filesystem/operations.cpp"             "$PATCH_DIR/operations.cpp.o"
    _cobj "$CXXLIB/stdexcept.cpp"                         "$PATCH_DIR/stdexcept.cpp.o"
    _cobj "$CXXLIB/thread.cpp"                            "$PATCH_DIR/thread.cpp.o"

    # ── Patch libc++.a ─────────────────────────────────────────────────────────
    cp "$CPP_SYSROOT/lib/libc++.a" "$PATCHED_LIBCXX"
    for obj in atomic barrier call_once directory_entry directory_iterator \
               filesystem_error future ios locale memory memory_resource \
               operations stdexcept thread; do
        "$LLVM_AR" d "$PATCHED_LIBCXX" "${obj}.cpp.o" 2>/dev/null || true
    done
    "$LLVM_AR" r "$PATCHED_LIBCXX" \
        "$PATCH_DIR/atomic.cpp.o" \
        "$PATCH_DIR/barrier.cpp.o" \
        "$PATCH_DIR/call_once.cpp.o" \
        "$PATCH_DIR/directory_entry.cpp.o" \
        "$PATCH_DIR/directory_iterator.cpp.o" \
        "$PATCH_DIR/filesystem_error.cpp.o" \
        "$PATCH_DIR/future.cpp.o" \
        "$PATCH_DIR/ios.cpp.o" \
        "$PATCH_DIR/locale.cpp.o" \
        "$PATCH_DIR/memory.cpp.o" \
        "$PATCH_DIR/memory_resource.cpp.o" \
        "$PATCH_DIR/operations.cpp.o" \
        "$PATCH_DIR/stdexcept.cpp.o" \
        "$PATCH_DIR/thread.cpp.o"
    echo "    patched: $(basename "$PATCHED_LIBCXX")"
    echo "==> Sysroot patching done."
}

# ── Shared: LLVM support + musl stubs for binaryen link ──────────────────────────
# Needed because:
#   suffix_tree.cpp.o (in libbinaryen.a) uses llvm::SmallVector and report_bad_alloc_error
#   locale.cpp.o (in libcxx-patched.a) uses catclose (POSIX message catalogs; musl lacks them)
#   cxa_thread_atexit.cpp.o uses __cxa_thread_atexit_impl (glibc internal; musl doesn't have it)
# Call AFTER binaryen source is downloaded (needs $BINARYEN_SRC for llvm-project include path).
build_link_support() {
    LIBLLVM_SUPPORT="$BUILD_DIR/libllvm-support.a"
    LIBMUSL_STUBS="$BUILD_DIR/libmusl-stubs.a"
    echo "==> Building link support archives..."

    LLVM_TP="$BINARYEN_SRC/third_party/llvm-project"

    # Helper script (avoids multiline-variable expansion pitfalls)
    cat > "$BUILD_DIR/cxx-llvm-support.sh" << SUPPORTEOF
#!/bin/sh
exec "$CLANGXX" \\
    --target=wasm32-unknown-linux-musl \\
    --sysroot="$CPP_SYSROOT" \\
    -matomics -mbulk-memory \\
    -fwasm-exceptions \\
    -stdlib=libc++ -nostdlib++ \\
    -resource-dir "$MUSL_SYSROOT/lib/clang/19" \\
    -isystem "$CPP_SYSROOT/include/c++/v1" \\
    -isystem "$LLVM_TP/include" \\
    -Os -c "\$@"
SUPPORTEOF
    chmod +x "$BUILD_DIR/cxx-llvm-support.sh"

    printf "    SmallVector.cpp.o... "
    "$BUILD_DIR/cxx-llvm-support.sh" "$LLVM_TP/SmallVector.cpp" -o "$BUILD_DIR/SmallVector.cpp.o" 2>&1 && echo "OK" || { echo "FAIL"; exit 1; }
    printf "    ErrorHandling.cpp.o... "
    "$BUILD_DIR/cxx-llvm-support.sh" "$LLVM_TP/ErrorHandling.cpp" -o "$BUILD_DIR/ErrorHandling.cpp.o" 2>&1 && echo "OK" || { echo "FAIL"; exit 1; }
    "$LLVM_AR" rcs "$LIBLLVM_SUPPORT" "$BUILD_DIR/SmallVector.cpp.o" "$BUILD_DIR/ErrorHandling.cpp.o"
    echo "    created: $(basename "$LIBLLVM_SUPPORT")"

    # musl-stubs.c: catclose/catgets/catopen + __cxa_thread_atexit_impl
    cat > "$BUILD_DIR/musl-stubs.c" << 'STUBSEOF'
/* POSIX message catalogs: musl has no implementation */
typedef void* nl_catd;
nl_catd catopen(const char *n, int f) { (void)n; (void)f; return (nl_catd)-1; }
char *catgets(nl_catd c, int s, int m, const char *d) { (void)c; (void)s; (void)m; return (char*)d; }
int catclose(nl_catd c) { (void)c; return 0; }
/* __cxa_thread_atexit_impl: glibc internal not in musl; wasm-opt is single-threaded so safe to no-op */
int __cxa_thread_atexit_impl(void (*dtor)(void *), void *arg, void *dso) { (void)dtor; (void)arg; (void)dso; return 0; }
STUBSEOF
    printf "    musl-stubs.o... "
    "$CLANG" --target=wasm32-unknown-linux-musl --sysroot="$CPP_SYSROOT" \
        -matomics -mbulk-memory \
        -resource-dir "$MUSL_SYSROOT/lib/clang/19" \
        -Os -c "$BUILD_DIR/musl-stubs.c" -o "$BUILD_DIR/musl-stubs.o" 2>&1 && echo "OK" || { echo "FAIL"; exit 1; }
    "$LLVM_AR" rcs "$LIBMUSL_STUBS" "$BUILD_DIR/musl-stubs.o"
    echo "    created: $(basename "$LIBMUSL_STUBS")"
    echo "==> Link support archives done."
}

# ── Shared: new/delete shim (for -fno-exceptions builds only) ─────────────────
# For builds that use -fno-exceptions -fno-rtti (no libc++abi needed at all)
build_newdel_shim() {
    NEWDEL_SRC="$BUILD_DIR/cxx_newdel.cpp"
    cat > "$NEWDEL_SRC" << 'SHIMEOF'
#include <stddef.h>
#include <stdlib.h>
namespace std { struct bad_alloc {}; }
void* operator new(size_t s)              { void* p = malloc(s); if (!p) __builtin_trap(); return p; }
void* operator new[](size_t s)            { void* p = malloc(s); if (!p) __builtin_trap(); return p; }
void* operator new(size_t s, const std::bad_alloc*) noexcept { return malloc(s); }
void  operator delete(void* p)   noexcept { free(p); }
void  operator delete(void* p, size_t) noexcept { free(p); }
void  operator delete[](void* p) noexcept { free(p); }
void  operator delete[](void* p, size_t) noexcept { free(p); }
SHIMEOF
    "$CLANGXX" -target wasm32-unknown-linux-musl \
        --sysroot="$CPP_SYSROOT" \
        -matomics -mbulk-memory \
        -resource-dir "$MUSL_SYSROOT/lib/clang/19" \
        -std=c++17 -Os -fno-exceptions -fno-rtti \
        -c "$NEWDEL_SRC" -o "$BUILD_DIR/cxx_newdel.cpp.o"
}

# ── Shared: CMake toolchain file (WASM EH enabled, using patched sysroot archives)
# Call patch_sysroot first, then write_toolchain
write_toolchain() {
    PATCHED_LIBCXXABI="$BUILD_DIR/libcxxabi-patched.a"
    PATCHED_LIBCXX="$BUILD_DIR/libcxx-patched.a"
    TOOLCHAIN_FILE="$BUILD_DIR/wasm32-linux-musl.cmake"
    LINK_FLAGS="-fuse-ld=lld -static"
    LINK_FLAGS="$LINK_FLAGS -Wl,--import-memory -Wl,--export-memory -Wl,--export-table"
    LINK_FLAGS="$LINK_FLAGS -Wl,--export=__heap_base -Wl,--export=__data_end"
    LINK_FLAGS="$LINK_FLAGS -Wl,--shared-memory -Wl,--max-memory=268435456"
    LINK_FLAGS="$LINK_FLAGS -Wl,-z,stack-size=8388608"

    cat > "$TOOLCHAIN_FILE" << EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR wasm32)
set(CMAKE_C_COMPILER         "$CLANG")
set(CMAKE_CXX_COMPILER       "$CLANGXX")
set(CMAKE_ASM_COMPILER       "$CLANG")
set(CMAKE_C_COMPILER_TARGET   wasm32-unknown-linux-musl)
set(CMAKE_CXX_COMPILER_TARGET wasm32-unknown-linux-musl)
set(CMAKE_SYSROOT            "$CPP_SYSROOT")
set(CMAKE_C_COMPILER_FORCED  ON)
set(CMAKE_CXX_COMPILER_FORCED ON)
set(CMAKE_CROSSCOMPILING      ON)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
# Suppress implicit C++ library selection (clang++ would add -lstdc++ for linux target)
set(CMAKE_CXX_IMPLICIT_LINK_LIBRARIES "")
set(CMAKE_C_IMPLICIT_LINK_LIBRARIES "")
set(CMAKE_CXX_IMPLICIT_LINK_DIRECTORIES "")
# C flags: atomics+bulk-memory required for --shared-memory; resource-dir for builtins
# -include: wasm-linux-compat.h re-declares POSIX symbols excluded by #ifndef __wasm__ in musl
set(CMAKE_C_FLAGS_INIT   "-matomics -mbulk-memory -resource-dir $MUSL_SYSROOT/lib/clang/19 -include $BUILD_DIR/wasm-linux-compat.h")
# C++ flags: libc++ (not libstdc++), -nostdlib++ suppresses auto -lc++, libc++ headers explicit
# -fwasm-exceptions: use WASM native EH (asyncify-compatible, tested OK)
# binaryen uses try/catch for flow control (Precompute.cpp) so exceptions must work
set(CMAKE_CXX_FLAGS_INIT "-matomics -mbulk-memory -fwasm-exceptions -stdlib=libc++ -nostdlib++ -resource-dir $MUSL_SYSROOT/lib/clang/19 -isystem $CPP_SYSROOT/include/c++/v1 -include $BUILD_DIR/wasm-linux-compat.h")
# Linker flags for all executables
set(CMAKE_EXE_LINKER_FLAGS_INIT "$LINK_FLAGS")
# C++ standard libraries: llvm-support (for suffix_tree) + builtins + patched libc++/libc++abi + musl stubs (catclose, __cxa_thread_atexit_impl)
set(CMAKE_CXX_STANDARD_LIBRARIES "$LIBLLVM_SUPPORT $BUILTINS $PATCHED_LIBCXX $PATCHED_LIBCXXABI $LIBMUSL_STUBS")
# CRITICAL: use LLVM 19 ar/ranlib — macOS system ar creates archives wasm-ld 19 can't parse
set(CMAKE_AR     "$LLVM_AR")
set(CMAKE_RANLIB "/nix/store/9bcy8p4xf4ni3bfmzxd0ib3nljbfw6v1-llvm-19.1.7/bin/llvm-ranlib")
EOF
    echo "    toolchain: $TOOLCHAIN_FILE"
}


# ── Helper: asyncify a WASM binary ───────────────────────────────────────────────
asyncify_bin() {
    src="$1"; dst="$2"
    echo "    asyncify: $(basename "$src") → $(basename "$dst")"
    # NOTE: -O1 BEFORE --asyncify (not after). Optimization passes must run first
    # so inlining happens before asyncify instruments the call sites. If asyncify
    # runs first and then -O1 inlines instrumented functions, the rewind state
    # machines become mismatched → RuntimeError: unreachable crash during rewind.
    "$WASM_OPT" -O1 --asyncify "$src" -o "$dst"
    ls -lh "$dst"
}

# ── Helper: create apk package tarball ──────────────────────────────────────────
# Usage: make_pkg NAME VERSION BINARY_SRC INSTALL_PATH
make_pkg() {
    name="$1"; version="$2"; bin_src="$3"; install_path="$4"
    pkg_dir="$BUILD_DIR/pkg-$name"
    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir/$(dirname "$install_path")"
    cp "$bin_src" "$pkg_dir/$install_path"
    printf "name=%s\nversion=%s\nbuilt_with=wasm32-linux-musl\ntarget=wasm32-unknown-linux-musl\n" \
        "$name" "$version" > "$pkg_dir/info"
    tarball="$REPO_ROOT/packages/${name}-${version}.tar.gz"
    (cd "$pkg_dir" && tar czf "$tarball" .)
    echo "    package: $tarball ($(du -sh "$tarball" | cut -f1))"
}

# ── Phase 1: wasm-opt (binaryen) ─────────────────────────────────────────────────
build_wasm_opt() {
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Phase 1: wasm-opt (binaryen version_129)"
    echo "════════════════════════════════════════════════════"

    BINARYEN_VERSION="version_129"
    BINARYEN_SRC="$BUILD_DIR/binaryen-$BINARYEN_VERSION"
    BINARYEN_BUILD="$BUILD_DIR/binaryen-build"
    WASM_OPT_OUT="$BUILD_DIR/wasm-opt-wasm32"
    WASM_OPT_ASYNC="$BUILD_DIR/wasm-opt-wasm32.async"

    if [ ! -d "$BINARYEN_SRC" ]; then
        echo "==> Downloading binaryen $BINARYEN_VERSION..."
        curl -L "https://github.com/WebAssembly/binaryen/archive/refs/tags/$BINARYEN_VERSION.tar.gz" \
            -o "$BUILD_DIR/binaryen.tar.gz"
        tar -C "$BUILD_DIR" -xzf "$BUILD_DIR/binaryen.tar.gz"
        mv "$BUILD_DIR/binaryen-$BINARYEN_VERSION" "$BINARYEN_SRC" 2>/dev/null || true
    fi

    # Patch sysroot archives, build link support stubs, and write the cmake toolchain
    patch_sysroot
    build_link_support
    write_toolchain
    TOOLCHAIN_FILE="$BUILD_DIR/wasm32-linux-musl.cmake"

    # Patch binaryen CMakeLists: unconditionally add llvm-project includes.
    # suffix_tree.h uses llvm/Support/Allocator.h regardless of BUILD_LLVM_DWARF,
    # but the include path is only added when DWARF is on. We append it right after
    # the FP16 include line (before the first if(BUILD_LLVM_DWARF) block).
    if ! grep -q 'llvm-project.*UNCONDITIONAL' "$BINARYEN_SRC/CMakeLists.txt"; then
        # macOS sed requires a\ followed by newline for the 'a' command
        sed -i.bak '/include_directories(SYSTEM .*FP16\/include)/a\
# UNCONDITIONAL: suffix_tree.h needs llvm headers regardless of DWARF\
include_directories(SYSTEM ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llvm-project/include)' \
            "$BINARYEN_SRC/CMakeLists.txt"
    fi

    # Clean stale build dir (avoids stale cmake cache poisoning flags like -fno-exceptions)
    rm -rf "$BINARYEN_BUILD"
    mkdir -p "$BINARYEN_BUILD"
    echo "==> Configuring binaryen with cmake (via nix-shell)..."
    export PATH="$(dirname "$WASM_LD"):$PATH"
    nix-shell -p cmake ninja --run "
        cmake -S '$BINARYEN_SRC' -B '$BINARYEN_BUILD' \
            -DCMAKE_TOOLCHAIN_FILE='$TOOLCHAIN_FILE' \
            -DCMAKE_BUILD_TYPE=MinSizeRel \
            -DBUILD_TESTS=OFF \
            -DENABLE_WERROR=OFF \
            -DBUILD_STATIC_LIB=ON \
            -DCMAKE_SKIP_RPATH=ON \
            -DCMAKE_INSTALL_RPATH=. \
            -DBUILD_LLVM_DWARF=OFF \
            -DBINARYEN_ENABLE_EXCEPTION_CATCHING=OFF \
            -G Ninja 2>&1
        cmake --build '$BINARYEN_BUILD' --target wasm-opt -j$JOBS 2>&1
    "
    cp "$BINARYEN_BUILD/bin/wasm-opt" "$WASM_OPT_OUT"
    ls -lh "$WASM_OPT_OUT"

    asyncify_bin "$WASM_OPT_OUT" "$WASM_OPT_ASYNC"

    # Install to rootfs
    install -Dm755 "$WASM_OPT_ASYNC" "$REPO_ROOT/rootfs/usr/local/bin/wasm-opt"
    echo "    installed: rootfs/usr/local/bin/wasm-opt"

    # Create apk package
    make_pkg "wasm-opt" "129" "$WASM_OPT_ASYNC" "usr/local/bin/wasm-opt"
    echo "==> Phase 1 complete."
}

# ── Phase 2: wasm-ld (LLVM lld, wasm32 frontend only) ───────────────────────────
build_wasm_ld() {
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Phase 2: wasm-ld (lld 19.1.7)"
    echo "════════════════════════════════════════════════════"

    LLVM_VERSION="19.1.7"
    LLVM_PROJ="$BUILD_DIR/llvm-project-llvmorg-$LLVM_VERSION"
    LLD_BUILD="$BUILD_DIR/lld-build"
    WASM_LD_OUT="$BUILD_DIR/wasm-ld-wasm32"
    WASM_LD_ASYNC="$BUILD_DIR/wasm-ld-wasm32.async"

    # Native llvm-tblgen (host binary) needed for cross-compilation tablegen step
    NATIVE_TBLGEN="$(_nix_find -name 'llvm-tblgen' -path '*llvm-19*' ! -path '*.src*')"
    [ -x "$NATIVE_TBLGEN" ] || { echo "error: llvm-tblgen not found in Nix store"; exit 1; }
    echo "    NATIVE_TBLGEN: $NATIVE_TBLGEN"

    if [ ! -d "$LLVM_PROJ" ]; then
        echo "==> Downloading LLVM $LLVM_VERSION (~140MB)..."
        curl -L "https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-$LLVM_VERSION.tar.gz" \
            -o "$BUILD_DIR/llvm-project.tar.gz"
        tar -C "$BUILD_DIR" -xzf "$BUILD_DIR/llvm-project.tar.gz"
    fi

    # Patch sysroot and build musl stubs for locale/thread_atexit symbols.
    # Note: libllvm-support.a is NOT needed here — LLVM's cmake build compiles
    # libLLVMSupport (SmallVector etc.) for WASM32 itself as part of the build.
    patch_sysroot
    # Build musl-stubs: always rebuild (content may have changed)
    # Provides: catopen/catgets/catclose, __cxa_thread_atexit_impl (missing from musl)
    #           mmap/munmap/mprotect/madvise/fork/vfork (guarded by #ifndef __wasm__ in musl)
    LIBLLVM_SUPPORT=""    # not needed — cmake builds LLVM support libs internally
    LIBMUSL_STUBS="$BUILD_DIR/libmusl-stubs.a"
    echo "==> Building musl-stubs..."
    cat > "$BUILD_DIR/musl-stubs.c" << 'STUBSEOF'
/* POSIX message catalogs: musl has no implementation */
typedef void* nl_catd;
nl_catd catopen(const char *n, int f) { (void)n; (void)f; return (nl_catd)-1; }
char *catgets(nl_catd c, int s, int m, const char *d) { (void)c; (void)s; (void)m; return (char*)d; }
int catclose(nl_catd c) { (void)c; return 0; }
/* __cxa_thread_atexit_impl: glibc internal not in musl */
int __cxa_thread_atexit_impl(void (*dtor)(void *), void *arg, void *dso) { (void)dtor; (void)arg; (void)dso; return 0; }

/* --- wasm32-linux-musl: POSIX symbols excluded by #ifndef __wasm__ in headers ---
 * mmap: returns MAP_FAILED → forces LLVM MemoryBuffer to use read() fallback.
 * mprotect/munmap/madvise: no-op stubs (JIT memory management not needed in lld).
 * fork/vfork: return -1 (lld doesn't exec subprocesses).
 * All types are given as primitives to avoid header inclusion issues.
 */
typedef unsigned long     _stub_size_t;
typedef long long         _stub_off_t;
typedef int               _stub_pid_t;

void *mmap(void *addr, _stub_size_t len, int prot, int flags, int fd, _stub_off_t off) {
    (void)addr; (void)len; (void)prot; (void)flags; (void)fd; (void)off;
    return (void *)-1; /* MAP_FAILED — triggers LLVM MemoryBuffer read() fallback */
}
int munmap(void *addr, _stub_size_t len) { (void)addr; (void)len; return 0; }
int mprotect(void *addr, _stub_size_t len, int prot) { (void)addr; (void)len; (void)prot; return 0; }
int madvise(void *addr, _stub_size_t len, int advice) { (void)addr; (void)len; (void)advice; return 0; }
_stub_pid_t fork(void)  { return (_stub_pid_t)-1; }
_stub_pid_t vfork(void) { return (_stub_pid_t)-1; }
STUBSEOF
    "$CLANG" --target=wasm32-unknown-linux-musl --sysroot="$CPP_SYSROOT" \
        -matomics -mbulk-memory \
        -resource-dir "$MUSL_SYSROOT/lib/clang/19" \
        -Os -c "$BUILD_DIR/musl-stubs.c" -o "$BUILD_DIR/musl-stubs.o"
    "$LLVM_AR" rcs "$LIBMUSL_STUBS" "$BUILD_DIR/musl-stubs.o"
    echo "    created: libmusl-stubs.a"

    # wasm-linux-compat.h: re-declares POSIX symbols hidden by #ifndef __wasm__ in musl.
    # Force-included via -include in the cmake toolchain so all LLVM translation units see them.
    cat > "$BUILD_DIR/wasm-linux-compat.h" << 'COMPATEOF'
/* wasm-linux-compat.h — POSIX declarations for wasm32-unknown-linux-musl
 * Provides symbols excluded by musl's #ifndef __wasm__ guards.
 * Included via -include in cmake toolchain (before any source file headers).
 */
#ifndef WASM_LINUX_COMPAT_H
#define WASM_LINUX_COMPAT_H
#ifdef __wasm__
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
/* sys/mman.h constants: excluded from wasm by musl */
#ifndef MAP_SHARED
# define MAP_SHARED    0x01
# define MAP_PRIVATE   0x02
# define MAP_FIXED     0x10
# define MAP_ANON      0x20
# define MAP_ANONYMOUS MAP_ANON
# define MAP_NORESERVE 0x4000
# define MAP_GROWSDOWN 0x0100
#endif
#ifndef MAP_FAILED
# define MAP_FAILED    ((void *)-1)
#endif
#ifndef PROT_READ
# define PROT_READ  1
# define PROT_WRITE 2
# define PROT_EXEC  4
# define PROT_NONE  0
#endif
#ifndef MADV_DONTNEED
# define MADV_DONTNEED 4
#endif
/* mmap/munmap/mprotect/madvise: stubs return MAP_FAILED / 0 */
void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
int munmap(void *addr, size_t len);
int mprotect(void *addr, size_t len, int prot);
int madvise(void *addr, size_t len, int advice);
/* fork/vfork: stub returns -1 (lld does not exec subprocesses) */
pid_t fork(void);
pid_t vfork(void);
#ifdef __cplusplus
}
#endif
#endif /* __wasm__ */
#endif /* WASM_LINUX_COMPAT_H */
COMPATEOF
    echo "    created: wasm-linux-compat.h"

    write_toolchain
    TOOLCHAIN_FILE="$BUILD_DIR/wasm32-linux-musl.cmake"

    rm -rf "$LLD_BUILD"
    mkdir -p "$LLD_BUILD"
    echo "==> Configuring LLVM+lld (wasm-ld target) with cmake..."
    # Build from llvm monorepo with lld enabled. LLVM_TABLEGEN must point to
    # a native (host-arch) llvm-tblgen since we're cross-compiling to WASM32.
    nix-shell -p cmake ninja --run "
        cmake -S '$LLVM_PROJ/llvm' -B '$LLD_BUILD' \
            -DCMAKE_TOOLCHAIN_FILE='$TOOLCHAIN_FILE' \
            -DCMAKE_BUILD_TYPE=MinSizeRel \
            -DLLVM_ENABLE_PROJECTS='lld' \
            -DLLVM_TARGETS_TO_BUILD='WebAssembly' \
            -DLLVM_TABLEGEN='$NATIVE_TBLGEN' \
            -DLLVM_HOST_TRIPLE='x86_64-apple-darwin' \
            -DLLVM_DEFAULT_TARGET_TRIPLE='wasm32-unknown-linux-musl' \
            -DLLVM_INCLUDE_TESTS=OFF \
            -DLLVM_INCLUDE_EXAMPLES=OFF \
            -DLLVM_INCLUDE_BENCHMARKS=OFF \
            -DLLVM_ENABLE_ASSERTIONS=OFF \
            -DLLVM_ENABLE_TERMINFO=OFF \
            -DLLVM_ENABLE_ZLIB=OFF \
            -DLLVM_ENABLE_ZSTD=OFF \
            -DLLVM_ENABLE_LIBXML2=OFF \
            -DLLVM_BUILD_STATIC=ON \
            -DCMAKE_SKIP_RPATH=ON \
            -DCMAKE_INSTALL_RPATH=. \
            -G Ninja 2>&1
    "
    # CRITICAL: Disable HAVE_SIGALTSTACK in the generated config.h BEFORE building.
    # sigaltstack() is not asyncify-safe: every linux.syscall import is asyncifiable,
    # so CreateSigAltStack() → sigaltstack() triggers asyncify rewind into code that
    # was not instrumented → RuntimeError: unreachable in the WASM kernel guest.
    # cmake detects sigaltstack on the HOST (macOS has it), so HAVE_SIGALTSTACK=1
    # ends up in config.h. We patch it to 0 before compilation.
    config_h="$LLD_BUILD/include/llvm/Config/config.h"
    if grep -q "HAVE_SIGALTSTACK" "$config_h" 2>/dev/null; then
        # Comment out HAVE_SIGALTSTACK entirely — setting to 0 is NOT sufficient
        # because the guard is `#if defined(HAVE_SIGALTSTACK)`, which is true for
        # any defined value including 0. We must leave it undefined.
        sed -i '' 's/#define HAVE_SIGALTSTACK 1/\/\* #undef HAVE_SIGALTSTACK *\//' "$config_h"
        sed -i '' 's/#define HAVE_SIGALTSTACK 0/\/\* #undef HAVE_SIGALTSTACK *\//' "$config_h"
        echo "    patched: HAVE_SIGALTSTACK → undefined in config.h"
    fi
    nix-shell -p cmake ninja --run "
        cmake --build '$LLD_BUILD' --target lld -j$JOBS 2>&1
    "
    # Patch config.h after build too (in case cmake regenerated it) — must fully undefine
    sed -i '' 's/#define HAVE_SIGALTSTACK [01]/\/* #undef HAVE_SIGALTSTACK *\//' \
        "$LLD_BUILD/include/llvm/Config/config.h" 2>/dev/null || true
    cp "$LLD_BUILD/bin/lld" "$WASM_LD_OUT"
    asyncify_bin "$WASM_LD_OUT" "$WASM_LD_ASYNC"
    install -Dm755 "$WASM_LD_ASYNC" "$REPO_ROOT/rootfs/usr/local/bin/wasm-ld"
    make_pkg "wasm-ld" "$LLVM_VERSION" "$WASM_LD_ASYNC" "usr/local/bin/wasm-ld"
    echo "==> Phase 2 complete."
}

# ── Phase 3: clang (LLVM 19, WebAssembly backend only) ──────────────────────────
build_clang() {
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Phase 3: clang (LLVM 19.1.7, WebAssembly backend)"
    echo "════════════════════════════════════════════════════"
    echo "  NOTE: This is the largest build (~1-3 hours). Consider running"
    echo "  with LOT_JOBS=4 to avoid OOM during host compilation."

    LLVM_VERSION="19.1.7"
    LLVM_BUILD="$BUILD_DIR/llvm-build"
    LLVM_PROJ="$BUILD_DIR/llvm-project-llvmorg-$LLVM_VERSION"
    CLANG_OUT="$BUILD_DIR/clang-wasm32"
    CLANG_ASYNC="$BUILD_DIR/clang-wasm32.async"

    if [ ! -d "$LLVM_PROJ" ]; then
        echo "==> LLVM source not found — run Phase 2 first (it downloads the source)."
        exit 1
    fi

    mkdir -p "$LLVM_BUILD"
    patch_sysroot

    # musl-stubs must be built (or already exist from Phase 2) before write_toolchain
    # so LIBMUSL_STUBS is set when the cmake toolchain file is generated.
    LIBLLVM_SUPPORT=""
    LIBMUSL_STUBS="$BUILD_DIR/libmusl-stubs.a"
    if [ ! -f "$LIBMUSL_STUBS" ]; then
        echo "==> musl-stubs.a not found — building (run Phase 2 first to avoid this)..."
        cat > "$BUILD_DIR/musl-stubs.c" << 'STUBSEOF'
typedef void* nl_catd;
nl_catd catopen(const char *n, int f) { (void)n; (void)f; return (nl_catd)-1; }
char *catgets(nl_catd c, int s, int m, const char *d) { (void)c; (void)s; (void)m; return (char*)d; }
int catclose(nl_catd c) { (void)c; return 0; }
int __cxa_thread_atexit_impl(void (*dtor)(void *), void *arg, void *dso) { (void)dtor; (void)arg; (void)dso; return 0; }
typedef unsigned long _stub_size_t; typedef long long _stub_off_t; typedef int _stub_pid_t;
void *mmap(void *a, _stub_size_t l, int p, int f, int fd, _stub_off_t o) { (void)a;(void)l;(void)p;(void)f;(void)fd;(void)o; return (void*)-1; }
int munmap(void *a, _stub_size_t l) { (void)a;(void)l; return 0; }
int mprotect(void *a, _stub_size_t l, int p) { (void)a;(void)l;(void)p; return 0; }
int madvise(void *a, _stub_size_t l, int adv) { (void)a;(void)l;(void)adv; return 0; }
_stub_pid_t fork(void)  { return (_stub_pid_t)-1; }
_stub_pid_t vfork(void) { return (_stub_pid_t)-1; }
STUBSEOF
        "$CLANG" --target=wasm32-unknown-linux-musl --sysroot="$CPP_SYSROOT" \
            -matomics -mbulk-memory -resource-dir "$MUSL_SYSROOT/lib/clang/19" \
            -Os -c "$BUILD_DIR/musl-stubs.c" -o "$BUILD_DIR/musl-stubs.o"
        "$LLVM_AR" rcs "$LIBMUSL_STUBS" "$BUILD_DIR/musl-stubs.o"
        echo "    created: libmusl-stubs.a"
    fi

    write_toolchain
    TOOLCHAIN_FILE="$BUILD_DIR/wasm32-linux-musl.cmake"

    # Native tblgen binaries required for cross-compilation
    NATIVE_TBLGEN="$(_nix_find -name 'llvm-tblgen' -path '*llvm-19*' ! -path '*.src*')"
    [ -x "$NATIVE_TBLGEN" ] || { echo "error: llvm-tblgen not found in Nix store"; exit 1; }
    # clang-tblgen lives in llvm-tblgen-19.x packages (not llvm-19.x), search broadly
    NATIVE_CLANG_TBLGEN="$(_nix_find -name 'clang-tblgen' -path '*tblgen-19*' ! -path '*.src*' | head -1)"
    [ -x "$NATIVE_CLANG_TBLGEN" ] || \
        NATIVE_CLANG_TBLGEN="$(_nix_find -name 'clang-tblgen' ! -path '*.src*' ! -path '*wrapper*' | head -1)"
    [ -x "$NATIVE_CLANG_TBLGEN" ] || { echo "error: clang-tblgen not found in Nix store"; exit 1; }
    echo "    NATIVE_TBLGEN:       $NATIVE_TBLGEN"
    echo "    NATIVE_CLANG_TBLGEN: $NATIVE_CLANG_TBLGEN"

    echo "==> Configuring clang (WASM backend only) with cmake..."
    nix-shell -p cmake ninja --run "
        cmake -S '$LLVM_PROJ/llvm' -B '$LLVM_BUILD' \
            -DCMAKE_TOOLCHAIN_FILE='$TOOLCHAIN_FILE' \
            -DCMAKE_BUILD_TYPE=MinSizeRel \
            -DLLVM_ENABLE_PROJECTS='clang;lld' \
            -DLLVM_TARGETS_TO_BUILD='WebAssembly' \
            -DLLVM_TABLEGEN='$NATIVE_TBLGEN' \
            -DCLANG_TABLEGEN='$NATIVE_CLANG_TBLGEN' \
            -DLLVM_HOST_TRIPLE='x86_64-apple-darwin' \
            -DLLVM_DEFAULT_TARGET_TRIPLE='wasm32-unknown-linux-musl' \
            -DLLVM_INCLUDE_TESTS=OFF \
            -DLLVM_INCLUDE_EXAMPLES=OFF \
            -DLLVM_INCLUDE_BENCHMARKS=OFF \
            -DLLVM_ENABLE_ASSERTIONS=OFF \
            -DLLVM_ENABLE_TERMINFO=OFF \
            -DLLVM_ENABLE_ZLIB=OFF \
            -DLLVM_ENABLE_ZSTD=OFF \
            -DLLVM_ENABLE_LIBXML2=OFF \
            -DLLVM_BUILD_STATIC=ON \
            -DCLANG_ENABLE_ARCMT=OFF \
            -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
            -DCLANG_BUILD_TOOLS=ON \
            -DLLVM_BUILD_LLVM_DYLIB=OFF \
            -DCMAKE_SKIP_RPATH=ON \
            -DCMAKE_INSTALL_RPATH=. \
            -G Ninja 2>&1
    "
    # CRITICAL: Disable HAVE_SIGALTSTACK before building.
    # cmake detects sigaltstack on the macOS HOST → HAVE_SIGALTSTACK=1 in config.h.
    # The guard is `#if defined(HAVE_SIGALTSTACK)` — setting to 0 is NOT enough,
    # must fully comment out so the macro is undefined.
    _llvm_config_h="$LLVM_BUILD/include/llvm/Config/config.h"
    if grep -q "HAVE_SIGALTSTACK" "$_llvm_config_h" 2>/dev/null; then
        sed -i '' 's/#define HAVE_SIGALTSTACK [01]/\/\* #undef HAVE_SIGALTSTACK *\//' "$_llvm_config_h"
        echo "    patched: HAVE_SIGALTSTACK → undefined in $LLVM_BUILD config.h"
    fi
    echo "==> Building clang..."
    nix-shell -p cmake ninja --run "
        cmake --build '$LLVM_BUILD' --target clang -j$JOBS 2>&1
    "
    # Re-patch in case cmake regenerated config.h during build
    sed -i '' 's/#define HAVE_SIGALTSTACK [01]/\/\* #undef HAVE_SIGALTSTACK *\//' \
        "$_llvm_config_h" 2>/dev/null || true
    cp "$LLVM_BUILD/bin/clang" "$CLANG_OUT"
    asyncify_bin "$CLANG_OUT" "$CLANG_ASYNC"
    install -Dm755 "$CLANG_ASYNC" "$REPO_ROOT/rootfs/usr/local/bin/clang"
    ln -sf clang "$REPO_ROOT/rootfs/usr/local/bin/cc"
    ln -sf clang "$REPO_ROOT/rootfs/usr/local/bin/clang-19"
    make_pkg "clang" "$LLVM_VERSION" "$CLANG_ASYNC" "usr/local/bin/clang"
    echo "==> Phase 3 complete."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────────
for phase in $PHASES; do
    case "$phase" in
        1) build_wasm_opt ;;
        2) build_wasm_ld ;;
        3) build_clang ;;
        *) echo "Unknown phase: $phase (valid: 1, 2, 3)"; exit 1 ;;
    esac
done

echo ""
echo "==> Done. Binaries installed to rootfs/usr/local/bin/"
echo "    Run ./build-rootfs.sh to rebuild rootfs.ext4."
