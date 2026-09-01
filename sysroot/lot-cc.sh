#!/bin/sh
# lot-cc.sh — cc wrapper for autoconf-style cross builds on wasm32-musl.
#
# Compile steps pass straight through. Link steps (no -c/-S/-E/-M) get the
# full wasm link line appended: LDFLAGS, any extra objects in LOT_LINK_OBJS
# (fork thunk, mmap shim, ld128 compat …), then crt1 + libc + builtins, so
# every configure probe and every Makefile link target resolves the same way
# without threading LIBS through a dozen build files.
#
# Expects the build-package.sh env: CLANG SYSROOT CFLAGS LDFLAGS CRT1 BUILTINS
# (plus optional LOT_LINK_OBJS, LOT_LINK_LIBS). Generate a bound copy with:
#   sed "s|@CLANG@|$CLANG|; ..." — or simpler, export the vars and use as-is.
set -e
: "${LOT_CLANG_BIN:?}" "${LOT_SYSROOT_DIR:?}"
link=1
for a in "$@"; do
    case "$a" in
        -c|-S|-E|-M|-MM|--version|-v|-V|-dumpversion|-qversion|-print-*) link=0 ;;
    esac
done
if [ $link = 0 ]; then
    exec "$LOT_CLANG_BIN" -target wasm32 --sysroot="$LOT_SYSROOT_DIR" -fuse-ld=lld "$@"
fi
# shellcheck disable=SC2086
exec "$LOT_CLANG_BIN" -target wasm32 --sysroot="$LOT_SYSROOT_DIR" -fuse-ld=lld "$@" \
    $LOT_LDFLAGS $LOT_LINK_OBJS "$LOT_CRT1" -lc -lm $LOT_LINK_LIBS "$LOT_BUILTINS"
