#!/usr/bin/env bash
# Build a HUSH-ONLY busybox with command substitution (HUSH_TICK) enabled.
# The guest's current hush lacks HUSH_TICK, so $() parse-errors — this rebuild
# fixes that. Hush-only = tiny build surface (no coreutils/mail/console applets
# that hit missing linux headers); clawlite calls those via the existing busybox.
set -e
REPO=/Users/kilian/.ai/LinuxOnTab-kernel
SRC=/nix/store/pi1mxz9962avhkd24csbrzyw1cswv7hc-tombl-busybox-master
WORK=/tmp/lot-hush-build
CLANG=$(find /nix/store -maxdepth 3 -path "*/bin/clang" ! -path "*wrapper*" 2>/dev/null | grep clang-19 | sort | head -1)
SYSROOT=$REPO/toolchain/musl-sysroot-fixed
BUILTINS=$(find "$SYSROOT/lib/clang" -name "libclang_rt.builtins.a" 2>/dev/null | head -1)
LLVM_AR=$(find /nix/store -maxdepth 3 -name llvm-ar -path "*llvm-19*" 2>/dev/null | sort | head -1)
LLDBIN=$(dirname "$(find /nix/store -maxdepth 3 -name wasm-ld -path '*lld-19*' 2>/dev/null | head -1)")
export PATH="$LLDBIN:$PATH"
CRT1="$SYSROOT/lib/crt1.o"

rm -rf "$WORK"; mkdir -p "$WORK"; cp -R "$SRC/." "$WORK/"; chmod -R u+w "$WORK"; cd "$WORK"
patch -p1 < "$REPO/toolchain/patches/busybox-hush-nommu-pipe-next-infd.patch" >/dev/null 2>&1 || true
find . -name "*.S" -delete   # x86 asm, useless on wasm
sed -i.bak "/hash_sha1_x86-64.o/d; /hash_sha1_hwaccel_x86/d; /hash_sha256_hwaccel_x86/d" libbb/Kbuild.src   # x86 hash asm not buildable on wasm
python3 /tmp/hush-patch.py shell/hush.c
printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n#define xvfork vfork\n' > /tmp/hush-fork.h
CC_WASM="$CLANG -target wasm32 --sysroot=$SYSROOT -fuse-ld=lld -include /tmp/hush-fork.h"

# allnoconfig = everything OFF, then enable only what hush needs.
make HOSTCC=cc allnoconfig >/tmp/hush-cfg.log 2>&1
en(){ grep -v "^$1=" .config | grep -v "^# $1 is not set" > .c && mv .c .config; echo "$1=y" >> .config; }
for o in CONFIG_HUSH CONFIG_SH_IS_HUSH CONFIG_HUSH_TICK CONFIG_HUSH_BASH_COMPAT \
         CONFIG_HUSH_BRACE_EXPANSION CONFIG_HUSH_INTERACTIVE CONFIG_HUSH_SAVEHISTORY \
         CONFIG_HUSH_JOB CONFIG_HUSH_TICK_DEPRECATED CONFIG_HUSH_IF CONFIG_HUSH_LOOPS \
         CONFIG_HUSH_CASE CONFIG_HUSH_FUNCTIONS CONFIG_HUSH_LOCAL CONFIG_HUSH_RANDOM_SUPPORT \
         CONFIG_HUSH_EXPORT CONFIG_HUSH_EXPORT_N CONFIG_HUSH_READONLY CONFIG_HUSH_KILL \
         CONFIG_HUSH_WAIT CONFIG_HUSH_TRAP CONFIG_HUSH_TYPE CONFIG_HUSH_TIMES \
         CONFIG_HUSH_READ CONFIG_HUSH_SET CONFIG_HUSH_UNSET CONFIG_HUSH_ECHO \
         CONFIG_HUSH_PRINTF CONFIG_HUSH_TEST CONFIG_HUSH_HELP CONFIG_HUSH_EXPORT_N \
         CONFIG_HUSH_GETOPTS CONFIG_HUSH_MEMLEAK CONFIG_HUSH_UMASK CONFIG_HUSH_COMMAND \
         CONFIG_FEATURE_SH_MATH CONFIG_FEATURE_SH_MATH_64 \
         CONFIG_FEATURE_EDITING CONFIG_FEATURE_EDITING_MAX_LEN \
         CONFIG_PLATFORM_LINUX CONFIG_NOMMU CONFIG_LFS CONFIG_FEATURE_BUFFERS_USE_MALLOC; do en "$o"; done
dis(){ grep -v "^$1=" .config | grep -v "^# $1 is not set" > .c && mv .c .config; echo "# $1 is not set" >> .config; }
for o in CONFIG_SHA1_HWACCEL CONFIG_SHA256_HWACCEL CONFIG_SHA1_SMALL CONFIG_SHA3_SMALL; do dis "$o"; done
yes "" | make HOSTCC=cc oldconfig >/tmp/hush-cfg2.log 2>&1 || true
echo "TICK=$(grep -c '^CONFIG_HUSH_TICK=y' .config) HUSH=$(grep -c '^CONFIG_HUSH=y' .config) SH_IS_HUSH=$(grep -c '^CONFIG_SH_IS_HUSH=y' .config)"

# Build objects (busybox's own trylink often fails for exotic targets, so we
# build objects then link manually).
make -j"$(sysctl -n hw.logicalcpu)" CC="$CC_WASM" HOSTCC=cc LD="$LLDBIN/wasm-ld" \
     AR="$LLVM_AR" SKIP_STRIP=y busybox >/tmp/hush-make.log 2>/tmp/hush-make.err || true
echo "=== objs: $(find . -name '*.o' | wc -l)"
echo "=== busybox built by make? ==="; ls -la busybox busybox_unstripped 2>/dev/null
echo "=== errors:"; grep -nE "fatal error:|undefined symbol|error:|Error [0-9]" /tmp/hush-make.err 2>/dev/null | grep -viE "warning|note:" | head -12
