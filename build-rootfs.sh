#!/bin/sh
# build-rootfs.sh — Rebuild shell/linux-dist/rootfs.ext4 from the rootfs/ staging tree.
#
# Usage:
#   ./build-rootfs.sh            # rebuild and write to shell/linux-dist/rootfs.ext4
#   ./build-rootfs.sh --dry-run  # show what would be done
#
# Adding a package:
#   1. Copy the binary into rootfs/usr/local/bin/<name>  (or wherever fits)
#   2. If it needs a /packages/*.tar.gz entry, add it to rootfs/packages/
#   3. Register it in rootfs/usr/bin/apk  (cmd_install / cmd_upgrade lists)
#   4. Run ./build-rootfs.sh
#   5. git add rootfs/ shell/linux-dist/rootfs.ext4 && git commit

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGING="$SCRIPT_DIR/rootfs"
OUTPUT="$SCRIPT_DIR/shell/linux-dist/rootfs.ext4"
SIZE=64M

# Locate mke2fs — prefer Homebrew e2fsprogs (macOS), fall back to system mke2fs (Linux)
if [ -x /opt/homebrew/opt/e2fsprogs/sbin/mke2fs ]; then
  MKE2FS=/opt/homebrew/opt/e2fsprogs/sbin/mke2fs
elif command -v mke2fs >/dev/null 2>&1; then
  MKE2FS=mke2fs
else
  echo "ERROR: mke2fs not found." >&2
  echo "  macOS: brew install e2fsprogs" >&2
  echo "  Linux: apt install e2fsprogs" >&2
  exit 1
fi

if [ "$1" = "--dry-run" ]; then
  echo "Would run: $MKE2FS -q -t ext4 -d $STAGING -F -L 'Alpine Linux' -m 0 $OUTPUT $SIZE"
  exit 0
fi

echo "[build-rootfs] using $MKE2FS"
echo "[build-rootfs] staging: $STAGING"
echo "[build-rootfs] output:  $OUTPUT"

# Apply wasm-opt --asyncify to every WASM binary in the staging tree so that
# fork()/vfork() (which rely on asyncify_start_unwind / asyncify_start_rewind)
# work at runtime.  Binaries that are already transformed are idempotent (wasm-
# opt is a no-op for already-asyncify'd modules).
WASM_OPT="${WASM_OPT:-/opt/homebrew/bin/wasm-opt}"
if [ -x "$WASM_OPT" ]; then
  echo "[build-rootfs] applying wasm-opt --asyncify to staging WASM binaries..."
  find "$STAGING" -type f | while read -r f; do
    # Quick magic-byte check: WASM files start with \0asm
    if [ "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "0061736d" ]; then
      echo "  asyncify: $f"
      "$WASM_OPT" --asyncify -O1 "$f" -o "$f.tmp" && mv "$f.tmp" "$f" || {
        echo "  WARNING: wasm-opt failed for $f (skipping)" >&2
        rm -f "$f.tmp"
      }
    fi
  done
else
  echo "[build-rootfs] WARNING: wasm-opt not found at $WASM_OPT — skipping asyncify transform." >&2
  echo "[build-rootfs] Install with: brew install binaryen" >&2
fi

$MKE2FS -q -t ext4 -d "$STAGING" -F -L "Alpine Linux" -m 0 "$OUTPUT" "$SIZE"

echo "[build-rootfs] done — $(du -sh "$OUTPUT" | cut -f1) written to $OUTPUT"
