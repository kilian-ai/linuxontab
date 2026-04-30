#!/bin/sh
# tunnel-listen.sh — Open a local TCP port that forwards to a tunnel code.
# Enables plain `ssh -p PORT localhost`, `scp -P PORT ...`, rsync, etc.
#
# Usage: tunnel-listen.sh CODE [local_port] [remote_port]
#   local_port   defaults to 2222
#   remote_port  defaults to 22 (the port registered on the guest)
#
# One-liner:
#   sh <(curl -sS https://www.traits.build/local/tunnel-listen.sh) CODE
#
# Then in another terminal:
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost
#   scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null file root@localhost:/tmp/
#
# Requires: websocat (brew install websocat)

set -u

CODE="${1:?usage: tunnel-listen.sh CODE [local_port] [remote_port]}"
LOCAL_PORT="${2:-2222}"
REMOTE_PORT="${3:-22}"

# Override via env: TUNNEL_WS=ws://localhost:8787 sh tunnel-listen.sh CODE
# Default to Fly (no daily quota); CF Worker kept as fallback for legacy codes.
TUNNEL_WS="${TUNNEL_WS:-wss://traits-build-tunnel.fly.dev}"
TUNNEL_WS_FALLBACK="wss://tunnel.traits.build"

if ! command -v websocat >/dev/null 2>&1; then
    echo "[tunnel-listen] websocat not found — install via: brew install websocat" >&2
    exit 1
fi

relay_status_json_for_ws() {
    ws_base="$1"
    curl -fsS "https://${ws_base#*://}/port/status?code=${CODE}" 2>/dev/null || true
}

has_registered_port() {
    check_port="$1"
    status_json="$2"
    printf '%s' "$status_json" | grep -q "\"registered_ports\"" || return 1
    printf '%s' "$status_json" | grep -q "\[$check_port\(,\|]\)" && return 0
    printf '%s' "$status_json" | grep -q ",$check_port\(,\|]\)" && return 0
    return 1
}

has_guest_port() {
    check_port="$1"
    status_json="$2"
    printf '%s' "$status_json" | grep -q "\"guest_ports\"" || return 1
    printf '%s' "$status_json" | grep -q "\"guest_ports\"[[:space:]]*:[[:space:]]*\[[^]]*$check_port" && return 0
    return 1
}

status_json=""
selected_ws="$TUNNEL_WS"

status_primary="$(relay_status_json_for_ws "$TUNNEL_WS")"
status_fallback=""
if [ "$TUNNEL_WS" != "$TUNNEL_WS_FALLBACK" ]; then
    status_fallback="$(relay_status_json_for_ws "$TUNNEL_WS_FALLBACK")"
fi

if [ -n "$status_primary" ] && has_registered_port "$REMOTE_PORT" "$status_primary"; then
    selected_ws="$TUNNEL_WS"
    status_json="$status_primary"
elif [ -n "$status_fallback" ] && has_registered_port "$REMOTE_PORT" "$status_fallback"; then
    selected_ws="$TUNNEL_WS_FALLBACK"
    status_json="$status_fallback"
elif [ -n "$status_primary" ]; then
    selected_ws="$TUNNEL_WS"
    status_json="$status_primary"
elif [ -n "$status_fallback" ]; then
    selected_ws="$TUNNEL_WS_FALLBACK"
    status_json="$status_fallback"
else
    echo "[tunnel-listen] unable to fetch relay status for code ${CODE}" >&2
    echo "[tunnel-listen] verify the code and relay endpoint, then retry" >&2
    exit 1
fi

TUNNEL_WS="$selected_ws"

if printf '%s' "$status_json" | grep -q '"active"[[:space:]]*:[[:space:]]*false'; then
    echo "[tunnel-listen] code ${CODE} is inactive/expired" >&2
    echo "[tunnel-listen] generate a fresh code on the guest via tunnel-up.sh and retry" >&2
    exit 1
fi

if ! has_registered_port "$REMOTE_PORT" "$status_json"; then
    echo "[tunnel-listen] code ${CODE} is missing registered guest port ${REMOTE_PORT}" >&2
    echo "[tunnel-listen] restart guest tunnel-up with port ${REMOTE_PORT} and retry" >&2
    exit 1
