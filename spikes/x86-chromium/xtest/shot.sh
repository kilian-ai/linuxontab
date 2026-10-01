cd /w/x; apk add -q python3 >/dev/null 2>&1; (python3 -m http.server 8000 >/dev/null 2>&1 &); sleep 1
rm -rf /w/root/root
export BLINK_OVERLAYS=/w/root:
timeout 200 /w/bl/blink -m -j /w/root/usr/lib/chromium/chrome --headless=old --no-sandbox --single-process --no-zygote --disable-gpu --disable-software-rasterizer --disable-gpu-compositing --disable-dev-shm-usage --js-flags=--jitless --screenshot=/w/x/shot-native.png --window-size=780,400 http://127.0.0.1:8000/t.html >/dev/null 2>&1
ls -la /w/x/shot-native.png
