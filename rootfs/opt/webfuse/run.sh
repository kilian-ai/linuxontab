#!/bin/sh
# Start the Spiel/WebFuse backend (uvicorn on 127.0.0.1:8081, loopback only —
# nginx fronts it on :8080, see /etc/nginx/spiel.conf and spiel-demo).
# In-process uvicorn.run(): the `python3 -m uvicorn` click CLI stalls silently
# on this kernel before logging anything. threading.stack_size: real per-thread
# stacks (sysroot/wasm_clone.c) default to musl's 128 KB — too small here.
cd /opt/webfuse
export PYTHONPATH=/opt/webfuse-libs:/opt/webfuse
exec python3 -c "import threading; threading.stack_size(4<<20); import uvicorn; uvicorn.run('app.main:app', host='127.0.0.1', port=8081, log_level='info', access_log=False)"
