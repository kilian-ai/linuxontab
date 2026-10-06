#!/bin/sh
# Build the read-only LibreOffice disk the console's "libreoffice" row boots
# with (?xdisk=linux-dist/libreoffice.ext4), mounted in the guest at /opt/lo:
#   /opt/lo/program/soffice.bin   LibreOffice 26.8 for the wasm kernel (one
#                                 static module, name section stripped)
#   /opt/lo/{program,share,presets}  the rest of instdir (no static libs, no sdk)
#   /opt/lo/writer, soffice        launchers (profile under $HOME, X11 backend)
#   /opt/lo/lo-desktop             X server + Writer, for the console row
#
#   sh spikes/libreoffice/make-image.sh [workdir]
#   -> shell/linux-dist/libreoffice.ext4 (not committed; served from R2:
#      IMAGE=libreoffice.ext4 GZIP=1 cloudflare/upload-rootfs.sh)
# Needs the build container `lo` with a finished build (README.md).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
W="${1:-/tmp/lot-build/libreoffice}"
MKE2FS=/opt/homebrew/opt/e2fsprogs/sbin/mke2fs
E2FSCK=/opt/homebrew/opt/e2fsprogs/sbin/e2fsck
RESIZE2FS=/opt/homebrew/opt/e2fsprogs/sbin/resize2fs
mkdir -p "$W"

# stage in the container: instdir minus link-time leftovers, soffice.bin
# without its 45 MB name section
docker exec lo sh -c '
  set -e
  rm -rf /work/lo-pkg && mkdir -p /work/lo-pkg
  cd /work/libreoffice-26.8.1.1/instdir
  tar cf - --exclude="program/*.a" --exclude="*.linkdeps" --exclude="*-gdb.py" \
      --exclude=./sdk --exclude=./program/soffice.bin . | tar xf - -C /work/lo-pkg
  llvm-objcopy-19 --remove-section=name program/soffice.bin /work/lo-pkg/program/soffice.bin
'
rm -rf "$W/stage"
docker cp lo:/work/lo-pkg "$W/stage"
for f in writer soffice lo-desktop; do
  cp "$HERE/$f" "$W/stage/$f"
  chmod 755 "$W/stage/$f"
done
# the module must be valid wasm: the guest reports any compile failure only
# as "Exec format error"
node -e 'new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))' "$W/stage/program/soffice.bin"

rm -f "$W/libreoffice.ext4"
"$MKE2FS" -q -t ext4 -b 4096 -N 4096 -O ^has_journal -L libreoffice -E root_owner=0:0 -d "$W/stage" "$W/libreoffice.ext4" 400M
# shrink to the data (read-only disk; every free block is more download)
"$E2FSCK" -fy "$W/libreoffice.ext4" > /dev/null || true
"$RESIZE2FS" -M "$W/libreoffice.ext4" 2>&1 | tail -2
"$E2FSCK" -fn "$W/libreoffice.ext4" | tail -1
cp "$W/libreoffice.ext4" "$REPO/shell/linux-dist/libreoffice.ext4"
ls -la "$REPO/shell/linux-dist/libreoffice.ext4"
