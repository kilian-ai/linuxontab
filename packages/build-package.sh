#!/usr/bin/env bash
# build-package.sh — Build a WASM package from a recipe and publish to the registry
#
# Usage:
#   ./packages/build-package.sh <recipe-name>              # build from recipes/
#   ./packages/build-package.sh <recipe-name> --no-asyncify
#   ./packages/build-package.sh <recipe-name> --dry-run    # build only, no install to rootfs
#
# Environment overrides:
#   LOT_CLANG      path to wasm32 clang
#   LOT_SYSROOT    path to musl sysroot
#   LOT_WASM_LD    path to wasm-ld
#   LOT_WASM_OPT   path to wasm-opt
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RECIPES_DIR="$SCRIPT_DIR/recipes"
PKG_DIR="$SCRIPT_DIR"
ROOTFS_PKG_DIR="$REPO_ROOT/rootfs/packages"

# ── CLI args ────────────────────────────────────────────────────────────────
RECIPE_NAME=""
SKIP_ASYNCIFY=0
DRY_RUN=0
for _arg in "$@"; do
    case "$_arg" in
        --no-asyncify) SKIP_ASYNCIFY=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        -*)  echo "Unknown option: $_arg"; exit 1 ;;
        *)   RECIPE_NAME="$_arg" ;;
    esac
done

[ -n "$RECIPE_NAME" ] || { echo "Usage: $0 <recipe-name> [--no-asyncify] [--dry-run]"; exit 1; }

RECIPE="$RECIPES_DIR/$RECIPE_NAME.sh"
[ -f "$RECIPE" ] || { echo "Error: recipe not found: $RECIPE"; exit 1; }

# ── Toolchain detection ─────────────────────────────────────────────────────
_find_nix() {
    # Find the first match for a glob under /nix/store at depth 1 or 2
    local pat="$1"
    find /nix/store -maxdepth 3 -name "$pat" 2>/dev/null | sort | head -1
}

if [ -n "$LOT_CLANG" ]; then
    CLANG="$LOT_CLANG"
else
    # Prefer Nix clang 19.x (has wasm32 support matching our wasm-ld 19.1.7)
    # Avoid version-suffixed clangs from other Nix packages (21.x missing wasm32 builtins)
    CLANG=$(find /nix/store -maxdepth 3 -path "*/bin/clang" ! -path "*wrapper*" 2>/dev/null | grep "clang-19" | sort | head -1)
    [ -z "$CLANG" ] && CLANG=$(find /nix/store -maxdepth 3 -path "*/bin/clang" ! -path "*wrapper*" 2>/dev/null | sort | head -1)
    [ -z "$CLANG" ] && CLANG=$(find /nix/store -maxdepth 3 -path "*/bin/clang" 2>/dev/null | sort | head -1)
    [ -z "$CLANG" ] && command -v clang >/dev/null 2>&1 && CLANG="$(command -v clang)"
fi

if [ -n "$LOT_SYSROOT" ]; then
    SYSROOT="$LOT_SYSROOT"
elif [ -f "$REPO_ROOT/toolchain/musl-sysroot-fixed/lib/libc.a" ]; then
    # Prefer the repo sysroot: same as the Nix one but with the mallocng
    # alloc_meta fix (hardcoded 0x8000 meta-area base clobbering guest
    # memory). See toolchain/build-musl-sysroot-fixed.sh.
    SYSROOT="$REPO_ROOT/toolchain/musl-sysroot-fixed"
else
    SYSROOT=$(find /nix/store -maxdepth 1 -name "*musl-sysroot" -type d 2>/dev/null | sort | head -1)
fi

if [ -n "$LOT_WASM_LD" ]; then
    WASM_LD="$LOT_WASM_LD"
else
    WASM_LD=$(find /nix/store -maxdepth 3 -path "*/bin/wasm-ld" 2>/dev/null | sort | head -1)
    [ -z "$WASM_LD" ] && command -v wasm-ld >/dev/null 2>&1 && WASM_LD="$(command -v wasm-ld)"
fi

