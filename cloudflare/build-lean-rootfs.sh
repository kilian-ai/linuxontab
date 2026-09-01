#!/bin/sh
# Build the LEAN boot rootfs for LinuxOnTab 2.0.
#
# Produces (in shell/linux-dist/):
#   rootfs-lean.ext4           512 MiB ext4, ~a few MB of real data (local dev / debugging)
#   rootfs-lean.data           just the non-zero extents, concatenated (what browsers download)
#   rootfs-lean.manifest.json  {size, extents:[[off,len],...], sha256, dataSha256}
#
# The lean image boots to a busybox shell with apk + the package index; every
# other command is a tiny stub that auto-installs its package on first use
# (`apk exec-install`, see rootfs/usr/bin/apk). wasm.html prefers the lean
# manifest when present; ?disk=full forces the classic 512 MiB image.
#
# Geometry matches the full image (512 MiB / 4 KiB blocks) so the guest sees
# the same /dev/vda capacity and has room for on-demand installs.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ROOTFS="$REPO/rootfs"
PKGDIR="$REPO/packages"
OUTDIR="$REPO/shell/linux-dist"
MKE2FS="${MKE2FS:-/opt/homebrew/opt/e2fsprogs/sbin/mke2fs}"

SIZE_BLOCKS=131072      # 4 KiB blocks -> 512 MiB, same as rootfs.ext4
BLOCK=4096

[ -x "$MKE2FS" ] || { echo "ERROR: mke2fs not found at $MKE2FS (brew install e2fsprogs)"; exit 1; }
[ -f "$PKGDIR/index.json" ] || { echo "ERROR: $PKGDIR/index.json missing"; exit 1; }

STAGE="$(mktemp -d /tmp/lot-lean-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging lean tree in $STAGE"

# ── Core layout ──────────────────────────────────────────────────────────────
mkdir -p "$STAGE/bin" "$STAGE/sbin" "$STAGE/usr/bin" "$STAGE/usr/sbin" \
         "$STAGE/usr/local/bin" "$STAGE/usr/local/sbin" "$STAGE/usr/local/lib" \
         "$STAGE/usr/local/libexec" "$STAGE/usr/lib" \
         "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$STAGE/dev/pts" \
         "$STAGE/tmp" "$STAGE/run" "$STAGE/var/log" "$STAGE/var/run" \
         "$STAGE/var/tmp" "$STAGE/var/lib/apk/installed" "$STAGE/var/lib/apk/files" \
         "$STAGE/var/cache/apk" "$STAGE/root" "$STAGE/home" "$STAGE/packages" \
         "$STAGE/opt" "$STAGE/mnt"

cp -p "$ROOTFS/bin/busybox" "$STAGE/bin/busybox"
ln -s busybox "$STAGE/bin/sh"
# wget wrapper: routes https:// through the JS gateway (_https/ prefix) so the
# browser does real TLS. busybox has the wget applet but --install doesn't
# expose it; apk depends on `wget` being on PATH.
cp -p "$ROOTFS/bin/wget" "$STAGE/bin/wget"

# /etc wholesale (motd, profile, ssl certs, ssh config+keys, passwd, hosts...)
# — 300 KB and saves chasing individual dependencies. rc is overwritten below.
cp -Rp "$ROOTFS/etc" "$STAGE/etc"

cp -p "$ROOTFS/usr/bin/apk" "$STAGE/usr/bin/apk"
chmod +x "$STAGE/usr/bin/apk"
# lotfetch: tiny HTTP-GET-via-gateway client (this busybox has no wget applet).
# apk prefers it over wget. Source: tools/lotfetch.c (tools/build-lotfetch.sh).
cp -p "$ROOTFS/usr/bin/lotfetch" "$STAGE/usr/bin/lotfetch"
chmod +x "$STAGE/usr/bin/lotfetch"
[ -f "$ROOTFS/usr/local/sbin/install-https-tools" ] && \
    cp -p "$ROOTFS/usr/local/sbin/install-https-tools" "$STAGE/usr/local/sbin/"

# terminfo (36 KB): without it every ncurses app installed via apk dies with
# "Error opening terminal: xterm-256color" — htop/mc/nano/tmux all need it.
mkdir -p "$STAGE/usr/share"
cp -Rp "$ROOTFS/usr/share/terminfo" "$STAGE/usr/share/terminfo"

