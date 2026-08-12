#!/bin/sh
# Rebuild OpenSSH sshd for LinuxOnTab WASM kernel and enable daemon mode.
#
# Usage:
#   ./local/rebuild-sshd-wasm.sh /path/to/openssh-portable-src
#
# Optional env overrides:
#   LOT_CLANG, LOT_SYSROOT, LOT_WASM_LD, LOT_WASM_OPT

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/openssh-source" >&2
    exit 1
fi

SRC_DIR="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_BIN="$REPO_ROOT/rootfs/sbin/sshd"
ENABLE_MARKER="$REPO_ROOT/rootfs/etc/ssh/sshd-daemon.enabled"
ZLIB_BOOTSTRAP="$REPO_ROOT/local/bootstrap-wasm-zlib.sh"
WASM_FORK_SRC="$REPO_ROOT/sysroot/wasm_fork.c"

[ -d "$SRC_DIR" ] || { echo "error: source dir not found: $SRC_DIR" >&2; exit 1; }
[ -f "$SRC_DIR/configure" ] || { echo "error: expected configure in $SRC_DIR" >&2; exit 1; }
[ -f "$WASM_FORK_SRC" ] || { echo "error: missing wasm fork shim: $WASM_FORK_SRC" >&2; exit 1; }

find_one() {
    find /nix/store -maxdepth 3 "$@" 2>/dev/null | sort | head -1
}

find_llvm_tool() {
  tool_name="$1"
  p="$(find /nix/store -maxdepth 3 -name "$tool_name" -path '*llvm-19*' 2>/dev/null | sort | head -1)"
  [ -n "$p" ] || p="$(find /nix/store -maxdepth 3 -name "$tool_name" 2>/dev/null | sort | head -1)"
  [ -n "$p" ] || p="$(command -v "$tool_name" 2>/dev/null || true)"
  printf '%s\n' "$p"
}

CLANG="${LOT_CLANG:-}"
SYSROOT="${LOT_SYSROOT:-}"
WASM_LD="${LOT_WASM_LD:-}"
WASM_OPT="${LOT_WASM_OPT:-}"

[ -n "$CLANG" ] || CLANG="$(find_one -path '*/bin/clang' | head -1)"
[ -n "$SYSROOT" ] || SYSROOT="$(find /nix/store -maxdepth 1 -type d -name '*musl-sysroot' 2>/dev/null | sort | head -1)"
[ -n "$WASM_LD" ] || WASM_LD="$(find_one -path '*/bin/wasm-ld')"
[ -n "$WASM_OPT" ] || WASM_OPT="$(command -v wasm-opt 2>/dev/null || true)"

[ -x "${CLANG:-}" ] || { echo "error: clang not found (set LOT_CLANG)" >&2; exit 1; }
[ -d "${SYSROOT:-}" ] || { echo "error: musl sysroot not found (set LOT_SYSROOT)" >&2; exit 1; }
[ -x "${WASM_LD:-}" ] || { echo "error: wasm-ld not found (set LOT_WASM_LD)" >&2; exit 1; }
[ -x "${WASM_OPT:-}" ] || { echo "error: wasm-opt not found (set LOT_WASM_OPT or install binaryen)" >&2; exit 1; }

ZLIB_PREFIX="${LOT_WASM_ZLIB_PREFIX:-$HOME/.cache/linuxontab/wasm-zlib}"
if [ ! -f "$ZLIB_PREFIX/include/zlib.h" ] || [ ! -f "$ZLIB_PREFIX/lib/libz.a" ]; then
  [ -x "$ZLIB_BOOTSTRAP" ] || { echo "error: missing zlib bootstrap script: $ZLIB_BOOTSTRAP" >&2; exit 1; }
  LOT_CLANG="$CLANG" LOT_SYSROOT="$SYSROOT" LOT_WASM_ZLIB_PREFIX="$ZLIB_PREFIX" "$ZLIB_BOOTSTRAP"
fi

[ -f "$ZLIB_PREFIX/include/zlib.h" ] || { echo "error: zlib header missing after bootstrap: $ZLIB_PREFIX/include/zlib.h" >&2; exit 1; }
[ -f "$ZLIB_PREFIX/lib/libz.a" ] || { echo "error: zlib archive missing after bootstrap: $ZLIB_PREFIX/lib/libz.a" >&2; exit 1; }

WASM_LD_DIR="$(dirname "$WASM_LD")"
export PATH="$WASM_LD_DIR:$PATH"

CRT1="$SYSROOT/lib/crt1.o"
BUILTINS="$SYSROOT/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
[ -f "$BUILTINS" ] || BUILTINS="$(find "$SYSROOT/lib/clang" -name 'libclang_rt.builtins.a' -path '*/wasm32-unknown-linux-musl/*' 2>/dev/null | head -1)"
[ -f "$BUILTINS" ] || BUILTINS=""

