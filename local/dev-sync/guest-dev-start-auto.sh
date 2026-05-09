#!/usr/bin/env sh
# Start dev server, register with relay and spawn websocat bridges.
# Usage: guest-dev-start-auto.sh [PORT] [HOST_DIR] [TOKEN]

PORT=${1:-3000}
HOST_DIR=${2:-/usr/local/dev}
TOKEN=${3:-${DEV_SYNC_TOKEN:-}}

if [ ! -d "$HOST_DIR" ]; then
  echo "Host dir $HOST_DIR does not exist. Create it and copy server files there." >&2
  exit 2
fi

cd "$HOST_DIR" || exit 2

# Start the dev server (prefers guest wrapper if present)
if [ -x ./guest-dev-server.sh ]; then
  echo "Starting dev server via ./guest-dev-server.sh $PORT $HOST_DIR"
  ./guest-dev-server.sh "$PORT" "$HOST_DIR" &
  SERVER_PID=$!
else
  if command -v node >/dev/null 2>&1 && [ -f ./server-express.js ]; then
    echo "Starting node server-express.js"
    PORT=$PORT HOST_DIR=$HOST_DIR node server-express.js &
    SERVER_PID=$!
  elif command -v python3 >/dev/null 2>&1 && [ -f ./server-py.py ]; then
    echo "Starting python server-py.py"
    PORT=$PORT HOST_DIR=$HOST_DIR python3 server-py.py &
    SERVER_PID=$!
  else
    echo "No server found (guest-dev-server.sh, server-express.js or server-py.py)." >&2
    exit 2
  fi
fi

echo "Waiting for server to listen on 127.0.0.1:$PORT..."
for i in $(seq 1 20); do
  if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    echo "Server is up"
    break
  fi
  sleep 1
done

echo "Registering with relay for port $PORT..."
REG=$(curl -sS -m 10 -X POST https://linuxontab-tunnel.fly.dev/port/register \
      -H 'content-type: application/json' -d "{\"ports\":[${PORT}]}" )
CODE=$(echo "$REG" | sed -n 's/.*"code":"\([A-Z0-9]*\)".*/\1/p')
if [ -z "$CODE" ]; then
  echo "Failed to register with relay: $REG" >&2
  exit 3
fi

echo "CODE=$CODE"
echo "{\"code\":\"$CODE\",\"port\":$PORT}" > /tmp/tunnel.json
echo "$CODE" > /tmp/tunnel.code

# Start websocat bridge loops for resilience
LOG=/tmp/ws.log
: > "$LOG"
for i in 1 2 3; do
  setsid sh -c "while :; do
      websocat -b tcp:127.0.0.1:${PORT} 'wss://linuxontab-tunnel.fly.dev/port/guest?code=${CODE}&port=${PORT}' >>${LOG} 2>&1
      echo \"\$(date +%T) bridge ${PORT}/${i} died\" >> ${LOG}
      sleep 1
    done" </dev/null >/dev/null 2>&1 &
done

echo "Bridges started (log: $LOG). Tunnel info in /tmp/tunnel.json. Server PID=${SERVER_PID:-unknown}."
echo "Status (may be empty until clients connect):"
curl -s "https://linuxontab-tunnel.fly.dev/port/status?code=$CODE" || true
