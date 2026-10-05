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
# ATOMICITY: parts alternate between two key generations ("a"/"b" slots,
# rootfs.ext4.<slot>.part-*). Each upload writes the INACTIVE slot and flips
# the manifest last, so a visitor booting mid-upload keeps streaming the old,
# consistent generation — never a mix of old and new parts. (The previous
# in-place scheme corrupted any boot that raced an upload.) Storage is bounded
# at two generations; the next upload overwrites the stale slot.
#
# Tunables:
#   PART_MB   part size in MiB (default 25 — small, resilient over flaky links)
#   RETRIES   attempts per part (default 8)
#   IMAGE     file under shell/linux-dist to upload (default rootfs.ext4); its
#             keys are "$IMAGE.<slot>.part-*" + "$IMAGE.manifest", e.g.
#             IMAGE=x86-chromium.ext4 for the Chromium spike's extra disk
#             (served by functions/linux-dist/x86-chromium.ext4.js)
#   GZIP=1    store a gzip stream of the image instead (manifest gets
#             encoding/csize; lib/r2image.js serves it with x-lot-encoding and
#             the page inflates it). Only for the ?xdisk= images — the
#             rootfs.ext4 Function serves raw parts.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
IMAGE="${IMAGE:-rootfs.ext4}"
SRC="$REPO/shell/linux-dist/$IMAGE"
BUCKET="linuxontab-rootfs"
PART_MB="${PART_MB:-25}"
RETRIES="${RETRIES:-8}"

[ -f "$SRC" ] || { echo "ERROR: $SRC not found"; exit 1; }
# CF_ACCOUNT_ID isn't needed by wrangler here; unset a stale one to avoid a 403.
unset CF_ACCOUNT_ID CLOUDFLARE_ACCOUNT_ID 2>/dev/null || true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Pick the inactive slot: read the live manifest's slot and use the other one.
# No manifest / no slot field (legacy in-place layout) → start with "a".
CUR_SLOT=$(npx --yes wrangler r2 object get "$BUCKET/$IMAGE.manifest" --pipe --remote 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("slot",""))' 2>/dev/null || echo "")
if [ "$CUR_SLOT" = "a" ]; then SLOT="b"; else SLOT="a"; fi
echo "live slot: '${CUR_SLOT:-none}' → uploading to slot '$SLOT'"

PARTSRC="$SRC"
if [ -n "${GZIP:-}" ]; then
  echo "compressing $(du -h "$SRC" | cut -f1)…"
  # gzip reads $GZIP as default options ("1" = a file name): hide ours
  env -u GZIP gzip -9 -c "$SRC" > "$WORK/$IMAGE.gz"; PARTSRC="$WORK/$IMAGE.gz"
fi
echo "splitting $(du -h "$PARTSRC" | cut -f1) into ${PART_MB} MiB parts…"
split -b "${PART_MB}m" "$PARTSRC" "$WORK/$IMAGE.part-"
TOTAL=$(ls "$WORK"/"$IMAGE".part-* | wc -l | tr -d ' ')

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
for f in "$WORK"/"$IMAGE".part-*; do
  n=$((n+1))
  key="$IMAGE.${SLOT}.$(basename "$f" | sed "s/^$IMAGE.//")"
  printf 'uploading [%d/%d] %s … ' "$n" "$TOTAL" "$key"
  put "$key" "$f" application/octet-stream || { echo "FAILED after $RETRIES tries"; exit 1; }
  echo ok
done

# Manifest last — the ATOMIC FLIP. Until this succeeds, readers keep streaming
# the previous slot's parts, which are untouched. It carries order + total
# size + content hash. The sha256 becomes the HTTP ETag the Function serves,
# which is how a browser decides whether its cached 512 MiB copy is stale
# WITHOUT re-downloading it (see bootImageVersion() in shell/wasm.html).
# Without a hash, a rebuilt image of identical size would look unchanged to
# every returning visitor.
SIZE=$(wc -c < "$SRC" | tr -d ' ')
SHA=$(shasum -a 256 "$SRC" | awk '{print $1}')
KEYS=$(ls "$WORK"/"$IMAGE".part-* | sed 's#.*/##' | sed "s/^$IMAGE./\"$IMAGE.${SLOT}./; s/\$/\"/" | paste -sd, -)
if [ -n "${GZIP:-}" ]; then
  CSIZE=$(wc -c < "$PARTSRC" | tr -d ' ')
  printf '{"slot":"%s","parts":[%s],"size":%s,"sha256":"%s","encoding":"gzip","csize":%s}' "$SLOT" "$KEYS" "$SIZE" "$SHA" "$CSIZE" > "$WORK/manifest.json"
else
  printf '{"slot":"%s","parts":[%s],"size":%s,"sha256":"%s"}' "$SLOT" "$KEYS" "$SIZE" "$SHA" > "$WORK/manifest.json"
fi
printf 'uploading manifest (%d parts, %s bytes) … ' "$TOTAL" "$SIZE"
put "$IMAGE.manifest" "$WORK/manifest.json" application/json || { echo "FAILED"; exit 1; }
echo ok

echo "done. Now: ./build-publish.sh && npx wrangler pages deploy --branch=main"
