#!/bin/sh
# Recipe: lua — Lightweight scripting language
# Builds the Lua 5.4 interpreter as a standalone WASM binary.
#
# Lua uses setjmp/longjmp for error handling — asyncify handles this correctly.
# The readline interface is disabled (uses basic line input instead).

NAME="lua"
VERSION="5.4.7"
DESCRIPTION="Lightweight embeddable scripting language"
SOURCE_URL="https://www.lua.org/ftp/lua-5.4.7.tar.gz"
SOURCE_SHA256="9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30"

build() {
    # Build a conservative stdlib set for WASM guest stability.
    # package/io/os/debug pull in heavier host-integration paths that can
    # trigger runtime crashes in this environment.
    sed -i '' '/LUA_LOADLIBNAME/d; /LUA_IOLIBNAME/d; /LUA_OSLIBNAME/d; /LUA_DBLIBNAME/d' src/linit.c

    # Lua's Makefile uses MYCFLAGS / MYLDFLAGS / MYLIBS for extra flags.
    # LUAI_MAXSTACK reduced: default stack is smaller in WASM.
    make -C src \
        CC="$CC" \
        AR="$AR rcs" \
        RANLIB="$RANLIB" \
        MYCFLAGS="$CFLAGS -DLUA_USE_C89" \
        MYLDFLAGS="$LDFLAGS" \
        MYLIBS="$CRT1 -lc -lm $BUILTINS" \
        -j4 lua

    install -Dm755 src/lua "$STAGE/bin/lua"
}
