#!/bin/sh
# tunnel-ssh.sh — SSH into a tunnel-registered guest from Mac/Linux
# Usage: tunnel-ssh.sh CODE [user] [port]
#
# One-liner (zsh-safe):
#   sh <(curl -sS https://linuxontab.com/local/tunnel-ssh.sh) CODE
#
# Or install + use:
#   curl -sS https://linuxontab.com/local/tunnel-ssh.sh -o ~/bin/tunnel-ssh && chmod +x ~/bin/tunnel-ssh
#   tunnel-ssh CODE
#
# Requires: websocat, ssh

set -u

CODE="${1:?usage: tunnel-ssh.sh CODE [user] [port]}"
USER_AT="${2:-root}"
PORT="${3:-22}"

# Override via env: TUNNEL_WS=ws://localhost:8787 sh tunnel-ssh.sh CODE
TUNNEL_WS="${TUNNEL_WS:-wss://linuxontab-tunnel.fly.dev}"

if ! command -v websocat >/dev/null 2>&1; then
    echo "[tunnel-ssh] websocat not found — install via: brew install websocat" >&2
    exit 1
fi

WS_PROXY=$(mktemp -t tunnel-ssh-proxy.XXXXXX)
cat > "$WS_PROXY" <<PROXY_EOF
#!/bin/sh
exec websocat --binary "${TUNNEL_WS}/port/client?code=${CODE}&port=${PORT}"
PROXY_EOF
chmod +x "$WS_PROXY"

trap 'rm -f "$WS_PROXY"' EXIT INT TERM

exec ssh \
    -o "StrictHostKeyChecking=no" \
    -o "UserKnownHostsFile=/dev/null" \
    -o "LogLevel=ERROR" \
    -o "ProxyCommand=$WS_PROXY" \
    "${USER_AT}@tunnel-${CODE}"