if [ -n "$LOT_WASM_OPT" ]; then
    WASM_OPT="$LOT_WASM_OPT"
else
    for _p in /opt/homebrew/bin/wasm-opt /usr/local/bin/wasm-opt; do
        [ -x "$_p" ] && WASM_OPT="$_p" && break
    done
    [ -z "$WASM_OPT" ] && command -v wasm-opt >/dev/null 2>&1 && WASM_OPT="$(command -v wasm-opt)"
fi

[ -x "$CLANG" ]   || { echo "Error: clang not found. Set LOT_CLANG= or install via Nix."; exit 1; }
[ -d "$SYSROOT" ] || { echo "Error: musl sysroot not found. Set LOT_SYSROOT=."; exit 1; }
[ -x "$WASM_LD" ] || { echo "Error: wasm-ld not found. Set LOT_WASM_LD=."; exit 1; }
[ $SKIP_ASYNCIFY -eq 1 ] || { [ -x "$WASM_OPT" ] || { echo "Error: wasm-opt not found. Set LOT_WASM_OPT= or: brew install binaryen"; exit 1; }; }

# Derive CC/AR/RANLIB wrappers the recipe can use
WASM_LD_DIR="$(dirname "$WASM_LD")"
CC="$CLANG -target wasm32 --sysroot=$SYSROOT -fuse-ld=lld"

# Use llvm-ar instead of macOS ar: macOS ar corrupts WASM binary .o files by
# appending extra \n padding bytes during archiving, causing wasm-ld to fail
# with "section too large" when reading the archive members.
LLVM_AR=$(find /nix/store -maxdepth 3 -name "llvm-ar" -path "*llvm-19*" 2>/dev/null | sort | head -1)
[ -z "$LLVM_AR" ] && LLVM_AR=$(find /nix/store -maxdepth 3 -name "llvm-ar" 2>/dev/null | sort | head -1)
[ -z "$LLVM_AR" ] && LLVM_AR="ar"

LLVM_RANLIB=$(find /nix/store -maxdepth 3 -name "llvm-ranlib" -path "*llvm-19*" 2>/dev/null | sort | head -1)
[ -z "$LLVM_RANLIB" ] && LLVM_RANLIB=$(find /nix/store -maxdepth 3 -name "llvm-ranlib" 2>/dev/null | sort | head -1)
[ -z "$LLVM_RANLIB" ] && LLVM_RANLIB="ranlib"

# compiler-rt builtins: provides __tf* (128-bit float), __fixunsdfsi, etc.
# musl's vfprintf pulls these in for %Lf support. Located in the sysroot.
# Use explicit path construction first (most reliable), then fall back to find.
BUILTINS="$SYSROOT/lib/clang/19/lib/wasm32-unknown-linux-musl/libclang_rt.builtins.a"
[ -f "$BUILTINS" ] || BUILTINS=$(find "$SYSROOT/lib/clang" -name "libclang_rt.builtins.a" -path "*/wasm32-unknown-linux-musl/*" 2>/dev/null | head -1)
[ -f "$BUILTINS" ] || BUILTINS=$(find "$SYSROOT/lib/clang" -name "libclang_rt.builtins.a" 2>/dev/null | head -1)

export CC CLANG SYSROOT WASM_LD WASM_OPT BUILTINS
export AR="$LLVM_AR"
export RANLIB="$LLVM_RANLIB"

echo "==> Toolchain:"
echo "    CLANG    : ${CLANG:-NOT FOUND}"
echo "    SYSROOT  : ${SYSROOT:-NOT FOUND}"
echo "    WASM_LD  : ${WASM_LD:-NOT FOUND}"
echo "    WASM_OPT : ${WASM_OPT:-NOT FOUND}"
echo "    AR       : ${AR:-NOT FOUND}"
echo "    BUILTINS : ${BUILTINS:-(none)}"

# Standard CFLAGS for wasm32-linux-musl
# -matomics -mbulk-memory: required when linking with --shared-memory (wasm threads proposal)
export CFLAGS="-O2 -matomics -mbulk-memory"

