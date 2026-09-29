#!/bin/sh
# Recipe: zsh — the Z shell 5.9, static, as /bin/zsh.
#
# The guest's /bin/sh is busybox hush on a no-MMU kernel. It cannot fork,
# so it runs children by re-parsing function definitions from saved text,
# which drops heredoc bodies: any function containing a heredoc fails in a
# pipeline or $(...) ("syntax error: unexpected EOF in here document"). The
# lean image's hush also lacks $(...) assignments. zsh uses the kernel's
# asyncify fork (sysroot/wasm_fork.c), so children are real copies and
# ordinary POSIX scripts just work: `zsh --emulate sh script`, or zsh run
# under the name `sh`. The claw package runs on it.
#
# Packages the committed, already-asyncified rootfs/bin/zsh — the binary the
# full image has shipped since commit 1871791, built by local/build-zsh.sh
# (zsh 5.9, wasm-EH setjmp/longjmp, fork thunk, the call_indirect patch in
# toolchain/patches/zsh-5.9-wasm-call-indirect.py). A from-source recipe
# built with the package toolchain fails nested command substitution; it is
# parked in local/zsh-recipe-from-source.sh until that difference is found.

NAME="zsh"
VERSION="5.9"
DESCRIPTION="Z shell 5.9 — also a POSIX sh for scripts busybox hush can't run (zsh --emulate sh)"
SOURCE_URL="local:"
NO_ASYNCIFY=1   # rootfs/bin/zsh is already asyncified

build() {
    Z="$REPO_ROOT/rootfs/bin/zsh"
    # the binary committed in 1871791; refuse anything else
    [ "$(shasum -a 256 "$Z" | cut -d' ' -f1)" = "deb06e1afeb07b696dfa8bc2ba4c5c8519c887803ce0d711d64f8ced6e3354b0" ] \
        || { echo "zsh: rootfs/bin/zsh is not the expected binary" >&2; exit 1; }
    mkdir -p "$STAGE/bin"
    install -m755 "$Z" "$STAGE/bin/zsh"
}
