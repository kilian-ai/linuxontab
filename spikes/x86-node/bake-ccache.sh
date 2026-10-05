#!/bin/sh
# Bake a Node compile cache (V8 code cache) for x86-openclaw.ext4 by running
# `openclaw onboard` to its first prompt under NATIVE Blink in Docker, with
# the same paths and V8 flags as the guest wrapper (cache entries are keyed
# by file path + content, Node version and the V8 flag hash), then Ctrl-C so
# Node flushes the cache. ~2685 entries, 17 MB; cuts onboard's CPU ~40%.
#   sh spikes/x86-node/bake-ccache.sh <x86 root> <native blink dir> <out dir>
#   NODE_CCACHE=<out dir> NAME=x86-openclaw sh spikes/x86-node/make-image.sh ...
# <native blink dir>/bl/blink = native arm64 Blink with the LinuxOnTab patches
# (../x86-chromium/xtest/harness/rebuild-native.sh). Takes ~20-45 min.
set -eu
ROOT="$(cd "$1" && pwd)"; BL="$(cd "$2" && pwd)"; OUT="$3"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
cat > "$OUT/.bake.sh" <<'EOS'
apk add -q util-linux-misc procps >/dev/null 2>&1
export BLINK_OVERLAYS=/opt/x86/root: HOME=/tmp/home TERM=xterm-256color OPENCLAW_NO_RESPAWN=1
mkdir -p $HOME; cd /tmp; mkfifo /tmp/in
(cat /tmp/in) | script -q -f -c "/w/bl/blink -m -j /opt/x86/root/usr/bin/node --no-maglev --no-turbofan --disable-warning=ExperimentalWarning /opt/x86/root/usr/bin/openclaw onboard" /o/.bake.ts > /dev/null 2>&1 &
exec 3>/tmp/in
while ! grep -q "Setup choices" /o/.bake.ts 2>/dev/null; do sleep 2; done
sleep 5; printf '\003' >&3; sleep 5; printf '\003' >&3
while pgrep -x blink >/dev/null; do sleep 2; done
cp -a /tmp/node-compile-cache/. /o/
EOS
docker run --rm --platform linux/arm64 -v "$BL:/w" -v "$ROOT:/opt/x86/root:ro" -v "$OUT:/o" alpine:3.20 sh /o/.bake.sh
rm -f "$OUT/.bake.sh" "$OUT/.bake.ts"
du -sh "$OUT"; find "$OUT" -type f | wc -l
