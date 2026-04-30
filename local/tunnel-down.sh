#!/bin/sh
# tunnel-down.sh — Tear down all tunnel-up.sh bridges + watchdogs +
# unregister the cached pairing code.
#
# Usage (in-guest):
#   wget -qO- https://www.traits.build/local/tunnel-down.sh | sh
#
# Equivalent to: tunnel-up.sh --reset (kept as a separate URL for
# discoverability and shell-pipe ergonomics).

set -u

TUNNEL_BASE="${TUNNEL_BASE:-https://traits-build-tunnel.fly.dev}"
TUNNEL_PID_FILE="${TUNNEL_PID_FILE:-/tmp/tunnel.pids}"
TUNNEL_CODE_FILE="${TUNNEL_CODE_FILE:-/tmp/tunnel.code}"

echo "[tunnel-down] killing bridges + watchdogs ..."

# Kill tracked PIDs first (precise).
if [ -s "$TUNNEL_PID_FILE" ]; then
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        kill "$pid" 2>/dev/null || true
    done < "$TUNNEL_PID_FILE"
fi

# Belt-and-suspenders cleanup for any orphans pre-dating the PID file.
pkill -f 'websocat.*port/guest\?code=' 2>/dev/null || true
pkill -f 'tunnel-up\.sh' 2>/dev/null || true

# Unregister cached code (if any) so the relay drops the session.
if [ -s "$TUNNEL_CODE_FILE" ]; then
    code=$(head -1 "$TUNNEL_CODE_FILE")
    if [ -n "$code" ]; then
        echo "[tunnel-down] unregistering $code"
        curl -sS --max-time 5 -X POST \
            "$TUNNEL_BASE/port/unregister" \
            -H 'Content-Type: application/json' \
            -d "{\"code\":\"$code\"}" >/dev/null 2>&1 || true
    fi
fi

rm -f "$TUNNEL_PID_FILE" "$TUNNEL_CODE_FILE"
echo "[tunnel-down] done."
