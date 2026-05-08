#!/bin/sh
# expose-tcp.sh — claim a public TCP port on the relay so any TCP client
# (irssi, ssh, nc, ...) can connect directly to your guest service with
# no Mac/host helper needed.
#
# Usage:
#   wget -qO- https://linuxontab.com/local/expose-tcp.sh | sh -s 6667
#   wget -qO- https://linuxontab.com/local/expose-tcp.sh | sh -s 6667 1h
#
# The first arg is the guest-side internal port (must already be in your
# tunnel code's registered ports — i.e. listed in tunnel-up.sh).
# The optional second arg is the TTL ("1h", "30m", "12h", or seconds).
#
# Reads the active code from /tmp/tunnel.code (set by tunnel-up.sh).
# On success prints e.g.:
#   public: linuxontab-tunnel.fly.dev:6667
# Then any client can do:
#   irssi -c linuxontab-tunnel.fly.dev -p 6667

set -eu

RELAY="${RELAY:-https://linuxontab-tunnel.fly.dev}"
PORT="${1:-}"
TTL_RAW="${2:-1h}"

if [ -z "$PORT" ]; then
  echo "usage: expose-tcp.sh <guest-port> [ttl]" >&2
  exit 1
fi

if [ ! -s /tmp/tunnel.code ]; then
  echo "[expose-tcp] no /tmp/tunnel.code — run tunnel-up.sh first" >&2
  exit 1
fi
CODE="$(cat /tmp/tunnel.code)"

# Parse TTL: '1h' / '30m' / '45s' / plain seconds
case "$TTL_RAW" in
  *h) TTL_SECS="$(( ${TTL_RAW%h} * 3600 ))" ;;
  *m) TTL_SECS="$(( ${TTL_RAW%m} * 60 ))" ;;
  *s) TTL_SECS="${TTL_RAW%s}" ;;
  *)  TTL_SECS="$TTL_RAW" ;;
esac
TTL_MS="$(( TTL_SECS * 1000 ))"

apk info -e curl >/dev/null 2>&1 || apk add --no-cache --quiet curl >/dev/null 2>&1 || true

REQ_BODY="$(printf '{"code":"%s","port":%s,"ttlMs":%s}' "$CODE" "$PORT" "$TTL_MS")"
RESP="$(curl -fsS -X POST -H 'content-type: application/json' \
  --data "$REQ_BODY" "$RELAY/port/expose" 2>&1 || true)"

if [ -z "$RESP" ] || ! echo "$RESP" | grep -q '"publicPort"'; then
  echo "[expose-tcp] failed: $RESP" >&2
  exit 1
fi

# Tiny JSON pluck — works without jq (BusyBox grep + sed).
HOST="$(echo "$RESP" | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')"
PUBP="$(echo "$RESP" | sed -n 's/.*"publicPort":\([0-9]*\).*/\1/p')"
EXP="$(echo "$RESP"  | sed -n 's/.*"expiresAt":\([0-9]*\).*/\1/p')"
REUSED="$(echo "$RESP" | grep -q '"reused":true' && echo yes || echo no)"

cat <<EOF
[expose-tcp] code=$CODE  guest-port=$PORT  reused=$REUSED
[expose-tcp] public: $HOST:$PUBP
[expose-tcp] expires_at_ms: $EXP

Connect from anywhere:
  nc $HOST $PUBP
  ssh -p $PUBP user@$HOST           # if guest-port is sshd
  irssi -c $HOST -p $PUBP -n yourname
EOF
