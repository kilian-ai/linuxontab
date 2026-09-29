#!/bin/sh
# Build the thread/fork shim regression tests (see README.md) against the
# fixed musl sysroot. Output: $OUT/{tlsprobe,tlsprobe-big,tlsprobe-ng16,forktls,
# threadstacks,vforktls} with the current sysroot/ shims, and *-old controls linked
# with the shims as of $OLD_REV (before these fixes) for a before/after run.
#   sh local/thread-shims/build.sh [outdir]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$HERE/out}"
OLD_REV="${OLD_REV:-61b7dde}"   # last commit before the shims got these fixes
CLANG=/opt/homebrew/opt/llvm@19/bin/clang
SYSROOT="$REPO/toolchain/musl-sysroot-fixed"
CRT1="$SYSROOT/lib/crt1.o"
BUILTINS="$SYSROOT/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
CC="$CLANG -target wasm32 --sysroot=$SYSROOT"
CFLAGS="-O2 -matomics -mbulk-memory"
LDFLAGS="-nostdlib -static -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
  -Wl,--export=__heap_base -Wl,--export=__data_end -Wl,--shared-memory \
  -Wl,--max-memory=268435456 -Wl,-z,stack-size=1048576"
O="$OUT/obj"; mkdir -p "$O/old"

for f in wasm_clone wasm_fork wasm_dlmalloc wasm_dlmalloc_mt; do
  $CC $CFLAGS -w -c "$REPO/sysroot/$f.c" -o "$O/$f.o"
done
# controls: the shims as of $OLD_REV (no _mt variant there; the old
# wasm_dlmalloc.c is what ffmpeg7 links today, threads and all)
for f in wasm_clone wasm_fork wasm_dlmalloc; do
  git -C "$REPO" show "$OLD_REV:sysroot/$f.c" > "$O/old/$f.c"
done
cp "$REPO/sysroot/dlmalloc.c" "$O/old/"
for f in wasm_clone wasm_fork wasm_dlmalloc; do
  $CC $CFLAGS -w -c "$O/old/$f.c" -o "$O/old/$f.o"
done

$CC $CFLAGS -c "$HERE/tlsprobe.c" -o "$O/tlsprobe.o"
$CC $CFLAGS -DBIG -c "$HERE/tlsprobe.c" -o "$O/tlsprobe-big.o"
$CC $CFLAGS -DSTACK=16777216 -c "$HERE/tlsprobe.c" -o "$O/tlsprobe-16m.o"
$CC $CFLAGS -c "$HERE/forktls.c" -o "$O/forktls.o"
$CC $CFLAGS -c "$HERE/threadstacks.c" -o "$O/threadstacks.o"
$CC $CFLAGS -c "$HERE/vforktls.c" -o "$O/vforktls.o"

link() {  # link <out> <objs...>   (shims BEFORE libc so they override it)
  out="$1"; shift
  $CC -fuse-ld=lld $CFLAGS $LDFLAGS "$CRT1" "$@" -lc -lm "$BUILTINS" -o "$OUT/$out"
}
link tlsprobe       "$O/wasm_dlmalloc_mt.o" "$O/wasm_clone.o" "$O/tlsprobe.o"
link tlsprobe-big   "$O/wasm_dlmalloc_mt.o" "$O/wasm_clone.o" "$O/tlsprobe-big.o"
# python3's configuration: musl mallocng (no dlmalloc), 16 MB thread stacks.
# EXPECTED TO FAIL: mallocng traps in pthread_create (see README.md)
link tlsprobe-ng16  "$O/wasm_clone.o" "$O/tlsprobe-16m.o"
link threadstacks   "$O/wasm_dlmalloc_mt.o" "$O/wasm_clone.o" "$O/threadstacks.o"
link vforktls       "$O/wasm_dlmalloc_mt.o" "$O/wasm_clone.o" "$O/vforktls.o"
link forktls.raw    "$O/wasm_dlmalloc.o" "$O/wasm_fork.o" "$O/forktls.o"
link tlsprobe-old     "$O/wasm_dlmalloc_mt.o" "$O/old/wasm_clone.o" "$O/tlsprobe.o"
link threadstacks-old "$O/old/wasm_dlmalloc.o" "$O/old/wasm_clone.o" "$O/threadstacks.o"
link vforktls-old    "$O/wasm_dlmalloc_mt.o" "$O/old/wasm_clone.o" "$O/vforktls.o"
link forktls-old.raw  "$O/old/wasm_dlmalloc.o" "$O/old/wasm_fork.o" "$O/forktls.o"
for f in forktls forktls-old; do
  wasm-opt --asyncify -O1 "$OUT/$f.raw" -o "$OUT/$f" && rm "$OUT/$f.raw"
done
chmod +x "$OUT"/tlsprobe* "$OUT"/threadstacks* "$OUT"/forktls* "$OUT"/vforktls*
ls -l "$OUT" | grep -v obj
