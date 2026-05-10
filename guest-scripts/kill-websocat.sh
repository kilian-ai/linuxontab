#!/bin/sh
# kill websocat (cleanup)
pkill -9 -f websocat || true; pkill -9 -f 'while.*websocat' || true; sleep 1; pgrep -af websocat || true