# CRT1: the musl startup object — must be first in linker inputs
export CRT1="$SYSROOT/lib/crt1.o"

# Standard LDFLAGS: import-memory required for asyncify compatibility.
# -nostdlib: avoid clang searching for missing wasm32 libclang_rt.builtins.a;
#   instead link crt1.o explicitly (via CRT1) and add -lc from sysroot.
export LDFLAGS="-nostdlib -static \
  -Wl,--import-memory \
  -Wl,--export-memory \
  -Wl,--export-table \
  -Wl,--export=__heap_base \
  -Wl,--export=__data_end \
  -Wl,--shared-memory \
  -Wl,--max-memory=268435456"

# LIBS: appended after user objects when calling CC directly.
# Recipes that drive their own Makefile should add these after object files.
# BUILTINS last: libc references __tf* symbols which come from compiler-rt.
export LIBS_TRAIL="$CRT1 -lc -lm $BUILTINS"

# Make wasm-ld available on PATH for Makefiles that look for it
export PATH="$WASM_LD_DIR:$PATH"

# ── Load recipe ──────────────────────────────────────────────────────────────
NAME=""
VERSION=""
DESCRIPTION=""
SOURCE_URL=""
SOURCE_SHA256=""

. "$RECIPE"

[ -n "$NAME" ]       || NAME="$RECIPE_NAME"
[ -n "$VERSION" ]    || { echo "Error: recipe must set VERSION="; exit 1; }
[ -n "$SOURCE_URL" ] || { echo "Error: recipe must set SOURCE_URL="; exit 1; }

echo ""
echo "==> Building $NAME-$VERSION"
echo "    Source : $SOURCE_URL"
echo "    Recipe : $RECIPE"

# ── Work directories ─────────────────────────────────────────────────────────
BUILD_ROOT="/tmp/lot-build/$NAME"
SRC="$BUILD_ROOT/src"
STAGE="$BUILD_ROOT/stage"
export SRC STAGE

rm -rf "$BUILD_ROOT"
mkdir -p "$SRC" "$STAGE/bin"

# ── Fetch + extract source ───────────────────────────────────────────────────
ARCHIVE="/tmp/lot-src-$NAME.tar.gz"
if [ ! -f "$ARCHIVE" ]; then
    echo "==> Downloading $SOURCE_URL"
    curl -L --fail -o "$ARCHIVE" "$SOURCE_URL" || \
        { echo "Error: download failed: $SOURCE_URL"; exit 1; }
fi

if [ -n "$SOURCE_SHA256" ]; then
    actual="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
    [ "$actual" = "$SOURCE_SHA256" ] || {
        echo "Error: checksum mismatch"
        echo "  expected: $SOURCE_SHA256"
        echo "  actual  : $actual"
        exit 1
    }
fi

echo "==> Extracting source"
tar xzf "$ARCHIVE" -C "$SRC" --strip-components=1

# ── Run build ────────────────────────────────────────────────────────────────
echo "==> Running build() from recipe"
cd "$SRC"
build

# ── Safety net: fix mallocng alloc_meta if a buggy libc got linked in ────────
# The unpatched wasm32-musl mallocng discards sbrk()'s return and uses the
# hardcoded address 0x8000 as its meta-area base, overwriting guest memory
# at 0x8000–0xC000. The fixed sysroot (toolchain/musl-sysroot-fixed) makes
# this a no-op; this catches binaries linked against a stale/other libc.
# Must run BEFORE asyncify (wasm-opt rewrites the code section).
#   before: 41 7f 46 0d 03 41 80 80 02 21 02  (const -1; eq; br_if; const 0x8000; local.set N)
#   after:  22 02 41 7f 46 0d 03 01 01 01 01  (local.tee N = sbrk ret; const -1; eq; br_if; nops)
echo "==> Checking for buggy mallocng alloc_meta (hardcoded 0x8000)"
while IFS= read -r f; do
    [ -f "$f" ] || continue
    magic=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$magic" in 0061736d*) ;; *) continue ;; esac
    python3 - "$f" << 'PYEOF'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
