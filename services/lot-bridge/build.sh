#!/usr/bin/env bash
# Build lot-bridge as a static i686-unknown-linux-musl binary using `cross`.
# Requires Docker running and `cross` installed (`cargo install cross`).
set -euo pipefail
cd "$(dirname "$0")"

TARGET=i686-unknown-linux-musl

echo "[build] checking cross..."
if ! command -v cross &>/dev/null; then
  echo "[build] cross not found — installing (cargo install cross)..."
  cargo install cross --locked
fi

echo "[build] building for ${TARGET}..."
cross build --target "${TARGET}" --release

BIN="target/${TARGET}/release/lot-bridge"
echo "[build] binary: ${BIN} ($(du -sh "${BIN}" | cut -f1))"
echo "[build] done."
echo ""
echo "To upload to the running guest (tunnel code from /tmp/lot-bridge.code or tunnel-up.sh):"
echo "  sh <(curl -sS https://linuxontab.com/local/tunnel-listen.sh) CODE"
echo "  scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\"
echo "    ${BIN} root@localhost:/usr/local/bin/lot-bridge"
echo ""
echo "Or make available via GitHub Pages (after pushing main):"
echo "  cp ${BIN} ../../local/lot-bridge"
echo "  git add ../../local/lot-bridge && git commit -m 'local: add lot-bridge i686-musl binary'"