# Baked package index (apk falls back to it before any network).
cp -p "$PKGDIR/index.json" "$STAGE/packages/index.json"

# ── Lean /etc/rc (PID 1 after switch_root) ───────────────────────────────────
# Modeled on rootfs/etc/rc, with everything that needs absent software guarded.
cat > "$STAGE/etc/rc" << 'EOF'
#!/bin/sh
# System init (lean boot) — runs after switch_root from initramfs

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TERM=xterm-256color
export SSL_CERT_FILE=/etc/ssl/cert.pem
export SSL_CERT_DIR=/etc/ssl/certs

/bin/busybox --install -s
[ -x /usr/local/sbin/install-https-tools ] && /usr/local/sbin/install-https-tools

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts
mkdir -p /tmp /run /var/tmp /var/run /var/log
chmod 1777 /tmp /var/tmp

# Wall clock from lot_epoch=N on the kernel cmdline (see full rc for why
# this must happen from userspace).
read _CMDLINE < /proc/cmdline
case "$_CMDLINE" in
*lot_epoch=*)
	_EPOCH="${_CMDLINE##*lot_epoch=}"
	_EPOCH="${_EPOCH%% *}"
	date -s "@${_EPOCH}" > /dev/null 2>&1
	;;
esac

hostname linuxontab

# Container identity: the page passes lot_ip= (this tab's LAN address) and
# lot_hosts=name:ip,name:ip (peer services) on the kernel cmdline.
_IP="192.168.86.100"
case "$_CMDLINE" in
*lot_ip=*)
	_IP="${_CMDLINE##*lot_ip=}"
	_IP="${_IP%% *}"
	;;
esac
case "$_CMDLINE" in
*lot_hosts=*)
	_H="${_CMDLINE##*lot_hosts=}"
	_H="${_H%% *}"
	echo "$_H" | tr ',' '\n' | awk -F: 'NF==2 {print $2" "$1}' >> /etc/hosts
	;;
esac

/bin/busybox ifconfig lo 127.0.0.1 netmask 255.0.0.0 up
/bin/busybox ifconfig eth0 "$_IP" netmask 255.255.255.0 broadcast 192.168.86.255 up
/bin/busybox route add default gw 192.168.86.1
/bin/busybox arp -s 192.168.86.1 52:54:00:01:02:03
echo "nameserver 192.168.86.1" > /etc/resolv.conf

# DNS pins (DoH relay drops frames when the tab is throttled — see full rc).
cat >> /etc/hosts <<'HOSTS'
104.16.0.34     registry.npmjs.org
104.16.11.34    registry.npmjs.org
151.101.192.223 pypi.org
151.101.128.223 files.pythonhosted.org
151.101.192.223 files.pythonhosted.org
160.79.104.10   api.anthropic.com
162.159.140.245 api.openai.com
HOSTS

cat /etc/motd

# Service autostart (tabs-as-containers): lot_svc=redis[,pkg...] on the
# cmdline installs each package and, if /etc/lot-services.conf has a line
# "name|command", starts the service in the background.
case "$_CMDLINE" in
*lot_svc=*)
	_SVCS="${_CMDLINE##*lot_svc=}"
	_SVCS="${_SVCS%% *}"
	# NB: iterate WITHOUT a pipeline — `echo | tr | while read` runs the loop
	# body in a subshell, pushing apk (and its awk children) one fork level
	# deeper, where the asyncify fork-chain hang lives. It worked on desktop
	# by timing luck and reliably stalled installs on iOS.
	_rest="$_SVCS,"
	while [ -n "$_rest" ]; do
		_svc="${_rest%%,*}"
		_rest="${_rest#*,}"
		[ -n "$_svc" ] || continue
		echo "[lot] provisioning service: $_svc"
		/usr/bin/apk add "$_svc" || continue
		_cmdline_svc=""
		# registry line: name|command
		grep "^$_svc|" /etc/lot-services.conf > /tmp/.lot-svc-cmd 2>/dev/null
		read -r _cmdline_svc < /tmp/.lot-svc-cmd 2>/dev/null
		rm -f /tmp/.lot-svc-cmd
		_cmdline_svc="${_cmdline_svc#*|}"
		if [ -n "$_cmdline_svc" ]; then
			echo "[lot] starting: $_cmdline_svc"
			sh -c "$_cmdline_svc" > "/tmp/svc-$_svc.log" 2>&1 &
		fi
	done
	;;