old = bytes.fromhex('417f460d03418080022102')
new = bytes.fromhex('2202417f460d0301010101')
n = data.count(old)
if n == 0:
    sys.exit(0)  # clean (fixed sysroot) or already patched
if n > 1:
    sys.exit(f"ERROR: {path}: alloc_meta 0x8000 pattern found {n} times (expected <=1); refusing to patch")
i = data.find(old)
data[i:i+len(old)] = new
open(path, 'wb').write(data)
print(f"    WARN: {path} was linked against an UNFIXED libc; alloc_meta byte-patched at 0x{i:x}")
print(f"          (rebuild toolchain/musl-sysroot-fixed or check LOT_SYSROOT)")
PYEOF
    [ $? -eq 0 ] || { echo "Error: alloc_meta check failed on $f"; exit 1; }
done < <(find "$STAGE" -type f ! -name "*.a" ! -name "*.la" ! -name "*.h" ! -name "*.pc" ! -name "info")

# ── Asyncify all WASM binaries in $STAGE ─────────────────────────────────────
if [ $SKIP_ASYNCIFY -eq 0 ]; then
    echo "==> Asyncifying WASM binaries"
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        # Skip non-WASM files (check magic bytes: \0asm = 00 61 73 6d)
        magic=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
        case "$magic" in
            0061736d*) ;;   # WASM magic
            *) continue ;;
        esac
        echo "    asyncify: $f (opt: ${LOT_ASYNCIFY_EXTRA:--O1})"
        tmp="$f.tmp-asyncify"
        # LOT_ASYNCIFY_EXTRA (default -O1): optimize the asyncified output.
        # Asyncify inflates per-function native stack frames; unoptimized output
        # blows V8's call stack on call depths that used to fit (qjs segfaulted
        # on the node wrapper's console path, CPython on deep recursion), so
        # -O1 is the DEFAULT — set LOT_ASYNCIFY_EXTRA to override (e.g. "-O2").
        # Every other pipeline (build-rootfs.sh, rebuild-sshd-wasm.sh) already
        # hardcodes --asyncify -O1.
        # --enable-exception-handling: packages built with the native wasm-EH
        # setjmp/longjmp lowering (-mllvm -wasm-enable-sjlj) carry a wasm tag +
        # try/catch/throw. Asyncify must be told the EH feature is on or it
        # errors on those instructions. Harmless for non-EH binaries (just
        # enables an unused feature). Required for zsh/ash/Xvfb-class ports.
        # shellcheck disable=SC2086
        "$WASM_OPT" --enable-exception-handling --asyncify ${LOT_ASYNCIFY_EXTRA:--O1} "$f" -o "$tmp" \
            && mv "$tmp" "$f" && chmod +x "$f" \
            || { echo "Error: wasm-opt failed on $f"; rm -f "$tmp"; exit 1; }
    done < <(find "$STAGE" -type f ! -name "*.a" ! -name "*.la" ! -name "*.h" ! -name "*.pc" ! -name "info")
fi

# ── Verify import-memory ─────────────────────────────────────────────────────
echo "==> Verifying binaries"
while IFS= read -r f; do
    [ -f "$f" ] || continue
    magic=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$magic" in 0061736d*) ;; *) continue ;; esac
    if ! command -v wasm-objdump >/dev/null 2>&1; then continue; fi
    check="$(wasm-objdump -x "$f" 2>/dev/null | grep -i memory || true)"
    case "$check" in
        *'<- env.memory'*)         echo "    OK: $f (imports memory from kernel)" ;;
        *'Memory['*)               echo "    WARN: $f has own memory section — add --import-memory to LDFLAGS!" ;;
        *)                         echo "    ?: $f — could not verify memory imports" ;;
    esac
done < <(find "$STAGE" -type f ! -name "*.a" ! -name "*.la" ! -name "*.h" ! -name "*.pc" ! -name "info")

# ── Pack tarball ─────────────────────────────────────────────────────────────
echo "==> Packing $NAME-$VERSION"
TARNAME="$NAME-$VERSION.tar.gz"
TAROUT="$PKG_DIR/$TARNAME"