echo "==> toolchain"
echo "    CLANG   : $CLANG"
echo "    SYSROOT : $SYSROOT"
echo "    WASM_LD : $WASM_LD"
echo "    WASM_OPT: $WASM_OPT"

cd "$SRC_DIR"

if [ -f Makefile ]; then
    make distclean >/dev/null 2>&1 || true
fi

export CC="$CLANG -target wasm32 --sysroot=$SYSROOT -fuse-ld=lld"
export AR="$(find_llvm_tool llvm-ar)"
export RANLIB="$(find_llvm_tool llvm-ranlib)"

COMMON_CFLAGS="-O2 -matomics -mbulk-memory"
COMMON_LDFLAGS="-nostdlib -static \
  -Wl,--import-memory \
  -Wl,--export-memory \
  -Wl,--export-table \
  -Wl,--export=__heap_base \
  -Wl,--export=__data_end \
  -Wl,--shared-memory \
  -Wl,--max-memory=268435456"

export CFLAGS="$COMMON_CFLAGS"
export CPPFLAGS="-I$ZLIB_PREFIX/include"
export LDFLAGS="-L$ZLIB_PREFIX/lib $COMMON_LDFLAGS"
export LIBS="${CRT1} $ZLIB_PREFIX/lib/libz.a -lc -lm ${BUILTINS}"

echo "==> configure openssh"
./configure \
  --host=wasm32-unknown-linux-musl \
  --prefix=/usr \
  --sysconfdir=/etc/ssh \
  --libexecdir=/usr/local/libexec \
  --disable-security-key \
  --with-zlib="$ZLIB_PREFIX" \
  --without-openssl \
  --without-pam \
  --without-kerberos5 \
  --without-zlib-version-check

# WASM target: disable XMSS code paths that expect mmap semantics.
if [ -f config.h ]; then
    tmp_cfg="/tmp/openssh-config.h.$$"
    sed -e 's/^#define WITH_XMSS .*/\/\* #undef WITH_XMSS \*\//' \
        -e 's/^#define WITH_XMSS_FAST .*/\/\* #undef WITH_XMSS_FAST \*\//' \
        config.h > "$tmp_cfg"
    mv "$tmp_cfg" config.h
fi

if [ -f Makefile ]; then
  tmp_mk="/tmp/openssh-makefile.$$"
  awk '
    BEGIN {skip=0}
    /^XMSS_OBJS=\\/ {print "XMSS_OBJS="; skip=1; next}
    skip==1 {
      if ($0 ~ /^[ \t]/) next
      skip=0
    }
    {print}
  ' Makefile > "$tmp_mk"
  mv "$tmp_mk" Makefile
fi

"$CLANG" -target wasm32 --sysroot="$SYSROOT" -fuse-ld=lld -O2 -matomics -mbulk-memory -c "$WASM_FORK_SRC" -o lot_wasm_fork.o
export LIBS="lot_wasm_fork.o $LIBS"

if [ -f Makefile ]; then
  tmp_mk2="/tmp/openssh-makefile-link.$$"
  awk '
    /^sshd\$\(EXEEXT\):/ {
      if ($0 !~ /lot_wasm_fork\.o/) $0 = $0 " lot_wasm_fork.o"
      print
      next
    }
    /^\t\$\(LD\) -o \$@ \$\(SSHDOBJS\)/ {
      if ($0 !~ /lot_wasm_fork\.o/) sub(/\$\(SSHDOBJS\)/, "$(SSHDOBJS) lot_wasm_fork.o")
      print
      next
    }
    { print }
  ' Makefile > "$tmp_mk2"
  mv "$tmp_mk2" Makefile
fi

if [ -f includes.h ]; then
  tmp_inc="/tmp/openssh-includes.h.$$"
  awk '
    BEGIN {inserted=0}
    {
      print
      if (!inserted && $0 ~ /^#include <sys\/types.h>/) {
        print "#ifndef HAVE_FORK_DECL"
        print "pid_t fork(void);"
        print "#define HAVE_FORK_DECL 1"
        print "#endif"
        inserted=1
      }
    }
  ' includes.h > "$tmp_inc"
  mv "$tmp_inc" includes.h
fi

