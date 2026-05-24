#!/bin/sh
# Run after wasm-distro Nix build completes.
# Extracts and asyncifies WASM binaries from Nix results, packages them as
# .tar.gz tarballs suitable for download by the in-guest `apk` script.
#
# Usage: ./make-packages.sh <wasm-distro-dir> <output-dir>
#   e.g: ./make-packages.sh /tmp/wasm-distro /path/to/LinuxOnTab-kernel/rootfs/packages
#
# The tarball layout is:
#   pkg-<name>/sbin/...       → installed to /sbin/
#   pkg-<name>/usr/bin/...    → installed to /usr/bin/
#   pkg-<name>/bin/...        → installed to /bin/
#   pkg-<name>/info           → package metadata (not installed)
#
# Wasmer.io/WAPM packages are NOT compatible with this repo — they use WASI
# (wasi_snapshot_preview1) rather than the Linux syscall ABI (linux.syscall.*).

set -e

WASM_DISTRO="${1:-/private/tmp/wasm-distro}"
OUT="${2:-/Users/kilian/.ai/LinuxOnTab-kernel/rootfs/packages}"
SFTP_SERVER="${3:-/Users/kilian/.ai/LinuxOnTab-kernel/rootfs/usr/lib/sftp-server}"
WASM_OPT="${WASM_OPT:-wasm-opt}"

mkdir -p "$OUT"

# Asyncify a WASM binary (skip if already done)
asyncify_bin() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if wasm-dis "$src" 2>/dev/null | grep -q asyncify_start_unwind; then
        cp "$src" "$dst"
    else
        "$WASM_OPT" --asyncify -O1 "$src" -o "$dst"
    fi
    chmod +x "$dst"
}

# Find the Nix result for a given package name
_nix_result() {
    local name="$1"
    # Try <distro>/result-* symlinks pointing to store path with that name
    for l in "$WASM_DISTRO"/result*; do
        [ -L "$l" ] || continue
        local target
        target=$(readlink "$l")
        case "$target" in *-$name|*-$name-*) echo "$l"; return ;; esac
    done
    # Try direct nix build
    if command -v nix >/dev/null 2>&1; then
        nix build "$WASM_DISTRO#$name" --accept-flake-config --no-link --print-out-paths 2>/dev/null
    fi
}

# _pkg_bin: asyncify all WASM files from $src_dir and put in $dst_dir
_copy_bins() {
    local src_dir="$1" dst_dir="$2"
    [ -d "$src_dir" ] || return 0
    for f in "$src_dir"/*; do
        [ -f "$f" ] || continue
        local magic
        magic=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
        if [ "$magic" = "0061736d" ]; then
            asyncify_bin "$f" "$dst_dir/$(basename "$f")"
            echo "  [asyncify] $dst_dir/$(basename "$f")"
        fi
    done
}

pack_pkg() {
    local name="$1"

    local result
    result=$(_nix_result "$name")
    if [ -z "$result" ]; then
        echo "SKIP: no Nix result found for $name"
        return
    fi

    local store_path
    store_path=$(readlink "$result" 2>/dev/null || echo "$result")
    local version
    version=$(basename "$store_path" | sed "s/^[a-z0-9]*-$name-//")
    [ -n "$version" ] && [ "$version" != "$(basename "$store_path")" ] || version="0.0.0"

    local tmpdir="/tmp/pkg-work-$name/pkg-$name"
    rm -rf "/tmp/pkg-work-$name" && mkdir -p "$tmpdir"

    # Copy binaries from all standard dirs, asyncifying each WASM file
    for dir in bin sbin usr/bin usr/sbin usr/lib lib; do
        _copy_bins "$store_path/$dir" "$tmpdir/$dir"
    done

    # Check we got something
    local got
    got=$(find "$tmpdir" -type f | grep -v '/info' | wc -l | tr -d ' ')
    if [ "$got" = "0" ]; then
        echo "SKIP: no binaries found in $name result ($store_path)"
        rm -rf "/tmp/pkg-work-$name"
        return
    fi

    cat > "$tmpdir/info" <<EOF
name=$name
version=$version
built_with=tombl/distro
target=wasm32-linux-musl
EOF

    local tarname="$name-$version.tar.gz"
    tar czf "$OUT/$tarname" -C "/tmp/pkg-work-$name" "pkg-$name/"
    local size sha
    size=$(wc -c < "$OUT/$tarname" | tr -d ' ')
    sha=$(shasum -a 256 "$OUT/$tarname" | cut -d' ' -f1)
    echo "PACKED: $tarname ($size bytes, sha256=$sha)"
    rm -rf "/tmp/pkg-work-$name"

    # Collect bin paths for the index
    local bins
    bins=$(find "$OUT" -maxdepth 0 -name "x" 2>/dev/null; \
           tar tzf "$OUT/$tarname" | grep -v '/$' | grep -v 'pkg-[^/]*/info' | \
           sed "s|pkg-$name/||" | tr '\n' ',' | sed 's/,$//')

    echo "PKG_RECORD_${name}_tarname=$tarname"    >> "$OUT/.index-data.sh"
    echo "PKG_RECORD_${name}_version=$version"   >> "$OUT/.index-data.sh"
    echo "PKG_RECORD_${name}_size=$size"         >> "$OUT/.index-data.sh"
    echo "PKG_RECORD_${name}_sha=$sha"           >> "$OUT/.index-data.sh"
    echo "PKG_RECORD_${name}_bins=$bins"         >> "$OUT/.index-data.sh"
}

