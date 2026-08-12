#!/usr/bin/env bash
# Build an ASH-ONLY busybox for the wasm guest, installed as /bin/ash.
#
# ash was impossible on this port until now: busybox gates CONFIG_ASH on
# !NOMMU because ash needs a real fork() (hush gets by with vfork/clone
# tricks). The asyncify fork thunk (sysroot/wasm_fork.c, commit ab72592)
# provides exactly that — fork() with copied memory — so this build uses an
# MMU config (CONFIG_NOMMU unset) and links the thunk BEFORE libc so ash's
# fork()/vfork() resolve to it. Modeled on build-hush-tick.sh.
set -e
REPO=/Users/kilian/.ai/LinuxOnTab-kernel
SRC=/nix/store/pi1mxz9962avhkd24csbrzyw1cswv7hc-tombl-busybox-master
WORK=/tmp/lot-ash-build
CLANG=$(find /nix/store -maxdepth 3 -path "*/bin/clang" ! -path "*wrapper*" 2>/dev/null | grep clang-19 | sort | head -1)
SYSROOT=$REPO/toolchain/musl-sysroot-fixed
BUILTINS=$(find "$SYSROOT/lib/clang" -name "libclang_rt.builtins.a" 2>/dev/null | head -1)
LLVM_AR=$(find /nix/store -maxdepth 3 -name llvm-ar -path "*llvm-19*" 2>/dev/null | sort | head -1)
LLDBIN=$(dirname "$(find /nix/store -maxdepth 3 -name wasm-ld -path '*lld-19*' 2>/dev/null | head -1)")
WASM_OPT=/opt/homebrew/bin/wasm-opt
export PATH="$LLDBIN:$PATH"
CRT1="$SYSROOT/lib/crt1.o"

rm -rf "$WORK"; mkdir -p "$WORK"; cp -R "$SRC/." "$WORK/"; chmod -R u+w "$WORK"; cd "$WORK"
find . -name "*.S" -delete   # x86 asm, useless on wasm
sed -i.bak "/hash_sha1_x86-64.o/d; /hash_sha1_hwaccel_x86/d; /hash_sha256_hwaccel_x86/d" libbb/Kbuild.src

# musl wasm sysroot guards fork/vfork decls behind #ifndef __wasm__;
# wasm_fork.c provides the definitions at link time.
printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n' > /tmp/ash-fork.h
# NATIVE WASM-EH setjmp/longjmp (-mexception-handling -mllvm -wasm-enable-sjlj):
# ash's control flow lives on setjmp/longjmp (raise_exception longjmps for
# exit/errors/EOF). The emscripten JS-exception SjLj does NOT compose with
# asyncify (fork): a longjmp raised in a fork child, re-raised across a
# pre-fork handler, was mis-dispatched and ash subshells fell through
# (re-executing the parent script). The wasm-EH lowering uses native
# try/catch/throw/rethrow — ordinary wasm control flow asyncify understands —
# so it composes. Runtime: sysroot/sjlj_rt_wasmeh.c (__wasm_setjmp[_test] +
# __wasm_longjmp throwing the __c_longjmp tag). NO JS imports (worker.js
# untouched). See local/sched-debug/sjljfork2.c + [[wasm-kernel-async-fixes]].
CC_WASM="$CLANG -target wasm32 --sysroot=$SYSROOT -fuse-ld=lld -include /tmp/ash-fork.h -matomics -mbulk-memory -mexception-handling -mllvm -wasm-enable-sjlj"

# allnoconfig = everything OFF, then enable only what ash needs.
# NOTE: CONFIG_NOMMU deliberately NOT set — ash depends on !NOMMU and the
# whole point is to use the real fork() the thunk provides.
make HOSTCC=cc allnoconfig >/tmp/ash-cfg.log 2>&1
en(){ grep -v "^$1=" .config | grep -v "^# $1 is not set" > .c && mv .c .config; echo "$1=y" >> .config; }
for o in CONFIG_ASH CONFIG_SH_IS_ASH CONFIG_ASH_INTERNAL_GLOB \
         CONFIG_ASH_BASH_COMPAT CONFIG_ASH_JOB_CONTROL CONFIG_ASH_ALIAS \
         CONFIG_ASH_RANDOM_SUPPORT CONFIG_ASH_EXPAND_PRMT \
         CONFIG_ASH_ECHO CONFIG_ASH_PRINTF CONFIG_ASH_TEST CONFIG_ASH_GETOPTS \
         CONFIG_ASH_CMDCMD \
         CONFIG_FEATURE_SH_MATH CONFIG_FEATURE_SH_MATH_64 \
         CONFIG_FEATURE_EDITING CONFIG_FEATURE_EDITING_MAX_LEN \
         CONFIG_FEATURE_EDITING_HISTORY CONFIG_FEATURE_TAB_COMPLETION \
         CONFIG_PLATFORM_LINUX CONFIG_LFS CONFIG_FEATURE_BUFFERS_USE_MALLOC; do en "$o"; done
