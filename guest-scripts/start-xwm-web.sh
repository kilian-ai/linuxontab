#!/bin/sh
# start Xvfb + Openbox + x11vnc + noVNC and expose over tunnel :6080

DISPLAY_NUM="${DISPLAY_NUM:-:1}"
RESOLUTION="${XWM_RESOLUTION:-1280x720x24}"
VNC_PORT="${XWM_VNC_PORT:-5901}"
WEB_PORT="${XWM_WEB_PORT:-6080}"
RELAY_URL="${XWM_RELAY_URL:-https://linuxontab-tunnel.fly.dev}"

log() { printf '%s\n' "$*"; }

log "[xwm] installing packages (best effort)"
apk update || true
apk add --no-cache --upgrade \
  websocat curl jq xvfb xorg-server x11vnc openbox xterm dbus novnc websockify \
  >/tmp/xwm-apk.log 2>&1 || \
apk add --no-cache --upgrade \
  websocat curl jq xorg-server xorg-server-xvfb x11vnc openbox xterm dbus novnc py3-websockify \
  >/tmp/xwm-apk.log 2>&1 || true

if ! command -v Xvfb >/dev/null 2>&1; then
  log "[xwm] error: Xvfb not found after package install"
  log "[xwm] see /tmp/xwm-apk.log"
  exit 1
fi
if ! command -v x11vnc >/dev/null 2>&1; then
  log "[xwm] error: x11vnc not found after package install"
  log "[xwm] see /tmp/xwm-apk.log"
  exit 1
fi
if ! command -v websocat >/dev/null 2>&1; then
  log "[xwm] error: websocat is required for tunnel bridge"
  exit 1
fi

DISP_NUM_ONLY="${DISPLAY_NUM#:}"

log "[xwm] stopping previous X stack"
pkill -f "Xvfb ${DISPLAY_NUM}" >/dev/null 2>&1 || true
pkill -f "x11vnc .*rfbport ${VNC_PORT}" >/dev/null 2>&1 || true
pkill -f "websockify .* ${WEB_PORT} " >/dev/null 2>&1 || true
pkill -f "python3 -m websockify .* ${WEB_PORT} " >/dev/null 2>&1 || true
pkill -f "openbox" >/dev/null 2>&1 || true
pkill -f "xterm .*LinuxOnTab X session" >/dev/null 2>&1 || true
rm -f "/tmp/.X${DISP_NUM_ONLY}-lock" 2>/dev/null || true

log "[xwm] starting Xvfb on ${DISPLAY_NUM} (${RESOLUTION})"
Xvfb "${DISPLAY_NUM}" -screen 0 "${RESOLUTION}" >/tmp/xwm-xvfb.log 2>&1 &
sleep 1

export DISPLAY="${DISPLAY_NUM}"

log "[xwm] starting Openbox + xterm"
openbox >/tmp/xwm-openbox.log 2>&1 &
xterm -geometry 120x34+20+20 -T "LinuxOnTab X session" >/tmp/xwm-xterm.log 2>&1 &

log "[xwm] starting x11vnc on 127.0.0.1:${VNC_PORT}"
x11vnc -display "${DISPLAY_NUM}" -forever -shared -nopw -listen 127.0.0.1 -rfbport "${VNC_PORT}" >/tmp/xwm-x11vnc.log 2>&1 &

NOVNC_WEB=""
for CAND in /usr/share/novnc /usr/share/webapps/novnc; do
  if [ -d "$CAND" ]; then
    NOVNC_WEB="$CAND"
    break
  fi
done
if [ -z "$NOVNC_WEB" ]; then
  log "[xwm] error: noVNC web root not found (/usr/share/novnc or /usr/share/webapps/novnc)"
  exit 1
fi

log "[xwm] starting noVNC on :${WEB_PORT}"
if command -v websockify >/dev/null 2>&1; then
  websockify --web "${NOVNC_WEB}" "${WEB_PORT}" "127.0.0.1:${VNC_PORT}" >/tmp/xwm-novnc.log 2>&1 &
else
  python3 -m websockify --web "${NOVNC_WEB}" "${WEB_PORT}" "127.0.0.1:${VNC_PORT}" >/tmp/xwm-novnc.log 2>&1 &
fi

CODE="$(cat /tmp/tunnel.code 2>/dev/null || true)"
if [ -z "$CODE" ]; then
  log "[xwm] no tunnel code found - registering one"
  REG="$(curl -sS -m 12 -X POST "${RELAY_URL}/port/register" -H 'content-type: application/json' -d '{"ports":[6080]}' 2>/dev/null || true)"
  CODE="$(echo "$REG" | sed -n 's/.*"code":"\([A-Z0-9]*\)".*/\1/p')"
  if [ -n "$CODE" ]; then
    echo "$CODE" > /tmp/tunnel.code
  fi
fi

if [ -z "$CODE" ]; then
  log "[xwm] error: could not determine pairing code"
  log "[xwm] run tunnel-up first, then rerun this script"
  exit 1
fi

mkdir -p /tmp
: > /tmp/xwm-ws.log

log "[xwm] starting websocat bridge for port ${WEB_PORT} (code ${CODE})"
setsid sh -c "while :; do websocat -b tcp:127.0.0.1:${WEB_PORT} 'wss://${RELAY_URL#https://}/port/guest?code=${CODE}&port=${WEB_PORT}' >>/tmp/xwm-ws.log 2>&1; echo \"\$(date +%T) xwm bridge died\" >> /tmp/xwm-ws.log; sleep 1; done" </dev/null >/dev/null 2>&1 &

sleep 2

URL="https://tunnel.linuxontab.com/port/http/${CODE}/${WEB_PORT}/vnc.html?autoconnect=true&resize=scale"

log "[xwm] done"
log "[xwm] CODE: ${CODE}"
log "[xwm] URL:  ${URL}"
log "[xwm] logs: /tmp/xwm-*.log and /tmp/xwm-ws.log"
