#!/usr/bin/env bash
# build-busybox.sh — rebuild the guest's /bin/busybox (rootfs/bin/busybox).
#
# Replays the tombl/distro Nix derivation (busybox.drv: same source, same
# config, same toolchain store paths) outside Nix, against
# toolchain/musl-sysroot-fixed (all the musl fixes: alloc_meta, brk page
# units, pthread zeroed TLS, binary128 long double), plus the hush NOMMU pipe
# fix (toolchain/patches/busybox-hush-nommu-pipe-next-infd.patch), then
# asyncifies it (the kernel's fork/blocking-syscall protocol).
#
#   toolchain/build-busybox.sh            -> $OUT (default: scratch dir)/busybox
#   OUT=rootfs/bin toolchain/build-busybox.sh   to replace the rootfs copy
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${LOT_BUSYBOX_SRC:-/nix/store/pi1mxz9962avhkd24csbrzyw1cswv7hc-tombl-busybox-master}"
CLANG_BIN="${LOT_CLANG_BIN:-/nix/store/sa4f4iaw4zmkdnfiidjpys8dlgkzridc-clang/bin}"
HOSTCC="${LOT_HOSTCC:-/nix/store/5zadg9qqj8s598nxqfqsk8xn9z4axdi3-clang-wrapper-19.1.7/bin/clang}"
MAKE_BIN="${LOT_MAKE_BIN:-/nix/store/308q7v3aaiw4d1wjijy7xcszlgnfadb6-gnumake-4.4.1/bin}"
LLD_BIN="${LOT_LLD_BIN:-/nix/store/hi5jf8kppa6mz32pqawjq7wm6pvn1nhn-lld-19.1.7/bin}"
LLVM_BIN="${LOT_LLVM_BIN:-/nix/store/9bcy8p4xf4ni3bfmzxd0ib3nljbfw6v1-llvm-19.1.7/bin}"
COMPAT_BIN="${LOT_COMPAT_BIN:-/nix/store/lw9hjmjr9fym9xs5sxnx8i7h8lmh5s2k-busybox-compat/bin}"
LINUX_HEADERS="${LOT_LINUX_HEADERS:-/nix/store/k9lpm468z5y66dclgqs8hvv6402mlv3f-linux-headers}"
SYSROOT="${LOT_SYSROOT:-$REPO_ROOT/toolchain/musl-sysroot-fixed}"
WASM_OPT="${LOT_WASM_OPT:-$(command -v wasm-opt)}"
WORK="${LOT_BUSYBOX_WORK:-/tmp/lot-busybox-build}"
OUT="${OUT:-$WORK/out}"

for p in "$SRC" "$CLANG_BIN" "$HOSTCC" "$MAKE_BIN" "$LLD_BIN" "$LLVM_BIN" "$COMPAT_BIN" "$LINUX_HEADERS" "$SYSROOT" "$WASM_OPT"; do
    [ -e "$p" ] || { echo "Error: missing input: $p (set LOT_* overrides)"; exit 1; }
done

rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"
cp -R "$SRC" "$WORK/src"; chmod -R u+w "$WORK/src"; cd "$WORK/src"
patch -p1 < "$REPO_ROOT/toolchain/patches/busybox-hush-nommu-pipe-next-infd.patch"

# the derivation's PATH, with its GNU sed/coreutils ahead of the host's
export PATH="$CLANG_BIN:$MAKE_BIN:$LLD_BIN:$LLVM_BIN:$COMPAT_BIN:/usr/bin:/bin"   # host last: cmp, diff (stdenv's diffutils)
NCPU="$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || nproc)"
mk() {
  make -j"$NCPU" ARCH=wasm32 HOSTCC="$HOSTCC" CC="$CLANG_BIN/clang" \
    CFLAGS_busybox="-Wl,--import-memory -Wl,--max-memory=4294967296 -Wl,--shared-memory -Wl,--export-table" "$@"
}
config() {
  sed -i "/CONFIG_$1=/d" .config
  sed -i "/CONFIG_$1 is not set/d" .config
  case $2 in
    y|n) echo "CONFIG_$1=$2" >> .config ;;
    *) echo "CONFIG_$1=\"$2\"" >> .config ;;
  esac
}
mk defconfig > "$WORK/config.log"
config STATIC y
config NOMMU y
config STATIC_LIBGCC n
config CROSS_COMPILER_PREFIX llvm-
config SYSROOT "$SYSROOT"
config EXTRA_CFLAGS "-I$LINUX_HEADERS/include  -matomics -mbulk-memory"
config EXTRA_LDLIBS c
config MOUNT y
config SWITCH_ROOT y
config HUSH y
config SH_IS_ASH n
config SH_IS_HUSH y
config SH_IS_NONE n
config BASH_IS_ASH n
config BASH_IS_HUSH n
config BASH_IS_NONE y
for o in BOOTCHARTD CONSPY CROND CRONTAB DEVMEM FBSPLASH FTPD HDPARM HEXEDIT HTTPD IFDOWN IFUP \
         INETD NC NSENTER SCRIPT START_STOP_DAEMON SWAPOFF SWAPON TCPSVD TELNETD TIME TS UDPSVD WGET \
         SENDMAIL REFORMIME MAKEMIME POPMAILDIR INIT LINUXRC RUNSV RUNSVDIR SVLOGD HUSH_TICK \
         HWCLOCK RTCWAKE; do
  config "$o" n
done
yes "" | mk oldconfig >> "$WORK/config.log" 2>&1 || true
mk > "$WORK/make.log" 2>&1 || { tail -30 "$WORK/make.log"; exit 1; }

# the musl fixes must be in: no hardcoded-0x8000 alloc_meta
python3 - busybox << 'PY'
import sys
d = open(sys.argv[1], 'rb').read()
if d.count(bytes.fromhex('417f460d03418080022102')):
    sys.exit("ERROR: busybox linked an unfixed libc (alloc_meta 0x8000)")
PY
"$WASM_OPT" --enable-exception-handling --asyncify -O1 busybox -o "$OUT/busybox"
chmod 755 "$OUT/busybox"
ls -la "$OUT/busybox"