TMPDIR="/tmp/lot-pack-$NAME"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR/pkg-$NAME"
cp -r "$STAGE/." "$TMPDIR/pkg-$NAME/"

# Write package metadata. DEPENDS (optional, set in the recipe as a
# space-separated list of package names) is the runtime dependency list that
# the in-guest `apk` resolves before installing this package. Our binaries are
# statically linked, so these are TOOL/SERVICE deps (e.g. xeyes needs the Xvfb
# server + x11vnc viewer), not shared-library deps.
cat > "$TMPDIR/pkg-$NAME/info" << EOF
name=$NAME
version=$VERSION
description=${DESCRIPTION:-$NAME}
depends=${DEPENDS:-}
built_with=lot-build-package
target=wasm32-linux-musl
EOF

tar czf "$TAROUT" -C "$TMPDIR" "pkg-$NAME"
SIZE="$(wc -c < "$TAROUT" | tr -d ' ')"
SHA="$(shasum -a 256 "$TAROUT" | cut -d' ' -f1)"
echo "    => $TAROUT ($SIZE bytes)"
echo "    sha256: $SHA"

# ── Update index files ────────────────────────────────────────────────────────
_update_index() {
    local idx_file="$1"
    [ -f "$idx_file" ] || return
    python3 - "$idx_file" "$NAME" "$VERSION" "${DESCRIPTION:-$NAME}" \
        "$TARNAME" "$SIZE" "$SHA" "${DEPENDS:-}" << 'PY'
import json, sys, datetime
idx_file, name, version, description, tarname, size, sha, depends = sys.argv[1:]
with open(idx_file) as f:
    idx = json.load(f)
idx.setdefault("packages", {})[name] = {
    "version": version,
    "description": description,
    "url": f"https://linuxontab.com/packages/{tarname}",
    "size": int(size),
    "sha256": sha,
    "bins": [name],
    "depends": depends.split(),
    "status": "available"
}
idx["generated"] = datetime.date.today().isoformat()
with open(idx_file, "w") as f:
    json.dump(idx, f, indent=2)
    f.write("\n")
print(f"Updated: {idx_file}")
PY
}

echo "==> Updating package indexes"
_update_index "$PKG_DIR/index.json"

if [ $DRY_RUN -eq 0 ]; then
    # Install tarball into rootfs package cache
    cp "$TAROUT" "$ROOTFS_PKG_DIR/$TARNAME"
    # Update rootfs index (uses local URL for fast in-VM access)
    python3 - "$ROOTFS_PKG_DIR/index.json" "$NAME" "$VERSION" "${DESCRIPTION:-$NAME}" \
        "$TARNAME" "$SIZE" "$SHA" "${DEPENDS:-}" << 'PY'
import json, sys, datetime
idx_file, name, version, description, tarname, size, sha, depends = sys.argv[1:]
with open(idx_file) as f:
    idx = json.load(f)
idx.setdefault("packages", {})[name] = {
    "version": version,
    "description": description,
    "url": f"https://linuxontab.com/packages/{tarname}",
    "size": int(size),
    "sha256": sha,
    "bins": [name],
    "depends": depends.split(),
    "status": "available"
}
idx["generated"] = datetime.date.today().isoformat()
with open(idx_file, "w") as f:
    json.dump(idx, f, indent=2)
    f.write("\n")
print(f"Updated: {idx_file}")
PY
    echo ""
    echo "==> Installed to rootfs. Rebuild rootfs.ext4:"
    echo "    ./build-rootfs.sh"
else
    echo "==> Dry run — skipped rootfs install"
fi

echo ""
echo "Done: $NAME-$VERSION"
echo ""
echo "Next steps:"
echo "  1. Test: install to running guest via SCP"
echo "     scp -P 2222 $TAROUT root@localhost:/packages/"
echo "     # then in guest: apk update && apk add $NAME"
echo "  2. Bake into rootfs: ./build-rootfs.sh"
echo "  3. Publish: git add packages/ && git commit -m 'packages: add $NAME $VERSION'"