pack_dropbear() {
    # Dropbear needs special handling: it needs the sftp-server from the host
    # build alongside the Nix-provided binaries.
    local result
    result=$(_nix_result "dropbear")
    if [ -z "$result" ]; then
        echo "SKIP: no Nix result for dropbear"
        return
    fi
    local store_path
    store_path=$(readlink "$result" 2>/dev/null || echo "$result")
    local version
    version=$(basename "$store_path" | sed 's/^[a-z0-9]*-dropbear-//')
    [ -n "$version" ] && [ "$version" != "$(basename "$store_path")" ] || version="2024.86"

    local tmpdir="/tmp/pkg-work-dropbear/pkg-dropbear"
    rm -rf "/tmp/pkg-work-dropbear" && mkdir -p "$tmpdir"

    for dir in bin sbin usr/bin usr/sbin; do
        _copy_bins "$store_path/$dir" "$tmpdir/$dir"
    done

    # Include the host-compiled asyncified sftp-server
    if [ -f "$SFTP_SERVER" ]; then
        mkdir -p "$tmpdir/usr/lib"
        cp "$SFTP_SERVER" "$tmpdir/usr/lib/sftp-server"
        chmod +x "$tmpdir/usr/lib/sftp-server"
        echo "  [copy] usr/lib/sftp-server"
    fi

    cat > "$tmpdir/info" <<EOF
name=dropbear
version=$version
built_with=tombl/distro
target=wasm32-linux-musl
EOF

    local tarname="dropbear-$version.tar.gz"
    tar czf "$OUT/$tarname" -C "/tmp/pkg-work-dropbear" "pkg-dropbear/"
    local size sha
    size=$(wc -c < "$OUT/$tarname" | tr -d ' ')
    sha=$(shasum -a 256 "$OUT/$tarname" | cut -d' ' -f1)
    echo "PACKED: $tarname ($size bytes, sha256=$sha)"
    rm -rf "/tmp/pkg-work-dropbear"

    echo "PKG_RECORD_dropbear_tarname=$tarname"             >> "$OUT/.index-data.sh"
    echo "PKG_RECORD_dropbear_version=$version"            >> "$OUT/.index-data.sh"
    echo "PKG_RECORD_dropbear_size=$size"                  >> "$OUT/.index-data.sh"
    echo "PKG_RECORD_dropbear_sha=$sha"                    >> "$OUT/.index-data.sh"
    echo 'PKG_RECORD_dropbear_bins=sbin/dropbear,usr/sbin/sshd,usr/bin/ssh,usr/bin/ssh-keygen,bin/dbclient,bin/dropbearkey,usr/lib/sftp-server' \
                                                           >> "$OUT/.index-data.sh"
}

# ── Main ──────────────────────────────────────────────────────────────────────
rm -f "$OUT/.index-data.sh"

pack_pkg busybox
pack_pkg sqlite3
pack_dropbear

# Regenerate index.json from collected records
if [ -f "$OUT/.index-data.sh" ]; then
    . "$OUT/.index-data.sh"
    python3 - "$OUT" << 'PY'
import json, sys, os

DESCRIPTIONS = {
    "busybox":  "Swiss Army Knife of embedded Linux (WASM)",
    "sqlite3":  "Serverless SQL database engine",
    "dropbear": "Lightweight SSH server and client (dropbear, sshd, ssh)",
}

out = sys.argv[1]
env = os.environ

# Collect all package names from env keys
pkgs = set()
for k in env:
    if k.startswith("PKG_RECORD_") and k.endswith("_tarname"):
        pkgs.add(k[len("PKG_RECORD_"):-len("_tarname")])

index_file = os.path.join(out, "index.json")
try:
    with open(index_file) as f:
        idx = json.load(f)
except Exception:
    idx = {"version": 1, "packages": {}}

