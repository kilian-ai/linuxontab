#!/bin/sh
# native test bed: xtiny + Chromium (under native Blink) in one container
set -u
cd /w/x
command -v gcc >/dev/null || apk add -q gcc musl-dev python3 >/dev/null
gcc -O1 -w -o /tmp/xtiny librfb.c xtiny.c -lm || exit 1
mkdir -p /tmp/.X11-unix
rm -rf /w/root/root   # profile written through the overlay by earlier runs
/tmp/xtiny > /w/x/xtiny.log 2>&1 &
(cd /w/x && python3 -m http.server 8000 >/dev/null 2>&1 &)
sleep 1
export BLINK_OVERLAYS=/w/root: DISPLAY=:1
URL="${URL:-http://127.0.0.1:8000/t.html}"
timeout ${SECS:-90} ${BLINKBIN:-/w/bl/blink} ${BLINK_OPTS:-} /w/root/usr/lib/chromium/chrome --no-sandbox --single-process --no-zygote \
  --disable-gpu --disable-software-rasterizer --disable-gpu-compositing --disable-dev-shm-usage \
  --js-flags=--jitless --ozone-platform=x11 --no-first-run --disable-crashpad-for-testing --user-data-dir=/tmp/prof ${XFLAGS:-} ${APP:+--app=}"$URL" > /w/x/chrome.log 2>&1 &
CPID=$!
for t in ${SNAPS:-30 60 85}; do
  sleep $((t - ${last:-0})); last=$t
  python3 /w/x/snap.py 127.0.0.1 5900 /w/x/snap-$t.png 2>&1 | tail -1
done
wait $CPID
echo "chrome exit done"
