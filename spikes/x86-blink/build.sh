#!/bin/sh
# Spike: build Blink (jart/blink, x86-64 Linux user-mode emulator, ISC) as a
# wasm32 guest binary. Output: $OUT/blink (asyncified, fork enabled).
#   sh spikes/x86-blink/build.sh [outdir]
#   THREADS=1 sh spikes/x86-blink/build.sh [outdir]   # guest clone()/pthreads
#   MODE= THREADS=1 sh spikes/x86-blink/build.sh [outdir]  # debug: blink -s / -L
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
 -Wl,--export=__heap_base -Wl,--export=__data_end -Wl,--shared-memory -Wl,--max-memory=1073741824 \
 -Wl,-z,stack-size=8388608 -Wl,--table-base=2"
# --table-base=2: a signal handler at function-table index 1 is SIG_IGN to the
# kernel (a SIGCHLD handler there makes children auto-reap: waitpid -> ECHILD)
printf '#!/bin/sh\nexec %s --format=gnu "$@"\n' "$LLVM_AR" > "$W/bin/ar"; chmod +x "$W/bin/ar"
export CC="$REPO/sysroot/lot-cc.sh" AR="$W/bin/ar"

# shims: the sysroot's (clone with per-thread/vfork TLS + the
# __lot_clone_sets_sp marker, fork restoring the child's globals, sbrk-only
# dlmalloc that also serves musl's internal __libc_malloc; _mt = locked) and
# the spike's own malloc-backed mmap for Blink's nolinear mode. Needs a 7.1
# runtime with SA_SIGINFO compat (6e583e7): the old lot_sigaction.c wrapper
# kept handlers in a global table, which a vfork child (shared memory) clobbered
# when it reset its handlers before exec, so the parent lost SIGCHLD.
for f in wasm_dlmalloc wasm_dlmalloc_mt wasm_ld128 wasm_clone wasm_fork; do
  $CC1 $CFLAGS0 -w -c "$REPO/sysroot/$f.c" -o "$W/objs/$f.o"
done
for f in lot_mmap; do
  $CC1 $CFLAGS0 -w -c "$HERE/$f.c" -o "$W/objs/$f.o"
done
O="$W/objs"
if [ "${THREADS:-0}" = 1 ]; then
  MALLOC="$O/wasm_dlmalloc_mt.o"; THREADFLAG=""
else
  MALLOC="$O/wasm_dlmalloc.o"; THREADFLAG="--disable-threads"
fi
export LOT_LINK_OBJS="$MALLOC $O/wasm_ld128.o $O/wasm_clone.o $O/wasm_fork.o $O/lot_mmap.o"

[ -d "$W/blink" ] || git clone -q https://github.com/jart/blink.git "$W/blink"
cd "$W/blink"
git checkout -q "$BLINK_REV" && git checkout -q -- .
# blink-lot.patch: 1 MB host stacks for guest threads (musl's 128 KB default is
# tight for the asyncified interpreter) and LOT_VFORK, guest vfork/fork as a
# shared-memory host clone(CLONE_VM|CLONE_VFORK) (see the patch comment)
git apply "$HERE/blink-lot.patch"
# configure RUNS its probes; cross-compiling, "it linked" is the answer
sed -i '' 's|     run "o/tool/config/${RUNPROGRAM}"; then|     test -f "o/tool/config/${RUNPROGRAM}"; then|' configure
rm -rf o && mkdir -p o/tool && cc -o o/tool/flock tool/flock.c   # host tool
./configure CC="$CC" AR="$AR" CFLAGS="$CFLAGS0 -g0" --disable-jit $THREADFLAG --static >/dev/null 2>&1
sed -i '' 's|^// #define HAVE_FORK|#define HAVE_FORK|' config.h   # probe can't see our fork decl
sed -i '' "s|^CPPFLAGS = |CPPFLAGS = -DLOT_VFORK -DLOT_SYSCALLS -include $HERE/lot_mman.h |; s|^LDFLAGS = .*|LDFLAGS = -static|; s|^LDLIBS = .*|LDLIBS = -lm|" config.mk
# MODE=rel by default; MODE= (empty) builds Blink's debug mode, with the
# syscall tracer (blink -s) and logging (blink -L file)
MODE="${MODE-rel}"
rm -rf "o/$MODE/blink"
gmake -j10 MODE="$MODE" "o/$MODE/blink/blink"
wasm-opt --enable-exception-handling --asyncify -O3 "o/$MODE/blink/blink" -o "$OUT/blink"
chmod +x "$OUT/blink"
ls -la "$OUT/blink"
