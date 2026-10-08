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
#   LOT_UPLOAD_BASE_SHA  sha256 of the live image this build started from;
#             refuse to start, and refuse to flip, unless the live manifest
#             still names it (catches "someone uploaded since my download").
#   LOT_UPLOAD_OWNER     who holds the lock, shown to anyone blocked by it
#             (default user@host; set it to your session/task name).
#   LOCK_TTL  seconds after which a left-behind lock counts as stale (7200).
#   LOT_UPLOAD_FORCE=1   take the lock even if another upload holds it.
#
# CONCURRENCY: two uploads that start from the same live slot both pick the
# same inactive slot and overwrite each other's parts (2026-10-08: a 768 MiB
# image was lost that way, while an ETag check right before each upload
# passed for both). So an upload takes "$IMAGE.lock" in R2 first, and
# re-reads the manifest just before the flip: if it changed since the start,
# another upload got in and this one aborts without flipping. R2's CLI has
# no create-if-absent, so the lock is write-then-read-back (a near-
# simultaneous start still loses cleanly at the read-back or the flip check).
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
LOCK_KEY="$IMAGE.lock"
LOCK_TTL="${LOCK_TTL:-7200}"
TOKEN="$(hostname)-$$-$(date +%s)-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
HAVE_LOCK=0

rget() { # key -> object body on stdout (empty if absent)
  npx --yes wrangler r2 object get "$BUCKET/$1" --pipe --remote 2>/dev/null || true
}
lock_token() { rget "$LOCK_KEY" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")'; }
release_lock() {
  [ "$HAVE_LOCK" = 1 ] || return 0
  # only remove it if it is still ours (a forced takeover replaced it)
  if [ "$(lock_token)" = "$TOKEN" ]; then
    npx --yes wrangler r2 object delete "$BUCKET/$LOCK_KEY" --remote >/dev/null 2>&1 || true
  fi
  HAVE_LOCK=0
}
trap 'release_lock; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

# ── Lock ─────────────────────────────────────────────────────────────────────
HELD=$(rget "$LOCK_KEY")
if [ -n "$HELD" ]; then
  AGE=$(printf '%s' "$HELD" | python3 -c 'import json,sys,time
try: print(int(time.time()) - int(json.load(sys.stdin).get("started",0)))
except Exception: print(999999)')
  if [ "$AGE" -lt "$LOCK_TTL" ] && [ "${LOT_UPLOAD_FORCE:-}" != 1 ]; then
    echo "ERROR: another upload of $IMAGE holds the lock (${AGE}s old):"
    echo "  $HELD"
    echo "Wait for it, ask its owner, or LOT_UPLOAD_FORCE=1 if it is dead."
    exit 1
  fi
  echo "note: taking over a ${AGE}s-old lock: $HELD"
fi
printf '{"token":"%s","owner":"%s","started":%s,"image":"%s"}' "$TOKEN" \
  "${LOT_UPLOAD_OWNER:-${USER:-?}@$(hostname)}" "$(date +%s)" "$IMAGE" > "$WORK/lock.json"
npx --yes wrangler r2 object put "$BUCKET/$LOCK_KEY" --file "$WORK/lock.json" \
  --content-type application/json --remote >/dev/null 2>&1 \
  || { echo "ERROR: could not write the lock"; exit 1; }
HAVE_LOCK=1
sleep 3   # let a near-simultaneous writer land, then see whose lock stuck
if [ "$(lock_token)" != "$TOKEN" ]; then
  HAVE_LOCK=0
  echo "ERROR: lost the lock race to another upload: $(rget "$LOCK_KEY")"
  exit 1
fi
echo "lock: $LOCK_KEY held (${LOT_UPLOAD_OWNER:-${USER:-?}@$(hostname)})"

# Pick the inactive slot: read the live manifest's slot and use the other one.
# No manifest / no slot field (legacy in-place layout) → start with "a".
# This snapshot is also what the pre-flip check compares against.
BASE_MANIFEST=$(rget "$IMAGE.manifest")
mfield() { printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1],""))
except Exception: print("")' "$2"; }
CUR_SLOT=$(mfield "$BASE_MANIFEST" slot)
LIVE_SHA=$(mfield "$BASE_MANIFEST" sha256)
if [ -n "${LOT_UPLOAD_BASE_SHA:-}" ] && [ "$LIVE_SHA" != "$LOT_UPLOAD_BASE_SHA" ]; then
  echo "ERROR: live $IMAGE is ${LIVE_SHA:-none}, not LOT_UPLOAD_BASE_SHA=$LOT_UPLOAD_BASE_SHA"
  echo "Someone uploaded since you built: rebuild on the live image."
  exit 1
fi
if [ "$CUR_SLOT" = "a" ]; then SLOT="b"; else SLOT="a"; fi
echo "live slot: '${CUR_SLOT:-none}' (${LIVE_SHA:-no sha}) → uploading to slot '$SLOT'"

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
# Pre-flip check: the manifest must be exactly what it was when we took the
# lock, and the lock must still be ours. Otherwise another upload ran in the
# meantime and may have overwritten our slot's parts: flipping now could
# publish a mix. Abort and leave the live image alone.
if [ "$(rget "$IMAGE.manifest")" != "$BASE_MANIFEST" ]; then
  echo "ERROR: $IMAGE.manifest changed during this upload (another upload ran)."
  echo "Not flipping; live is untouched by this run. Rebuild on the new live image."
  exit 1
fi
if [ "$(lock_token)" != "$TOKEN" ]; then
  echo "ERROR: the lock was taken over during this upload. Not flipping."
  exit 1
fi
printf 'uploading manifest (%d parts, %s bytes) … ' "$TOTAL" "$SIZE"
put "$IMAGE.manifest" "$WORK/manifest.json" application/json || { echo "FAILED"; exit 1; }
echo ok

echo "done. Now: ./build-publish.sh && npx wrangler pages deploy --branch=main"
