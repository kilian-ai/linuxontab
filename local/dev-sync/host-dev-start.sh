#!/usr/bin/env sh
# Host helper: start host-side watcher to push edits into guest dev server.
# Usage: host-dev-start.sh CODE PORT WATCH_DIR [TOKEN] [BASE_URL]

CODE="$1"
PORT="$2"
WATCH_DIR="${3:-.}"
TOKEN="$4"
BASE_URL="${5:-https://linuxontab-tunnel.fly.dev/port/http}"

if [ -z "$CODE" ] || [ -z "$PORT" ]; then
  echo "Usage: $0 CODE PORT [WATCH_DIR] [TOKEN] [BASE_URL]" >&2
  exit 2
fi

cd "$(dirname "$0")" || exit 1

if [ ! -d node_modules ]; then
  echo "Installing dependencies..."
  npm install
fi

echo "Starting host watcher: $WATCH_DIR -> $BASE_URL/$CODE/$PORT"
node host-sync.js --code "$CODE" --port "$PORT" --watch "$WATCH_DIR" --token "$TOKEN" --url "$BASE_URL"
