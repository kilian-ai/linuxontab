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
cp "$SRC/coi-serviceworker.js" "$PUB/coi-serviceworker.js"
cp "$SRC/xterm.js"             "$PUB/xterm.js"
cp "$SRC/xterm.css"           "$PUB/xterm.css"
cp "$SRC/xterm-addon-fit.js"  "$PUB/xterm-addon-fit.js"

# Kernel + userland: the dist/ JS, the vmlinux .wasm, initramfs — everything
# under linux-dist EXCEPT the big rootfs (R2), editor backups, and source maps.
rsync -a \
  --exclude='rootfs.ext4' \
  --exclude='rootfs.ext4?*' \
  --exclude='*.bak' \
  --exclude='*.map' \
  "$SRC/linux-dist/" "$PUB/linux-dist/"

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