if [ -f sshkey.c ]; then
  tmp_keyc="/tmp/openssh-sshkey.c.$$"
  perl -0777 -pe 's@static int\nsshkey_prekey_alloc\(u_char \*\*prekeyp, size_t len\)\n\{.*?\n\}\n\nstatic void\nsshkey_prekey_free\(void \*prekey, size_t len\)\n\{.*?\n\}@static int\nsshkey_prekey_alloc(u_char **prekeyp, size_t len)\n{\n\tu_char *prekey;\n\n\t*prekeyp = NULL;\n\tif ((prekey = calloc(1, len)) == NULL)\n\t\treturn SSH_ERR_ALLOC_FAIL;\n\t*prekeyp = prekey;\n\treturn 0;\n}\n\nstatic void\nsshkey_prekey_free(void *prekey, size_t len)\n{\n\t(void)len;\n\tfreezero(prekey, len);\n}@s' sshkey.c > "$tmp_keyc"
  mv "$tmp_keyc" sshkey.c
fi

if [ -f readpass.c ]; then
  tmp_rp="/tmp/openssh-readpass.c.$$"
  awk '
    BEGIN {inserted=0}
    {
      print
      if (!inserted && $0 ~ /^#include <unistd.h>/) {
        print "#ifndef HAVE_FORK_DECL"
        print "pid_t fork(void);"
        print "#define HAVE_FORK_DECL 1"
        print "#endif"
        inserted=1
      }
    }
  ' readpass.c > "$tmp_rp"
  mv "$tmp_rp" readpass.c
fi

if [ -f misc.c ]; then
  tmp_misc="/tmp/openssh-misc.c.$$"
  awk '
    BEGIN {inserted=0}
    {
      print
      if (!inserted && $0 ~ /^#include <unistd.h>/) {
        print "#ifndef HAVE_FORK_DECL"
        print "pid_t fork(void);"
        print "#define HAVE_FORK_DECL 1"
        print "#endif"
        print ""
        print "#if !defined(PROT_READ) || !defined(MAP_PRIVATE) || !defined(MAP_FAILED)"
        print "#ifndef PROT_READ"
        print "#define PROT_READ 0"
        print "#endif"
        print "#ifndef MAP_PRIVATE"
        print "#define MAP_PRIVATE 0"
        print "#endif"
        print "#ifndef MAP_FAILED"
        print "#define MAP_FAILED ((void *)-1)"
        print "#endif"
        print "static void *lot_mmap_fallback(void *addr, size_t length, int prot, int flags, int fd, off_t offset)"
        print "{"
        print "\tvoid *p;"
        print "\tssize_t n;"
        print "\t(void)addr; (void)prot; (void)flags;"
        print "\tif (lseek(fd, offset, SEEK_SET) == (off_t)-1)"
        print "\t\treturn MAP_FAILED;"
        print "\tp = malloc(length);"
        print "\tif (p == NULL)"
        print "\t\treturn MAP_FAILED;"
        print "\tn = read(fd, p, length);"
        print "\tif (n < 0 || (size_t)n != length) {"
        print "\t\tfree(p);"
        print "\t\treturn MAP_FAILED;"
        print "\t}"
        print "\treturn p;"
        print "}"
        print "static int lot_munmap_fallback(void *addr, size_t length)"
        print "{"
        print "\t(void)length;"
        print "\tfree(addr);"
        print "\treturn 0;"
        print "}"
        print "#define mmap lot_mmap_fallback"
        print "#define munmap lot_munmap_fallback"
        print "#endif"
        inserted=1
      }
    }
  ' misc.c > "$tmp_misc"
  mv "$tmp_misc" misc.c
fi

echo "==> build sshd"
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" sshd

echo "==> asyncify sshd"
tmp_async="/tmp/sshd.asyncified.wasm"
"$WASM_OPT" --asyncify -O1 sshd -o "$tmp_async"

echo "==> verify import-memory"
if ! command -v wasm-objdump >/dev/null 2>&1; then
    echo "error: wasm-objdump not found (install wabt)" >&2
    exit 1
fi

mem_report="$(wasm-objdump -x "$tmp_async" | grep -i 'memory' || true)"
echo "$mem_report" | grep -q '<- env.memory' || {
    echo "error: rebuilt sshd does not import env.memory" >&2
    echo "hint: ensure --import-memory is present in final link flags" >&2
    exit 1
}

echo "==> verify asyncify exports"
exp_report="$(wasm-objdump -x "$tmp_async" | grep -E 'asyncify_start_unwind|asyncify_start_rewind|asyncify_get_state' || true)"
echo "$exp_report" | grep -q 'asyncify_start_unwind' || {
    echo "error: asyncify exports missing" >&2
    exit 1
}

echo "==> install"
cp "$tmp_async" "$OUT_BIN"
chmod +x "$OUT_BIN"
printf '%s\n' "enabled-by: local/rebuild-sshd-wasm.sh" > "$ENABLE_MARKER"

echo "done: installed $OUT_BIN"
echo "done: enabled daemon marker $ENABLE_MARKER"
echo "next: ./build-rootfs.sh"
