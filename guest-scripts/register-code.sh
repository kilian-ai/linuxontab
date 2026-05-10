#!/bin/sh
# register new code (API)
REG=$(curl -sS -m 10 -X POST https://linuxontab-tunnel.fly.dev/port/register -H 'content-type: application/json' -d '{"ports":[22,6667]}'); echo "$REG"; CODE=$(echo "$REG" | sed -n 's/.*"code":"\([A-Z0-9]*\)".*/\1/p'); echo "$CODE" > /tmp/tunnel.code; echo CODE=$CODE