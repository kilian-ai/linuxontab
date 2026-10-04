#!/bin/sh
# Build the read-only "x86 Node" disk: x86-64 Node 24 + npm (Alpine 3.23)
# under the wasm Blink from ../x86-chromium (4 GiB, all fixes).
#   /opt/x86/blink                 wasm Blink
#   /opt/x86/{node,npm,npx}        wrappers (x86-env: overlay, --jitless, npm dirs)
#   /opt/x86/x86-node-setup        tmpfs /opt/npm + PATH links
#   /opt/x86/root                  Alpine x86_64 root (nodejs npm + deps)
#
#   sh spikes/x86-node/make-image.sh [workdir] [extra-alpine-pkgs...]
#   -> shell/linux-dist/x86-node.ext4 (not committed)
# Boot ?disk=full&xdisk=linux-dist/x86-node.ext4, then in the guest:
#   mkdir -p /opt/x86 && mount -t ext4 -o ro /dev/vdc /opt/x86 && /opt/x86/x86-node-setup
#   node -v; npm -v
# PRE_NPM="pkg ..." also bakes npm packages into root/usr/lib/node_modules
# (npm install -g run in an x86-64 Alpine 3.23 container, so postinstall
# scripts and platform prebuilds are the real linux-x64-musl ones).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
W="${1:-/tmp/lot-build/x86-node}"; [ $# -gt 0 ] && shift
NAME="${NAME:-x86-node}"   # NAME=x86-openclaw PRE_NPM=openclaw for the baked variant
BLINK="${BLINK:-/tmp/lot-build/blink-chromium/blink}"
BLINK_DBG="${BLINK_DBG:-}"   # optional debug Blink (MODE= build.sh) -> /opt/x86/blink-dbg
MKE2FS=/opt/homebrew/opt/e2fsprogs/sbin/mke2fs
E2FSCK=/opt/homebrew/opt/e2fsprogs/sbin/e2fsck
RESIZE2FS=/opt/homebrew/opt/e2fsprogs/sbin/resize2fs
mkdir -p "$W"

[ -f "$BLINK" ] || sh "$REPO/spikes/x86-chromium/build.sh" "$(dirname "$BLINK")"
[ -x "$W/root/usr/bin/node" ] || python3 "$HERE/fetch-root.py" v3.23 "$W/root" nodejs npm busybox ca-certificates-bundle "$@"
# writes must reach the guest's own /tmp, /root ... (BLINK_OVERLAYS tries
# this root first), and the loader must never search host lib dirs
rm -rf "$W/root/tmp" "$W/root/root" "$W/root/home" "$W/root/run" "$W/root/var/tmp" "$W/root/var/cache"
printf '/opt/x86/root/lib\n/opt/x86/root/usr/lib\n/opt/x86/root/usr/local/lib\n' > "$W/root/etc/ld-musl-x86_64.path"
# npm 11 resolves every dependency with the FULL packument (openclaw's is
# 18 MB, the corgi 0.75 MB); under Blink each byte is parsed by an
# interpreted V8, so ask for corgis unless --before needs publish times
python3 - "$W/root/usr/lib/node_modules/npm/node_modules/@npmcli/arborist/lib/arborist/build-ideal-tree.js" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = "      avoid: this.#avoidRange(spec.name),\n      fullMetadata: true,"
new = "      avoid: this.#avoidRange(spec.name),\n      fullMetadata: !!this.options.before, // LinuxOnTab: corgi packuments"
if new not in s:
    assert old in s, "npm build-ideal-tree.js changed: re-check the fullMetadata patch"
    open(p, "w").write(s.replace(old, new, 1))
EOF

if [ -n "${PRE_NPM:-}" ]; then
  # x86-64 container: same Alpine release, same Node, same npm
  mkdir -p "$W/bins"
  docker run --rm --platform linux/amd64 -v "$W/root/usr/lib/node_modules:/out" -v "$W/bins:/bins" alpine:3.23 sh -c "
    apk add -q nodejs npm >/dev/null && npm install -g --no-audit --no-fund --prefix /tmp/g $PRE_NPM &&
    cp -a /tmp/g/lib/node_modules/. /out/ && cp -a /tmp/g/bin/. /bins/"
  # the bin links are relative (../lib/node_modules/...): valid in root/usr/bin
  cp -a "$W/bins/." "$W/root/usr/bin/"
fi

rm -rf "$W/stage" && mkdir -p "$W/stage"
cp -a "$W/root" "$W/stage/root"
cp "$BLINK" "$W/stage/blink"
[ -n "$BLINK_DBG" ] && cp "$BLINK_DBG" "$W/stage/blink-dbg" && chmod 755 "$W/stage/blink-dbg"
cp "$HERE/x86-env" "$HERE/node" "$HERE/npm" "$HERE/npx" "$HERE/x86-node-setup" "$W/stage/"
chmod 755 "$W/stage/blink" "$W/stage/node" "$W/stage/npm" "$W/stage/npx" "$W/stage/x86-node-setup"
# one host-side wrapper per baked npm bin (x86-node-setup links them to PATH)
for b in $(ls "$W/bins" 2>/dev/null); do
  printf '#!/bin/sh\n. /opt/x86/x86-env\nexec /opt/x86/blink /opt/x86/root/usr/bin/node /opt/x86/root/usr/bin/%s "$@"\n' "$b" > "$W/stage/$b"
  chmod 755 "$W/stage/$b"; echo "$b" >> "$W/stage/baked-bins"
done
SIZE_MB=$(( $(du -sm "$W/stage" | cut -f1) * 115 / 100 + 16 ))
rm -f "$W/$NAME.ext4"
"$MKE2FS" -q -t ext4 -O ^has_journal -L x86node -d "$W/stage" "$W/$NAME.ext4" "${SIZE_MB}M"
"$E2FSCK" -fy "$W/$NAME.ext4" > /dev/null || true
"$RESIZE2FS" -M "$W/$NAME.ext4" 2>&1 | tail -1
"$E2FSCK" -fn "$W/$NAME.ext4" | tail -1
cp "$W/$NAME.ext4" "$REPO/shell/linux-dist/$NAME.ext4"
ls -la "$REPO/shell/linux-dist/$NAME.ext4"
