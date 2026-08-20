#!/usr/bin/env bash
# Build zsh 5.9 for the wasm guest, static (no dynamic modules), installed as
# /bin/zsh. Uses the native wasm-EH setjmp/longjmp lowering (zsh leans heavily
# on setjmp/longjmp + fork, which only compose under wasm-EH — see build-ash.sh
# and [[wasm-kernel-async-fixes]]) plus the dynamic fork thunk. Reuses the
# ncurses static libs built by the nano recipe.
set -e
REPO=/Users/kilian/.ai/LinuxOnTab-kernel
W=/tmp/lot-zsh
CLANG=/opt/homebrew/opt/llvm@19/bin/clang
LLVM=/opt/homebrew/opt/llvm@19/bin
SYS=$REPO/toolchain/musl-sysroot-fixed
CRT1="$SYS/lib/crt1.o"
BUILTINS="$SYS/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
WASM_OPT=/opt/homebrew/bin/wasm-opt
NCURSES=/tmp/lot-build/nano-ncurses-prefix
AR="$LLVM/llvm-ar"; RANLIB="$LLVM/llvm-ranlib"
export PATH="$LLVM:$PATH"

[ -f "$NCURSES/usr/lib/libncursesw.a" ] || { echo "ERROR: build nano recipe first for ncurses ($NCURSES)"; exit 1; }
[ -d "$W" ] || { echo "ERROR: extract zsh to $W first"; exit 1; }
cd "$W"

# wasm call_indirect signature fix — zsh registers two ZERO-arg functions
# (accept_last, invalidate_list) as 2-arg Hookfn. Harmless on x86/ARM, fatal
# on wasm32: the first ZLE widget dispatch traps ("function signature
# mismatch" => SIGSEGV), so every interactive zsh died right after printing
# its prompt. See toolchain/patches/zsh-5.9-wasm-call-indirect.py.
python3 "$REPO/toolchain/patches/zsh-5.9-wasm-call-indirect.py"

# fork thunk + wasm-EH sjlj runtime (runtime MUST be built with the sjlj pass).
"$CLANG" -target wasm32 --sysroot="$SYS" -O2 -matomics -mbulk-memory \
    -c "$REPO/sysroot/wasm_fork.c" -o "$W/wasm_fork.o"
"$CLANG" -target wasm32 --sysroot="$SYS" -O2 -matomics -mbulk-memory \
    -mexception-handling -mllvm -wasm-enable-sjlj \
    -c "$REPO/sysroot/sjlj_rt_wasmeh.c" -o "$W/sjlj_rt.o"

# musl wasm sysroot guards fork/vfork behind #ifndef __wasm__.
printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n' > "$W/zsh-fork.h"

CC_BASE="$CLANG -target wasm32 --sysroot=$SYS -fuse-ld=lld -include $W/zsh-fork.h -matomics -mbulk-memory -mexception-handling -mllvm -wasm-enable-sjlj"
export CC="$CC_BASE"
export CPP="$CLANG -target wasm32 --sysroot=$SYS -E"
export AR RANLIB
export CFLAGS="-O2 -I$NCURSES/usr/include -I$NCURSES/usr/include/ncursesw -D_GNU_SOURCE"
export CPPFLAGS="-I$NCURSES/usr/include -I$NCURSES/usr/include/ncursesw"
# Link tests + final link need crt1 + fork/sjlj runtime + libc, AND the guest
# memory ABI: the kernel provides a shared, growable memory that the fork
# mechanism copies — the binary MUST import it (--import-memory --shared-memory
# --max-memory), not build its own internal memory. Omitting these gave zsh a
# private non-shared initial=138 memory, so the fork child (a fresh shared
# copy) didn't match and asyncify_start_rewind read bufPtr past the child's
# smaller memory => "memory access out of bounds". Same flags ash uses.
export LDFLAGS="-nostdlib -static -L$NCURSES/usr/lib \
  -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
  -Wl,--export=__heap_base -Wl,--export=__data_end \
  -Wl,--shared-memory -Wl,--max-memory=268435456 \
  -Wl,-z,stack-size=8388608"
export LIBS="$W/wasm_fork.o $W/sjlj_rt.o -lncursesw -ltinfo $CRT1 -lc -lm $BUILTINS"

# ── Cross-compile cache: zsh runs many AC_TRY_RUN probes it can't execute for
#    a wasm target. Preset the answers (values from known zsh cross recipes,
#    adjusted for our no-NIS/no-dynamic musl guest). Iterate as configure
#    reveals more. ─────────────────────────────────────────────────────────
export zsh_cv_shared_environ=yes
export zsh_cv_sys_nis=no
export zsh_cv_sys_nis_plus=no
export zsh_cv_sys_fifos_broken=no
export zsh_cv_sys_named_fds=yes
export zsh_cv_sys_path_dev_fd=/proc/self/fd
export zsh_cv_sys_getpwnam_faked=no
export zsh_cv_sys_getpwuid_faked=no
export zsh_cv_func_tgetent_accepts_null=yes
export zsh_cv_func_tgetent_zero_success=yes
export zsh_cv_sys_elf=yes
export zsh_cv_sys_signals_use_sigaction=yes
export zsh_cv_c_variable_length_arrays=yes
export ac_cv_func_malloc_0_nonnull=yes
export ac_cv_func_realloc_0_nonnull=yes
export ac_cv_func_mmap_fixed_mapped=no
export ac_cv_func_mbrtowc=yes
export ac_cv_func_wcwidth=yes
export zsh_cv_sys_tcsetpgrp=yes
# Force HAVE_SELECT: our kernel has select/pselect6, but zsh's autodetect left
# it undef, and with HAVE_POLL-but-not-HAVE_SELECT zsh miscompiles — zle_main.c
# references `cost` (defined in zle_refresh.c only under HAVE_SELECT) => link
# error `undefined symbol: cost`. Both work in the guest; poll still wins at
# runtime (zle_main prefers HAVE_POLL).
export ac_cv_func_select=yes
export ac_cv_header_sys_select_h=yes

echo "==> configure"
./configure \
    --host=wasm32-unknown-linux-musl \
    --prefix=/usr \
    --disable-dynamic \
    --disable-restricted-r \
    --enable-multibyte \
    --disable-gdbm \
    2>&1 | tail -45

echo "==> configure done — inspect config.log on failure"

# ── after configure ────────────────────────────────────────────────────────
#   make -j4
#   wasm-opt --asyncify -O1 -g Src/zsh -o $REPO/rootfs/bin/zsh
# Keep -g: it preserves the name section, which is what turns a wasm trap
# stack into named frames (that is how the Hookfn mismatch above was found).
# Then swap into the image with debugfs, per [[linuxontab-guest-debug]].
