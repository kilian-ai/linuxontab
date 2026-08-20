#!/bin/sh
# Upload the guest root filesystem to R2 using ONLY wrangler (no S3 keypair).
#
# rootfs.ext4 is 512 MiB, but `wrangler r2 object put` caps a single upload at
# 300 MiB. So we split it into <300 MiB parts, upload each, and write a
# manifest listing them in order. The Pages Function
# (functions/linux-dist/rootfs.ext4.js) reads the manifest and streams the
# parts back concatenated, so the browser sees one 512 MiB rootfs.ext4.
#
# Prereqs: `npx wrangler login` already done (same as for `pages deploy`).
# Re-run after any rootfs.ext4 rebuild — the manifest is authoritative, so a
# smaller rebuilt image can't be corrupted by leftover parts.
#
# Tunables:
#   PART_MB   part size in MiB (default 25 — small, resilient over flaky links)
#   RETRIES   attempts per part (default 8)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/shell/linux-dist/rootfs.ext4"
BUCKET="linuxontab-rootfs"
PART_MB="${PART_MB:-25}"
RETRIES="${RETRIES:-8}"

[ -f "$SRC" ] || { echo "ERROR: $SRC not found"; exit 1; }
# CF_ACCOUNT_ID isn't needed by wrangler here; unset a stale one to avoid a 403.
unset CF_ACCOUNT_ID CLOUDFLARE_ACCOUNT_ID 2>/dev/null || true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "splitting $(du -h "$SRC" | cut -f1) into ${PART_MB} MiB parts…"
split -b "${PART_MB}m" "$SRC" "$WORK/rootfs.ext4.part-"
TOTAL=$(ls "$WORK"/rootfs.ext4.part-* | wc -l | tr -d ' ')

put() { # key file
  i=1
  while [ "$i" -le "$RETRIES" ]; do
    if npx --yes wrangler r2 object put "$BUCKET/$1" \
         --file "$2" --content-type "$3" --remote >/dev/null 2>&1; then
      return 0
    fi
    i=$((i+1)); sleep 2
  done
  return 1
}

n=0
for f in "$WORK"/rootfs.ext4.part-*; do
  n=$((n+1))
  key="rootfs.ext4.$(basename "$f" | sed 's/^rootfs.ext4.//')"
  printf 'uploading [%d/%d] %s … ' "$n" "$TOTAL" "$key"
  put "$key" "$f" application/octet-stream || { echo "FAILED after $RETRIES tries"; exit 1; }
  echo ok
done

# Manifest last — authoritative order + total size + content hash.
# The sha256 becomes the HTTP ETag the Function serves, which is how a browser
# decides whether its cached 512 MiB copy is stale WITHOUT re-downloading it
# (see bootImageVersion() in shell/wasm.html). Without a hash, a rebuilt image
# of identical size would look unchanged to every returning visitor.
SIZE=$(wc -c < "$SRC" | tr -d ' ')
SHA=$(shasum -a 256 "$SRC" | awk '{print $1}')
KEYS=$(ls "$WORK"/rootfs.ext4.part-* | sed 's#.*/##' | sed 's/^/"/; s/$/"/' | paste -sd, -)
printf '{"parts":[%s],"size":%s,"sha256":"%s"}' "$KEYS" "$SIZE" "$SHA" > "$WORK/manifest.json"
printf 'uploading manifest (%d parts, %s bytes) … ' "$TOTAL" "$SIZE"
put "rootfs.ext4.manifest" "$WORK/manifest.json" application/json || { echo "FAILED"; exit 1; }
echo ok

echo "done. Now: ./build-publish.sh && npx wrangler pages deploy --branch=main"
