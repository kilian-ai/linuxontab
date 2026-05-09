#!/usr/bin/env sh
# Wrapper to run the guest dev server: prefer Node; fallback to Python.
# Usage: guest-dev-server.sh [PORT] [HOST_DIR]

PORT=${1:-3000}
HOST_DIR=${2:-/usr/local/dev}

if [ ! -d "$HOST_DIR" ]; then
  echo "Host dir $HOST_DIR does not exist. Create it and put files there." >&2
  exit 2
fi

cd "$HOST_DIR" || exit 2

# Try Node first
if command -v node >/dev/null 2>&1; then
  echo "Node detected — starting server-express.js if present"
  if [ ! -f server-express.js ]; then
    echo "server-express.js not found in $HOST_DIR — please copy it here or run from /path/to/local/dev-sync" >&2
    echo "Attempting to start python fallback instead..."
  else
    # Run Node server
    PORT=$PORT HOST_DIR=$HOST_DIR node server-express.js &
    echo "Node dev server started (PID $!) on port $PORT serving $HOST_DIR"
    exit 0
  fi
fi

# Python fallback
if command -v python3 >/dev/null 2>&1; then
  echo "Starting Python fallback server"
  PORT=$PORT HOST_DIR=$HOST_DIR python3 /usr/local/dev/server-py.py &
  echo "Python dev server started (PID $!) on port $PORT serving $HOST_DIR"
  exit 0
fi

echo "No suitable runtime found (node or python3). Install nodejs or python3 in the guest." >&2
exit 1