esac

# Service start WITHOUT install (lot_run=name[,name...]): for committed-image
# boots (?image=@overlay) where the binaries are already in the filesystem —
# no apk involved, just the registry command. Keeps the fragile install
# machinery entirely off devices that only run prebuilt images (phones).
case "$_CMDLINE" in
*lot_run=*)
	_RUNS="${_CMDLINE##*lot_run=}"
	_RUNS="${_RUNS%% *}"
	_rrest="$_RUNS,"
	while [ -n "$_rrest" ]; do
		_rsvc="${_rrest%%,*}"
		_rrest="${_rrest#*,}"
		[ -n "$_rsvc" ] || continue
		_rcmd=""
		grep "^$_rsvc|" /etc/lot-services.conf > /tmp/.lot-run-cmd 2>/dev/null
		read -r _rcmd < /tmp/.lot-run-cmd 2>/dev/null
		rm -f /tmp/.lot-run-cmd
		_rcmd="${_rcmd#*|}"
		if [ -n "$_rcmd" ]; then
			echo "[lot] starting: $_rcmd"
			sh -c "$_rcmd" > "/tmp/svc-$_rsvc.log" 2>&1 &
		fi
	done
	;;
esac

# sshd only if installed (apk add openssh / dropbear installs then this
# starts it on next boot; the stub path handles first-use in-session).
if [ -x /usr/local/libexec/sshd-session ] || [ -x /sbin/sshd ]; then
	(while true; do
		if [ -x /sbin/sshd ]; then
			mkdir -p /run/sshd
			/sbin/sshd -D -e -f /etc/ssh/sshd_config >>/tmp/sshd.log 2>&1
		fi
		[ -x /usr/local/libexec/sshd-session ] && \
			/usr/local/libexec/sshd-session -f /etc/ssh/sshd_config 2>>/tmp/sshd.log
		sleep 1
	done) &
fi

# The shell must run in its own session with hvc0 as controlling tty, or ^C
# never reaches the foreground job (PID 1's /dev/console can't be a ctty, so
# the line discipline has no pgrp to signal). getty -l /bin/sh is broken in
# this busybox build (clone fn=446), so setsid+cttyhack instead; the loop
# also respawns the shell after ^D/exit instead of killing init.
while true; do
	setsid cttyhack /bin/sh -i
done
EOF
chmod +x "$STAGE/etc/rc"

# ── Service registry (lot_svc autostart commands) ────────────────────────────
# name|command — /etc/rc starts the command after `apk add name` when the tab
# was opened with ?image=name. Packages without a line just get installed.
cat > "$STAGE/etc/lot-services.conf" << 'EOF'
redis|redis-server --port 6379 --bind 0.0.0.0 --protected-mode no
nginx|nginx-demo
httpd|httpd-demo
EOF

# ── Lean motd ────────────────────────────────────────────────────────────────
cat > "$STAGE/etc/motd" << 'EOF'

  LinuxOnTab 2.0 — real Linux 6.1, compiled to WebAssembly   [lean boot]

  This tab booted from a few MB. Software installs itself on first use:
      python3            # downloads + installs python, then runs it
      nano, jq, tmux ... # same — every package is one first-run away
  Or manage packages explicitly:
      apk list           # what's available
      apk add <pkg>      # install now
  Web servers:  nginx-demo (:8080) · httpd-demo (:8081)  → top bar: web view
  Everything runs in this tab. Nothing is sent to a server.

EOF

# ── Auto-install stubs ───────────────────────────────────────────────────────
# Scan every package tarball for the executables it ships in bin dirs
# (pkg-<name>/{bin,sbin,usr/bin,usr/sbin,usr/local/bin,usr/local/sbin}/*)
# and drop a stub at each path. The index's `bins` field is only a display
# hint (usually just the package name), so the tarballs are the ground truth.
echo "==> generating auto-install stubs"
python3 - "$PKGDIR" "$STAGE" << 'PYEOF'
import json, os, sys, tarfile

pkgdir, stage = sys.argv[1], sys.argv[2]
index = json.load(open(os.path.join(pkgdir, "index.json")))
pkgs = index.get("packages", {})

BIN_DIRS = ("bin/", "sbin/", "usr/bin/", "usr/sbin/",
            "usr/local/bin/", "usr/local/sbin/")
