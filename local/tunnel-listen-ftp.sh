#!/bin/sh
# tunnel-listen-ftp.sh — Open local FTP control + passive listeners to a tunnel code.
#
# USAGE FLOW:
#   1. In guest shell: sh <(curl -sS https://www.traits.build/local/tunnel-up.sh) 21
#      → outputs pairing CODE (e.g., P52Y)
#   2. On Mac: sh <(curl -sS https://www.traits.build/local/tunnel-listen-ftp.sh) P52Y
#      → opens local FTP listeners on 127.0.0.1:2121 + passive range
#   3. In FTP client: Connect to 127.0.0.1 port 2121 (NOT port 21)
#
# Usage:
#   tunnel-listen-ftp.sh CODE [local_control_port] [remote_control_port] [pasv_min] [pasv_max]
#
# Defaults:
#   local_control_port = 2121 (use this port in your FTP client!)
#   remote_control_port = 21 (guest FTP server port)
#   pasv_min = 30000
#   pasv_max = 30010
#
# One-liner:
#   sh <(curl -sS https://www.traits.build/local/tunnel-listen-ftp.sh) CODE
#
# FTP client settings (lftp, Transmit, FileZilla, etc):
#   Host: 127.0.0.1
#   Port: 2121 (or your custom local_control_port)
#   Passive mode: ON (required)
#   Username: root
#   Password: (set in guest via `passwd` or authorized_keys)

set -u

CODE="${1:?usage: tunnel-listen-ftp.sh CODE [local_control_port] [remote_control_port] [pasv_min] [pasv_max]}"
LOCAL_CTRL_PORT="${2:-2121}"
REMOTE_CTRL_PORT="${3:-21}"
PASV_MIN="${4:-30000}"
PASV_MAX="${5:-30010}"

# Override via env: TUNNEL_WS=ws://localhost:8787 sh tunnel-listen-ftp.sh CODE
TUNNEL_WS="${TUNNEL_WS:-wss://traits-build-tunnel.fly.dev}"
TUNNEL_WS_FALLBACK="wss://tunnel.traits.build"

if ! command -v websocat >/dev/null 2>&1; then
    echo "[tunnel-listen-ftp] websocat not found — install via: brew install websocat" >&2
    exit 1
fi

is_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

for n in "$LOCAL_CTRL_PORT" "$REMOTE_CTRL_PORT" "$PASV_MIN" "$PASV_MAX"; do
    if ! is_int "$n"; then
        echo "[tunnel-listen-ftp] invalid numeric value: $n" >&2
        exit 1
    fi
done

if [ "$PASV_MIN" -gt "$PASV_MAX" ]; then
    echo "[tunnel-listen-ftp] invalid passive range: $PASV_MIN-$PASV_MAX" >&2
    exit 1
fi

relay_status_json_for_ws() {
    ws_base="$1"
    curl -fsS "https://${ws_base#*://}/port/status?code=${CODE}" 2>/dev/null || true
}

ensure_remote_port_registered() {
    check_port="$1"
    status_json="$2"
    printf '%s' "$status_json" | grep -q "\"registered_ports\"" || return 1
    printf '%s' "$status_json" | grep -q "\[$check_port\(,\|]\)" && return 0
    printf '%s' "$status_json" | grep -q ",$check_port\(,\|]\)" && return 0
    return 1
}

is_complete_registration() {
    status_json="$1"
    if ! ensure_remote_port_registered "$REMOTE_CTRL_PORT" "$status_json"; then
        return 1
    fi
    p="$PASV_MIN"
    while [ "$p" -le "$PASV_MAX" ]; do
        if ! ensure_remote_port_registered "$p" "$status_json"; then
            return 1
        fi
        p=$((p + 1))
    done
    return 0
}

status_primary="$(relay_status_json_for_ws "$TUNNEL_WS")"
status_fallback=""
if [ "$TUNNEL_WS" != "$TUNNEL_WS_FALLBACK" ]; then
    status_fallback="$(relay_status_json_for_ws "$TUNNEL_WS_FALLBACK")"
