#!/bin/sh
# Run after Docker build completes.
# Extracts WASM binaries from Nix results and packages them as .tar.gz
# suitable for download by the in-guest `apk` script.
#
# Usage: ./make-packages.sh <nix-result-dir> <output-dir>
#   e.g: ./make-packages.sh /tmp/wasm-pkgs /path/to/repo/packages
set -e

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
