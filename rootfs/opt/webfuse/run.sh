#!/bin/sh
# Start the WebFuse backend on the LinuxOnTab wasm guest.
cd /opt/webfuse
export PYTHONPATH=/opt/webfuse-libs:/opt/webfuse
exec python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8080 --no-access-log