fi

if [ -n "$status_primary" ] && is_complete_registration "$status_primary"; then
    status_json="$status_primary"
elif [ -n "$status_fallback" ] && is_complete_registration "$status_fallback"; then
    TUNNEL_WS="$TUNNEL_WS_FALLBACK"
    status_json="$status_fallback"
elif [ -n "$status_primary" ]; then
    status_json="$status_primary"
elif [ -n "$status_fallback" ]; then
    TUNNEL_WS="$TUNNEL_WS_FALLBACK"
    status_json="$status_fallback"
else
    status_json=""
fi

if [ -n "$status_json" ]; then
    if ! ensure_remote_port_registered "$REMOTE_CTRL_PORT" "$status_json"; then
        echo "[tunnel-listen-ftp] relay code ${CODE} is missing control port ${REMOTE_CTRL_PORT} registration" >&2
        echo "[tunnel-listen-ftp] re-run guest side: sh <(curl -sS https://www.traits.build/local/tunnel-up.sh) ${REMOTE_CTRL_PORT}" >&2
        exit 1
    fi

    missing_pasv=""
    p="$PASV_MIN"
    while [ "$p" -le "$PASV_MAX" ]; do
        if ! ensure_remote_port_registered "$p" "$status_json"; then
            missing_pasv="$missing_pasv $p"
        fi
        p=$((p + 1))
    done
    if [ -n "$missing_pasv" ]; then
        echo "[tunnel-listen-ftp] relay code ${CODE} is missing passive ports:${missing_pasv}" >&2
        echo "[tunnel-listen-ftp] ls/mkdir/put/get will fail without passive registration" >&2
        echo "[tunnel-listen-ftp] re-run guest side with updated script: sh <(curl -sS https://www.traits.build/local/tunnel-up.sh) ${REMOTE_CTRL_PORT}" >&2
        exit 1
    fi
fi

PIDS=""

start_listener() {
    local_port="$1"
    remote_port="$2"
    ws_url="${TUNNEL_WS}/port/client?code=${CODE}&port=${remote_port}"
    # -E exits when one side disconnects; each new local connection gets a fresh WS.
    websocat --binary -E "tcp-l:127.0.0.1:${local_port}" "$ws_url" >/tmp/tunnel-ftp-${local_port}.log 2>&1 &
    pid="$!"
    PIDS="$PIDS $pid"
    echo "[tunnel-listen-ftp] 127.0.0.1:${local_port} -> tunnel:${CODE} remote:${remote_port} (pid $pid)"
}

cleanup() {
    echo ""
    echo "[tunnel-listen-ftp] stopping listeners..."
    for p in $PIDS; do
        kill "$p" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    echo "[tunnel-listen-ftp] done"
}

trap cleanup INT TERM EXIT

echo "──────────────────────────────────────────────────────"
echo "  FTP tunnel code: ${CODE}"
echo "  control: 127.0.0.1:${LOCAL_CTRL_PORT} -> guest:${REMOTE_CTRL_PORT}"
echo "  passive: ${PASV_MIN}-${PASV_MAX}"
echo ""
echo "  FTP client settings:"
echo "    Host: 127.0.0.1"
echo "    Port: ${LOCAL_CTRL_PORT}"
echo "    Passive mode: ON"
echo "    Passive ports: ${PASV_MIN}-${PASV_MAX}"
echo ""
echo "  Ctrl-C to stop all listeners"
echo "──────────────────────────────────────────────────────"

start_listener "$LOCAL_CTRL_PORT" "$REMOTE_CTRL_PORT"

p="$PASV_MIN"
while [ "$p" -le "$PASV_MAX" ]; do
    start_listener "$p" "$p"
    p=$((p + 1))
done

# Keep script alive while child listeners run.
while :; do
    sleep 30
done