fi

if ! has_guest_port "$REMOTE_PORT" "$status_json"; then
    echo "[tunnel-listen] warning: guest is not currently connected on port ${REMOTE_PORT}" >&2
    echo "[tunnel-listen] listener will start, but connections may fail until guest bridge is up" >&2
fi

URL="${TUNNEL_WS}/port/client?code=${CODE}&port=${REMOTE_PORT}"

echo "──────────────────────────────────────────────────────"
echo "  tunnel: $CODE  (guest port $REMOTE_PORT)"
echo "  local listener: 127.0.0.1:${LOCAL_PORT}"
echo ""
echo "  In another terminal:"
if [ "$REMOTE_PORT" = "22" ]; then
    echo "    ssh -p ${LOCAL_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost"
    echo "    scp -P ${LOCAL_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null FILE root@localhost:/tmp/"
    echo "    sftp -P ${LOCAL_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost"
else
    echo "    nc localhost ${LOCAL_PORT}   # or any client that speaks port ${REMOTE_PORT}"
fi
echo ""
echo "  Ctrl-C to stop."
echo "──────────────────────────────────────────────────────"

# Respawn loop: each local TCP client gets a fresh upstream WSS connection.
# Forking TCP listener: accepts unlimited concurrent clients, each gets its
# OWN fresh websocat → upstream WS connection. Required for SFTP/Filezilla
# (parallel transfers open additional TCP connections to the same port) and
# for any client that overlaps a control session with data sessions.
#
# Prior single-shot design (websocat --binary -E tcp-l:...) handled only one
# client at a time; the second concurrent connection would queue in the kernel
# backlog and time out with "socket unexpectedly closed".
#
# Implementation: prefer socat (cleanest), fall back to Python (always on
# macOS), then last-resort to single-shot websocat respawn loop.
trap 'echo "[tunnel-listen] stopping"; kill 0 2>/dev/null; exit 0' INT TERM

if command -v socat >/dev/null 2>&1; then
    echo "[tunnel-listen] using socat fork-listener (multi-client)"
    exec socat "TCP-LISTEN:${LOCAL_PORT},bind=127.0.0.1,reuseaddr,fork" \
        "EXEC:websocat --binary ${URL},nofork"
elif command -v python3 >/dev/null 2>&1; then
    echo "[tunnel-listen] using python3 fork-listener (multi-client)"
    exec python3 - "$LOCAL_PORT" "$URL" <<'PYEOF'
import os, sys, socket, signal
port = int(sys.argv[1])
url  = sys.argv[2]
# Auto-reap finished children on POSIX so we don't accumulate zombies.
try: signal.signal(signal.SIGCHLD, signal.SIG_IGN)
except Exception: pass
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(128)
while True:
    try:
        conn, _addr = srv.accept()
    except (KeyboardInterrupt, SystemExit):
        break
    except OSError:
        continue
    pid = os.fork()
    if pid == 0:
        # Child: replace stdio with the accepted socket and exec websocat.
        # `-E` makes the child exit cleanly on EOF from either side; the
        # parent keeps accepting unrelated clients in parallel.
        try: srv.close()
        except Exception: pass
        fd = conn.fileno()
        os.dup2(fd, 0)
        os.dup2(fd, 1)
        try: conn.close()
        except Exception: pass
        os.execvp("websocat", ["websocat", "--binary", "-E", "-", url])
        os._exit(127)
    else:
        # Parent: child has its own dup of the socket; we don't need ours.
        try: conn.close()
        except Exception: pass
PYEOF
else
    echo "[tunnel-listen] WARNING: socat and python3 unavailable; falling back to" >&2
    echo "[tunnel-listen] single-shot websocat (parallel SFTP transfers may fail)" >&2
    while :; do
        websocat --binary -E "tcp-l:127.0.0.1:${LOCAL_PORT}" "$URL" || true
        sleep 0.2 2>/dev/null || sleep 1
    done
fi
