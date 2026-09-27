#!/usr/bin/env sh
# Build kernels/linux and ship it as shell/linux-dist/vmlinux.wasm — the ONLY
# supported way to update the kernel binary, because it keeps the GPL
# corresponding-source pointer honest:
#   * refuses if the kernel tree has uncommitted changes (case-collision
#     files that macOS reports as modified are ignored, see KERNEL_IGNORE)
#   * refuses if HEAD is not on the public fork (kilian-ai/linux)
#   * embeds a `.linuxontab.source` custom section (fork URL + commit) in
#     the .wasm and writes the same to kernels/vmlinux.source
#   * swaps the 1 MB baked initramfs for the 512-byte stub (the page fetches
#     initramfs.cpio separately)
#
# Usage: kernels/deploy-vmlinux.sh [7.1|6.1]   (default 7.1; LOT_ALLOW_DIRTY=1 overrides)
#   7.1: kernels/linux-7.1 (branch wasm-linuxontab-7.1) -> shell/linux-dist-7.1/vmlinux.wasm
#   6.1: kernels/linux     (branch wasm-linuxontab)     -> shell/linux-dist/vmlinux.wasm
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
FORK_URL="https://github.com/kilian-ai/linux"
case "${1:-7.1}" in
7.1)
  K="$HERE/linux-7.1"; FORK_BRANCH="wasm-linuxontab-7.1"
  OUT="$REPO/shell/linux-dist-7.1/vmlinux.wasm"; SOURCE_FILE="$HERE/vmlinux-7.1.source"
  BUILT="$K/vmlinux.wasm"; MAKE_TARGET="vmlinux.wasm"; DEFCONFIG="linuxontab_defconfig" ;;
6.1)
  K="$HERE/linux"; FORK_BRANCH="wasm-linuxontab"
  OUT="$REPO/shell/linux-dist/vmlinux.wasm"; SOURCE_FILE="$HERE/vmlinux.source"
  BUILT="$K/tools/wasm/vmlinux.wasm"; MAKE_TARGET="tools/wasm/vmlinux.wasm"; DEFCONFIG="" ;;
*) echo "usage: $0 [7.1|6.1]"; exit 2 ;;
esac
MAKE="$(command -v gmake || echo make)"   # 7.1 needs GNU Make >= 4
export PATH="/opt/homebrew/opt/llvm@19/bin:$PATH"

git -C "$K" rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: $K is not a git checkout (or worktree) — see kernels/README.md"; exit 1; }
command -v llvm-objcopy >/dev/null || { echo "ERROR: llvm-objcopy (llvm@19) not on PATH"; exit 1; }

# Files that a case-insensitive checkout collapses onto their lowercase twins
# (xt_CONNMARK.h vs xt_connmark.h ...). They read as modified on macOS but
# are not edits; they are not part of the wasm build either.
KERNEL_IGNORE='include/uapi/linux/netfilter|net/netfilter/xt_|\.litmus$'
# Untracked files (??) are ignored too: they are not part of the build.
DIRTY="$(git -C "$K" status --porcelain | grep -v '^??' | grep -Ev "$KERNEL_IGNORE" || true)"
if [ -n "$DIRTY" ] && [ "${LOT_ALLOW_DIRTY:-}" != "1" ]; then
  echo "ERROR: kernels/linux has uncommitted changes — the shipped binary must correspond to a public commit:"
  echo "$DIRTY" | sed 's/^/  /'
  echo "Commit them (and push to $FORK_URL $FORK_BRANCH), or LOT_ALLOW_DIRTY=1 for a local-only test build."
  exit 1
fi
SHA="$(git -C "$K" rev-parse HEAD)"
git -C "$K" fetch -q linuxontab 2>/dev/null || true
if ! git -C "$K" merge-base --is-ancestor "$SHA" "linuxontab/$FORK_BRANCH" 2>/dev/null && [ "${LOT_ALLOW_DIRTY:-}" != "1" ]; then
  echo "ERROR: kernel commit $SHA is not on $FORK_URL $FORK_BRANCH — push it first:"
  echo "  git -C kernels/linux push linuxontab HEAD:$FORK_BRANCH"
  exit 1
fi

# Configure from the committed defconfig so the binary is fully described by
# the published commit (a stray local .config would not be).
if [ -n "$DEFCONFIG" ]; then
  echo "==> $MAKE $DEFCONFIG"
  "$MAKE" -C "$K" "$DEFCONFIG" >/dev/null
fi
echo "==> $MAKE $MAKE_TARGET ($SHA)"
"$MAKE" -C "$K" "$MAKE_TARGET" -j8

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'source=%s\nbranch=%s\ncommit=%s\nlicense=GPL-2.0 WITH Linux-syscall-note\nbuild=make %s%s (llvm@19); .linux.initramfs replaced by the 512-byte stub, initramfs.cpio is fetched separately\n' \
  "$FORK_URL" "$FORK_BRANCH" "$SHA" "${DEFCONFIG:+$DEFCONFIG }" "$MAKE_TARGET" > "$TMP/source.txt"
# The stub is carried by every shipped vmlinux.wasm; take it from the current one.
node -e '
const fs=require("fs");const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));
const s=WebAssembly.Module.customSections(m,".linux.initramfs")[0];
if(!s||s.byteLength!==512){console.error("ERROR: current vmlinux.wasm has no 512-byte initramfs stub");process.exit(1)}
fs.writeFileSync(process.argv[2],Buffer.from(s))' "$OUT" "$TMP/stub.bin"
llvm-objcopy --remove-section=.linux.initramfs --add-section=.linux.initramfs="$TMP/stub.bin" \
  --remove-section=.linuxontab.source --add-section=.linuxontab.source="$TMP/source.txt" \
  "$BUILT" "$OUT"
cp "$TMP/source.txt" "$SOURCE_FILE"
echo "==> shipped $OUT"
cat "$SOURCE_FILE"
echo "Now: git add ${OUT#$REPO/} ${SOURCE_FILE#$REPO/} && commit."
