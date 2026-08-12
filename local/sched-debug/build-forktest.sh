#!/bin/sh
# Build forktest against the fixed musl sysroot, linked with the NEW dynamic
# fork thunk (sysroot/wasm_fork.c), then asyncify. Install to /usr/local/bin.
set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLANG=/opt/homebrew/opt/llvm@19/bin/clang
SYSROOT="$REPO/toolchain/musl-sysroot-fixed"
WASM_OPT=/opt/homebrew/bin/wasm-opt
CRT1="$SYSROOT/lib/crt1.o"
BUILTINS="$SYSROOT/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
FORK_SRC="$REPO/sysroot/wasm_fork.c"
OUT="$REPO/local/sched-debug"

CFLAGS="-O2 -matomics -mbulk-memory -pthread"
LDFLAGS="-nostdlib -static \
  -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
  -Wl,--export=__heap_base -Wl,--export=__data_end \
  -Wl,--shared-memory -Wl,--max-memory=268435456"

echo "==> compile wasm_fork.c"
"$CLANG" -target wasm32 --sysroot="$SYSROOT" -fuse-ld=lld $CFLAGS -c "$FORK_SRC" -o "$OUT/wasm_fork.o"

echo "==> compile forktest.c"
"$CLANG" -target wasm32 --sysroot="$SYSROOT" -fuse-ld=lld $CFLAGS -c "$OUT/forktest.c" -o "$OUT/forktest.o"

echo "==> link (fork thunk BEFORE libc so it overrides musl fork/vfork)"
"$CLANG" -target wasm32 --sysroot="$SYSROOT" -fuse-ld=lld $CFLAGS $LDFLAGS \
  "$CRT1" "$OUT/wasm_fork.o" "$OUT/forktest.o" -lc -lm "$BUILTINS" \
  -o "$OUT/forktest.raw"

echo "==> asyncify"
"$WASM_OPT" --asyncify -O1 "$OUT/forktest.raw" -o "$OUT/forktest"

echo "==> verify asyncify exports"
wasm-objdump -x "$OUT/forktest" | grep -E 'asyncify_start_unwind|asyncify_start_rewind|asyncify_get_state' \
  || { echo "ERROR: asyncify exports missing"; exit 1; }

ls -l "$OUT/forktest"
echo "OK: $OUT/forktest"