dis(){ grep -v "^$1=" .config | grep -v "^# $1 is not set" > .c && mv .c .config; echo "# $1 is not set" >> .config; }
for o in CONFIG_SHA1_HWACCEL CONFIG_SHA256_HWACCEL CONFIG_SHA1_SMALL CONFIG_SHA3_SMALL CONFIG_NOMMU; do dis "$o"; done
yes "" | make HOSTCC=cc oldconfig >/tmp/ash-cfg2.log 2>&1 || true
echo "ASH=$(grep -c '^CONFIG_ASH=y' .config) SH_IS_ASH=$(grep -c '^CONFIG_SH_IS_ASH=y' .config) NOMMU=$(grep -c '^CONFIG_NOMMU=y' .config)"
grep -q '^CONFIG_ASH=y' .config || { echo "ERROR: CONFIG_ASH did not survive oldconfig (NOMMU gate?)"; exit 1; }

# Build objects; busybox's own trylink fails for exotic targets — link manually.
make -j"$(sysctl -n hw.logicalcpu)" CC="$CC_WASM" HOSTCC=cc LD="$LLDBIN/wasm-ld" \
     AR="$LLVM_AR" SKIP_STRIP=y busybox >/tmp/ash-make.log 2>/tmp/ash-make.err || true
echo "=== objs: $(find . -name 'built-in.o' | wc -l) built-in.o, lib.a: $(find . -name 'lib.a' | wc -l)"
grep -nE "fatal error:|error:" /tmp/ash-make.err 2>/dev/null | grep -viE "warning|note:" | head -8 || true

echo "==> compile wasm_fork.c (dynamic thunk) + sjlj_rt_wasmeh.c (wasm-EH longjmp runtime)"
"$CLANG" -target wasm32 --sysroot="$SYSROOT" -fuse-ld=lld -O2 -matomics -mbulk-memory \
    -c "$REPO/sysroot/wasm_fork.c" -o /tmp/ash-wasm-fork.o
# The runtime MUST be built with the sjlj pass so __builtin_wasm_throw(1,...)
# resolves the __c_longjmp tag (index 1) instead of a weak-undefined symbol.
"$CLANG" -target wasm32 --sysroot="$SYSROOT" -fuse-ld=lld -O2 -matomics -mbulk-memory \
    -mexception-handling -mllvm -wasm-enable-sjlj \
    -c "$REPO/sysroot/sjlj_rt_wasmeh.c" -o /tmp/ash-sjlj-rt.o

echo "==> manual link"
BUILTIN_OBJS=$(find . -name 'built-in.o' | sort)
LIBS_A=$(find . -name 'lib.a' | sort)
"$CLANG" -target wasm32 --sysroot="$SYSROOT" -fuse-ld=lld \
    -nostdlib -static \
    -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
    -Wl,--export=__heap_base -Wl,--export=__data_end \
    -Wl,--shared-memory -Wl,--max-memory=268435456 \
    -Wl,-z,stack-size=1048576 \
    "$CRT1" /tmp/ash-wasm-fork.o /tmp/ash-sjlj-rt.o $BUILTIN_OBJS $LIBS_A -lc -lm "$BUILTINS" \
    -o ash.raw
ls -la ash.raw

echo "==> asyncify -O1 (--enable-exception-handling so asyncify keeps the wasm try/catch/throw)"
"$WASM_OPT" --enable-exception-handling --asyncify -O1 ash.raw -o ash.wasm
wasm-objdump -x ash.wasm | grep -q asyncify_start_unwind || { echo "ERROR: asyncify exports missing"; exit 1; }
wasm-objdump -x ash.wasm | grep -q '<- env.memory' || { echo "ERROR: does not import env.memory"; exit 1; }
echo "==> magic check (dyn fork ABI)"
wasm-objdump -d ash.wasm | grep -c 1179603531 || true

# rootfs/bin/ash historically was a symlink to busybox — remove it first so
# cp doesn't write THROUGH the symlink onto the load-bearing busybox binary.
rm -f "$REPO/rootfs/bin/ash"
cp ash.wasm "$REPO/rootfs/bin/ash"
chmod +x "$REPO/rootfs/bin/ash"
ls -la "$REPO/rootfs/bin/ash"
echo "done: $REPO/rootfs/bin/ash (install into rootfs.ext4 via debugfs or build-rootfs.sh)"