SKIP_PKGS = {"busybox"}          # core of the lean image itself
stub_count = 0
per_pkg = []
for name, meta in sorted(pkgs.items()):
    if name in SKIP_PKGS:
        continue
    tarball = os.path.join(pkgdir, f"{name}-{meta.get('version','')}.tar.gz")
    if not os.path.exists(tarball):
        print(f"    [skip] {name}: tarball not found ({os.path.basename(tarball)})")
        continue
    try:
        with tarfile.open(tarball, "r:gz") as tf:
            members = [m for m in tf.getmembers() if m.isfile() or m.issym()]
    except Exception as e:
        print(f"    [skip] {name}: unreadable tarball ({e})")
        continue
    prefix = f"pkg-{name}/"
    made = 0
    for m in members:
        if not m.name.startswith(prefix):
            continue
        rel = m.name[len(prefix):]
        if not any(rel.startswith(bd) and "/" not in rel[len(bd):] and rel != bd
                   for bd in BIN_DIRS):
            continue                     # not a top-level bin-dir entry
        dest = os.path.join(stage, rel)
        if os.path.exists(dest) or os.path.islink(dest):
            continue                     # real file already staged (apk, busybox)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as f:
            f.write("#!/bin/sh\n"
                    f'exec /usr/bin/apk exec-install {name} /{rel} "$@"\n')
        os.chmod(dest, 0o755)
        stub_count += 1
        made += 1
    if made:
        per_pkg.append(f"{name}({made})")
print(f"    {stub_count} stubs: {' '.join(per_pkg)}")
PYEOF

echo "==> lean tree size:"
du -sh "$STAGE" | awk '{print "    " $1}'

# ── mke2fs ───────────────────────────────────────────────────────────────────
OUT="$OUTDIR/rootfs-lean.ext4"
rm -f "$OUT"
echo "==> mke2fs -d (512 MiB geometry, no journal)"
"$MKE2FS" -F -q -t ext4 -b $BLOCK -I 256 -m 0 -L lotlean \
    -O ^has_journal \
    -E lazy_itable_init=1,no_copy_xattrs \
    -d "$STAGE" "$OUT" $SIZE_BLOCKS

# ── Sparse extent scan → .data + .manifest.json ─────────────────────────────
echo "==> scanning extents"
python3 - "$OUT" "$OUTDIR/rootfs-lean.data" "$OUTDIR/rootfs-lean.manifest.json" << 'PYEOF'
import hashlib, json, sys

img_path, data_path, man_path = sys.argv[1], sys.argv[2], sys.argv[3]
BLOCK = 4096
GAP_BLOCKS = 16          # merge runs separated by < 64 KiB of zeros
ZERO = bytes(BLOCK)

img = open(img_path, "rb").read()
size = len(img)
assert size % BLOCK == 0

# Non-zero block bitmap -> merged extents
extents = []
cur = None               # [start_block, end_block)
nblocks = size // BLOCK
for b in range(nblocks):
    nz = img[b*BLOCK:(b+1)*BLOCK] != ZERO
    if nz:
        if cur is None:
            cur = [b, b+1]
        elif b - cur[1] < GAP_BLOCKS:
            cur[1] = b+1            # merge across the small gap
        else:
            extents.append(cur); cur = [b, b+1]
if cur:
    extents.append(cur)

with open(data_path, "wb") as out:
    for s, e in extents:
        out.write(img[s*BLOCK:e*BLOCK])

data = open(data_path, "rb").read()
man = {
    "size": size,
    "blockSize": BLOCK,
    "extents": [[s*BLOCK, (e-s)*BLOCK] for s, e in extents],
    "sha256": hashlib.sha256(img).hexdigest(),
    "dataSha256": hashlib.sha256(data).hexdigest(),
}
json.dump(man, open(man_path, "w"))

# Verify: reassemble == original
re = bytearray(size)
off = 0
for s, e in extents:
    ln = (e-s)*BLOCK
    re[s*BLOCK:s*BLOCK+ln] = data[off:off+ln]
    off += ln
assert hashlib.sha256(re).hexdigest() == man["sha256"], "reassembly mismatch!"
print(f"    image {size>>20} MiB -> {len(extents)} extents, "
      f"{len(data)>>20} MiB ({len(data)} bytes) of data")
PYEOF

echo "==> done:"
ls -la "$OUT" "$OUTDIR/rootfs-lean.data" "$OUTDIR/rootfs-lean.manifest.json"
