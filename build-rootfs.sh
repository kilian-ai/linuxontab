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

$MKE2FS -q -t ext4 -d "$STAGING" -F -L "Alpine Linux" -m 0 "$OUTPUT" "$SIZE"

echo "[build-rootfs] done — $(du -sh "$OUTPUT" | cut -f1) written to $OUTPUT"
