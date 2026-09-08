#!/bin/sh
# Assemble ./public — the exact set of static files Cloudflare Pages should
# upload for LinuxOnTab 2.0. Everything is copied from ../shell EXCEPT the
# 491 MB rootfs.ext4 (that lives in R2, streamed by the rootfs.ext4 Function).
#
# Re-run after any change to shell/wasm.html or shell/linux-dist/.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/shell"
PUB="$HERE/public"

[ -f "$SRC/wasm.html" ] || { echo "ERROR: $SRC/wasm.html not found"; exit 1; }

rm -rf "$PUB"
mkdir -p "$PUB/linux-dist"

# Document + terminal front-end. wasm.html becomes the site index.
cp "$SRC/wasm.html"            "$PUB/index.html"
cp "$SRC/wasm.html"            "$PUB/wasm.html"      # console.html launches containers at this path
cp "$SRC/console.html"         "$PUB/console.html"   # container manager GUI
cp "$SRC/coi-serviceworker.js" "$PUB/coi-serviceworker.js"
cp "$SRC/sw-guest-proxy.js"    "$PUB/sw-guest-proxy.js"
cp "$SRC/xterm.js"             "$PUB/xterm.js"
cp "$SRC/xterm.css"           "$PUB/xterm.css"
cp "$SRC/xterm-addon-fit.js"  "$PUB/xterm-addon-fit.js"

# Kernel + userland: the dist/ JS, the vmlinux .wasm, initramfs — everything
# under linux-dist EXCEPT the big rootfs (R2), editor backups, and source maps.
rsync -a \
  --exclude='rootfs.ext4' \
  --exclude='rootfs.ext4?*' \
  --exclude='rootfs-lean.ext4' \
  --exclude='*.bak' \
  --exclude='*.map' \
  "$SRC/linux-dist/" "$PUB/linux-dist/"
# (rootfs-lean.data + rootfs-lean.manifest.json ride along — a few MB, well
# under the Pages 25 MiB cap. Only the two 512 MiB .ext4 files stay out.)

# Cache-bust the runtime modules. /linux-dist/* is served immutable for a
# year (right for the content-addressed vmlinux-<hash>.wasm and rootfs data),
# but dist/*.js (index.js, worker.js, virtio.js, wali-bridge.js, ...) are NOT
# content-addressed: without this, a deploy that changes them is invisible
# to the edge and to every returning browser. Stamp every module URL with a
# hash of the dist JS so each build gets fresh URLs (wasm.html is no-cache).
STAMP="$(cat "$PUB"/linux-dist/dist/*.js | shasum -a 256 | cut -c1-10)"
for f in "$PUB/index.html" "$PUB/wasm.html"; do
  sed -i '' "s#\./linux-dist/dist/index\.js#./linux-dist/dist/index.js?b=$STAMP#g" "$f"
done
for f in "$PUB"/linux-dist/dist/*.js; do
  sed -E -i '' \
    -e "s#(from [\"'])\./([A-Za-z0-9_-]+\.js)(\?[^\"']*)?([\"'])#\1./\2?b=$STAMP\4#g" \
    -e "s#new URL\(\"\./worker\.js\"#new URL(\"./worker.js?b=$STAMP\"#g" "$f"
done
echo "runtime module stamp: $STAMP"

# COOP/COEP + caching rules.
cp "$HERE/_headers" "$PUB/_headers"

# Guardrail: Cloudflare Pages rejects any single file over 25 MiB.
BIG="$(find "$PUB" -type f -size +25M || true)"
if [ -n "$BIG" ]; then
  echo "ERROR: these files exceed the Pages 25 MiB/file limit:"
  echo "$BIG"
  echo "(rootfs.ext4 should NOT be here — it belongs in R2.)"
  exit 1
fi

echo "publish dir ready:"
du -sh "$PUB"
echo "top-level entries:"
ls -1 "$PUB"
