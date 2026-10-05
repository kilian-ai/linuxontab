# Native (arm64 Linux, 64-bit host) Blink with the LinuxOnTab patches, for fast
# repros in Docker: docker run --platform linux/arm64 -v $SCRATCH:/w alpine:3.20 sh /w/rebuild.sh
# (/w/blink = patched Blink tree, output /w/bl/blink)
set -e
apk add -q build-base git python3 linux-headers zlib-dev procps >/dev/null 2>&1
cd /w/blink && ./configure CFLAGS="-O2 -DLOT_SYSCALLS" >/w/configure.log 2>&1
make -j8 o//blink/blink >/w/make.log 2>&1 || { grep -E "error" /w/make.log | head; exit 1; }
cp o//blink/blink /w/bl/blink && echo REBUILT
