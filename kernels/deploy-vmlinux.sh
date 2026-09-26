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
# Usage: kernels/deploy-vmlinux.sh            (set LOT_ALLOW_DIRTY=1 to override)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
K="$HERE/linux"
FORK_URL="https://github.com/kilian-ai/linux"
FORK_BRANCH="wasm-linuxontab"
OUT="$REPO/shell/linux-dist/vmlinux.wasm"
export PATH="/opt/homebrew/opt/llvm@19/bin:$PATH"

[ -d "$K/.git" ] || { echo "ERROR: $K is not a git checkout — see kernels/README.md"; exit 1; }
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

echo "==> make tools/wasm/vmlinux.wasm ($SHA)"
make -C "$K" tools/wasm/vmlinux.wasm -j8

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'source=%s\nbranch=%s\ncommit=%s\nlicense=GPL-2.0 WITH Linux-syscall-note\nbuild=make tools/wasm/vmlinux.wasm (llvm@19); .linux.initramfs replaced by the 512-byte stub, initramfs.cpio is fetched separately\n' \
  "$FORK_URL" "$FORK_BRANCH" "$SHA" > "$TMP/source.txt"
# The stub is carried by every shipped vmlinux.wasm; take it from the current one.
node -e '
const fs=require("fs");const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));
const s=WebAssembly.Module.customSections(m,".linux.initramfs")[0];
if(!s||s.byteLength!==512){console.error("ERROR: current vmlinux.wasm has no 512-byte initramfs stub");process.exit(1)}
fs.writeFileSync(process.argv[2],Buffer.from(s))' "$OUT" "$TMP/stub.bin"
llvm-objcopy --remove-section=.linux.initramfs --add-section=.linux.initramfs="$TMP/stub.bin" \
  --remove-section=.linuxontab.source --add-section=.linuxontab.source="$TMP/source.txt" \
  "$K/tools/wasm/vmlinux.wasm" "$OUT"
cp "$TMP/source.txt" "$HERE/vmlinux.source"
echo "==> shipped $OUT"
cat "$HERE/vmlinux.source"
echo "Now: git add shell/linux-dist/vmlinux.wasm kernels/vmlinux.source && commit."
