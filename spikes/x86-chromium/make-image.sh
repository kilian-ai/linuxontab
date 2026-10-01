#!/bin/sh
# Build the read-only disk image the Chromium spike boots with:
#   /opt/x86/blink, /opt/x86/blink-dbg   wasm Blink (build.sh, release + debug)
#   /opt/x86/chromium                    launcher (headless, one process, no JIT)
#   /opt/x86/<chrome data files>         symlinks: /proc/self/exe is Blink, so
#                                        Chrome looks for its .pak/.dat here
#   /opt/x86/root                        Alpine 3.20 chromium 131, pruned to the
#                                        files a headless run opens (~383 MB)
#
#   sh spikes/x86-chromium/make-image.sh [workdir]
#   -> shell/linux-dist/x86-chromium.ext4 (not committed, ~470 MB)
# Boot with ?xdisk=linux-dist/x86-chromium.ext4, then in the guest:
#   mkdir -p /opt/x86 && mount -t ext4 -o ro /dev/vdc /opt/x86
#   /opt/x86/chromium --dump-dom http://127.0.0.1:8080/
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
W="${1:-/tmp/lot-build/x86-chromium}"
MKE2FS=/opt/homebrew/opt/e2fsprogs/sbin/mke2fs
E2FSCK=/opt/homebrew/opt/e2fsprogs/sbin/e2fsck
mkdir -p "$W"

[ -d "$W/root-full/usr/lib/chromium" ] || python3 "$HERE/fetch-root.py" v3.20 "$W/root-full" chromium
[ -f "$W/blink/blink" ] || sh "$HERE/build.sh" "$W/blink"
[ -f "$W/blink-dbg/blink" ] || MODE= sh "$HERE/build.sh" "$W/blink-dbg"

# stage: the pruned root plus the files Blink itself opens (ld-musl is loaded
# by Blink's ELF loader, which the syscall trace behind chromium-files.txt
# doesn't show)
rm -rf "$W/stage" && mkdir -p "$W/stage"
python3 - "$W/root-full" "$W/stage/root" "$HERE/chromium-files.txt" <<'EOF'
import os, sys, shutil
R, D, listing = sys.argv[1:4]
keep = set()
def add(rel):
    rel = os.path.normpath(rel).lstrip("/")
    if rel in keep or rel in (".", ""): return
    # places Chromium writes: the image is read-only and BLINK_OVERLAYS looks
    # here first, so shipping e.g. /tmp makes shared memory fail (EROFS)
    if rel.split("/")[0] in ("tmp", "root", "run", "home") or rel.startswith(("var/tmp", "var/run")):
        return
    if rel.startswith("var/cache") and not rel.startswith("var/cache/fontconfig") and rel != "var/cache":
        return
    # GTK 4 is never used (Chromium picks GTK 3; GTK 3 is needed: without it
    # there is no input method context and typed keys never reach the page)
    if os.path.basename(rel).startswith("libgtk-4.so"): return
    p = os.path.join(R, rel)
    if not os.path.lexists(p): return
    if os.path.dirname(rel): add(os.path.dirname(rel))
    keep.add(rel)
    if os.path.islink(p):
        t = os.readlink(p)
        add(t if t.startswith("/") else os.path.join(os.path.dirname(rel), t))
for l in open(listing):
    l = l.strip()
    if l.startswith("/") and not l.startswith(("/proc", "/dev", "/sys", "/tmp", "/w/")): add(l)
for d in ["etc/fonts", "usr/share/fonts", "usr/share/fontconfig", "usr/lib/chromium",
          "var/cache/fontconfig",
          "etc/ssl", "usr/share/icu", "lib/ld-musl-x86_64.so.1",
          "usr/lib/libgtk-3.so.0", "usr/lib/gtk-3.0", "usr/share/X11/xkb"]:
    add(d)
    for base, dirs, files in os.walk(os.path.join(R, d)):
        for f in dirs + files: add(os.path.relpath(os.path.join(base, f), R))
for rel in sorted(keep):
    s, t = os.path.join(R, rel), os.path.join(D, rel)
    if os.path.islink(s):
        os.makedirs(os.path.dirname(t), exist_ok=True); os.symlink(os.readlink(s), t)
    elif os.path.isdir(s): os.makedirs(t, exist_ok=True)
    else:
        os.makedirs(os.path.dirname(t), exist_ok=True); shutil.copy2(s, t)
print(len(keep), "entries kept")
EOF
cd "$W/stage"
cp "$W/blink/blink" blink
cp "$W/blink-dbg/blink" blink-dbg
cp "$HERE/chromium" "$HERE/chromium-x" . && chmod 755 chromium chromium-x blink blink-dbg
for f in root/usr/lib/chromium/*; do
  b=$(basename "$f")
  case $b in chrome|chromium) ;; *) ln -s "$f" "$b" ;; esac
done
rm -f "$W/x86-chromium.ext4"
"$MKE2FS" -q -t ext4 -O ^has_journal -L x86 -d "$W/stage" "$W/x86-chromium.ext4" 470M
"$E2FSCK" -fn "$W/x86-chromium.ext4" | tail -1
cp "$W/x86-chromium.ext4" "$REPO/shell/linux-dist/x86-chromium.ext4"
ls -la "$REPO/shell/linux-dist/x86-chromium.ext4"
