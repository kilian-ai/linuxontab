#!/bin/sh
# Spike: build Blink (jart/blink, x86-64 Linux user-mode emulator, ISC) as a
# wasm32 guest binary. Output: $OUT/blink (asyncified, fork enabled).
#   sh spikes/x86-blink/build.sh [outdir]
# Needs the same toolchain as packages/build-package.sh (Nix clang/lld 19,
# toolchain/musl-sysroot-fixed, binaryen wasm-opt, gmake).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:-/tmp/lot-build/blink-spike}"
BLINK_REV=f006a4f
W="$OUT/work"; mkdir -p "$W/objs" "$W/bin"

CLANG=$(find /nix/store -maxdepth 3 -path "*/bin/clang" ! -path "*wrapper*" 2>/dev/null | grep clang-19 | sort | head -1)
WASM_LD=$(find /nix/store -maxdepth 3 -path "*/bin/wasm-ld" 2>/dev/null | sort | head -1)
LLVM_AR=$(find /nix/store -maxdepth 3 -name llvm-ar -path "*llvm-19*" 2>/dev/null | sort | head -1)
SYSROOT="$REPO/toolchain/musl-sysroot-fixed"
export PATH="$(dirname "$WASM_LD"):$W/bin:$PATH"
CFLAGS0="-O2 -matomics -mbulk-memory"
CC1="$CLANG -target wasm32 --sysroot=$SYSROOT"
export LOT_CLANG_BIN="$CLANG" LOT_SYSROOT_DIR="$SYSROOT" LOT_CRT1="$SYSROOT/lib/crt1.o" \
       LOT_BUILTINS="$SYSROOT/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
export LOT_LDFLAGS="-nostdlib -static -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
 -Wl,--export=__heap_base -Wl,--export=__data_end -Wl,--shared-memory -Wl,--max-memory=268435456 \
 -Wl,-z,stack-size=8388608"
printf '#!/bin/sh\nexec %s --format=gnu "$@"\n' "$LLVM_AR" > "$W/bin/ar"; chmod +x "$W/bin/ar"
export CC="$REPO/sysroot/lot-cc.sh" AR="$W/bin/ar"

# shims: lot_sbrk FIRST (overrides musl's broken sbrk), then the usual objects
for f in wasm_dlmalloc wasm_ld128 wasm_clone wasm_fork; do
  $CC1 $CFLAGS0 -w -c "$REPO/sysroot/$f.c" -o "$W/objs/$f.o"
done
for f in lot_sbrk lot_mmap lot_sigaction; do
  $CC1 $CFLAGS0 -c "$HERE/$f.c" -o "$W/objs/$f.o"
done
O="$W/objs"
export LOT_LINK_OBJS="$O/lot_sbrk.o $O/wasm_dlmalloc.o $O/wasm_ld128.o $O/wasm_clone.o $O/wasm_fork.o $O/lot_mmap.o $O/lot_sigaction.o"

[ -d "$W/blink" ] || git clone -q https://github.com/jart/blink.git "$W/blink"
cd "$W/blink"
git checkout -q "$BLINK_REV" && git checkout -q -- configure
# configure RUNS its probes; cross-compiling, "it linked" is the answer
sed -i '' 's|     run "o/tool/config/${RUNPROGRAM}"; then|     test -f "o/tool/config/${RUNPROGRAM}"; then|' configure
rm -rf o && mkdir -p o/tool && cc -o o/tool/flock tool/flock.c   # host tool
./configure CC="$CC" AR="$AR" CFLAGS="$CFLAGS0 -g0" --disable-jit --disable-threads --static >/dev/null 2>&1
sed -i '' 's|^// #define HAVE_FORK|#define HAVE_FORK|' config.h   # probe can't see our fork decl
sed -i '' "s|^CPPFLAGS = |CPPFLAGS = -include $HERE/lot_mman.h |; s|^LDFLAGS = .*|LDFLAGS = -static -Wl,--wrap=sigaction|; s|^LDLIBS = .*|LDLIBS = -lm|" config.mk
gmake -j10 MODE=rel o/rel/blink/blink
wasm-opt --enable-exception-handling --asyncify -O3 o/rel/blink/blink -o "$OUT/blink"
chmod +x "$OUT/blink"
ls -la "$OUT/blink"