for pkg in sorted(pkgs):
    prefix = f"PKG_RECORD_{pkg}_"
    tarname = env.get(prefix + "tarname", "")
    version = env.get(prefix + "version", "0.0.0")
    size    = int(env.get(prefix + "size", "0"))
    sha     = env.get(prefix + "sha", "")
    bins    = [b for b in env.get(prefix + "bins", pkg).split(",") if b]
    idx["packages"][pkg] = {
        "version":     version,
        "description": DESCRIPTIONS.get(pkg, pkg),
        "url":         f"http://192.168.86.1/packages/{tarname}",
        "size":        size,
        "sha256":      sha,
        "bins":        bins,
        "status":      "available",
    }
    print(f"Updated index: {pkg} {version}")

import datetime
idx["generated"] = datetime.date.today().isoformat()
with open(index_file, "w") as f:
    json.dump(idx, f, indent=2)
    f.write("\n")
print(f"Wrote {index_file}")
PY
fi

echo ""
echo "=== Packages in $OUT ==="
ls -lh "$OUT"/*.tar.gz 2>/dev/null || echo "(none)"


WASM_PKGS="${1:-/tmp/wasm-pkgs}"
OUT="${2:-/Users/kilian/.ai/LinuxOnTab-kernel/packages}"

mkdir -p "$OUT"

pack_pkg() {
    local name="$1"
    local result_link="$WASM_PKGS/$name-result"
    if [ ! -L "$result_link" ] && [ ! -d "$result_link" ]; then
        echo "SKIP: $name-result not found"
        return
    fi

    # Detect version from the store path (e.g. /nix/store/xxx-sqlite3-3.51.0/)
    local store_path
    store_path=$(readlink "$result_link" 2>/dev/null || echo "$result_link")
    local version
    version=$(basename "$store_path" | sed "s/^[a-z0-9]*-$name-//")
    [ -n "$version" ] || version="0.0.0"

    local tmpdir="/tmp/pkg-$name"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir/bin"

    # Copy all files from bin/
    if [ -d "$result_link/bin" ]; then
        cp -r "$result_link/bin/"* "$tmpdir/bin/" 2>/dev/null || true
    fi

    # If single-file result (e.g. busybox is just the binary)
    if [ -f "$result_link" ]; then
        cp "$result_link" "$tmpdir/bin/$name"
    fi

    # Check we got something
    if [ -z "$(ls -A "$tmpdir/bin" 2>/dev/null)" ]; then
        echo "SKIP: no bin/ files in $name result"
        rm -rf "$tmpdir"
        return
    fi

    # Write metadata
    cat > "$tmpdir/info" << EOF
name=$name
version=$version
built_with=tombl/distro
target=wasm32-linux-musl
EOF

    local tarname="$name-$version.tar.gz"
    tar czf "$OUT/$tarname" -C /tmp "pkg-$name"
    local size sha
    size=$(wc -c < "$OUT/$tarname" | tr -d ' ')
    sha=$(shasum -a 256 "$OUT/$tarname" | cut -d' ' -f1)
    echo "PACKED: $tarname ($size bytes, sha256=$sha)"

    # Emit JSON fragment for index update
    cat >> "$OUT/.index-fragments.txt" << EOF
  "$name": {
    "version": "$version",
    "url": "https://linuxontab.com/packages/$tarname",
    "size": $size,
    "sha256": "$sha",
    "bins": ["$name"]
  },
EOF

    rm -rf "$tmpdir"
}

# Remove old fragments
rm -f "$OUT/.index-fragments.txt"

pack_pkg busybox
pack_pkg sqlite3

# Regenerate index.json
if [ -f "$OUT/.index-fragments.txt" ]; then
    python3 - "$OUT" << 'PY'
import json, sys, os, re

out = sys.argv[1]
index_file = os.path.join(out, "index.json")
try:
    with open(index_file) as f:
        idx = json.load(f)
except Exception:
    idx = {"version": 1, "packages": {}}

frags = open(os.path.join(out, ".index-fragments.txt")).read()
# Parse fragments as JSON object values
for m in re.finditer(r'"(\w+)":\s*(\{[^}]+\})', frags, re.DOTALL):
    name = m.group(1)
    try:
        val = json.loads(m.group(2).rstrip(","))
        val["description"] = {
            "busybox": "Swiss Army Knife of embedded Linux (WASM)",
            "sqlite3": "Serverless SQL database engine",
        }.get(name, name)
        val["status"] = "available"
        idx["packages"][name] = val
        print(f"Updated index: {name} {val['version']}")
    except Exception as e:
        print(f"Warning: could not parse {name}: {e}")

idx["generated"] = __import__("datetime").date.today().isoformat()
with open(index_file, "w") as f:
    json.dump(idx, f, indent=2)
    f.write("\n")
print(f"Wrote {index_file}")
PY
fi

echo ""
echo "=== Packages in $OUT ==="
ls -lh "$OUT"/*.tar.gz 2>/dev/null || echo "(none yet)"
echo ""
echo "Run after copying to repo:"
echo "  cd /Users/kilian/.ai/LinuxOnTab-kernel"
echo "  git add packages/ && git commit -m 'feat: add WASM package registry'"
