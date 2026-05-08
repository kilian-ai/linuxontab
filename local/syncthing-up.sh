#!/bin/sh
# syncthing-up.sh — Start Syncthing in the v86 guest with 0.0.0.0 binding
#
# Default `apk add syncthing` configures the GUI to bind 127.0.0.1:8384,
# which works for the HTTP-over-WS proxy (websocat bridges on the same
# loopback) but refuses raw TCP from any other client. Binding 0.0.0.0:8384
# makes the GUI reachable via `tunnel-listen.sh` raw-TCP pairing too.
#
# Also disables Syncthing's GUI hostcheck so we don't have to spoof Host
# headers, and lets the listen address bind 0.0.0.0:22000 explicitly.
#
# Usage:
#   wget -qO- https://linuxontab.com/local/syncthing-up.sh | sh
#
# Env overrides:
#   SYNCTHING_GUI_ADDR=0.0.0.0:8384     # GUI bind
#   SYNCTHING_LISTEN_ADDR=tcp://0.0.0.0:22000
#   SYNCTHING_HOME=/root/.local/state/syncthing
#
# Requires: syncthing (apk add syncthing)

set -u

GUI_ADDR="${SYNCTHING_GUI_ADDR:-0.0.0.0:8384}"
LISTEN_ADDR="${SYNCTHING_LISTEN_ADDR:-tcp://0.0.0.0:22000}"
HOME_DIR="${SYNCTHING_HOME:-${HOME:-/root}/.local/state/syncthing}"

if ! command -v syncthing >/dev/null 2>&1; then
    echo "[syncthing-up] syncthing not installed — running: apk add --no-cache syncthing"
    apk add --no-cache syncthing >/dev/null 2>&1 || {
        echo "[syncthing-up] apk add failed — make sure repos are configured" >&2
        exit 1
    }
fi

# Kill any running instance so the new binding takes effect.
if pgrep -x syncthing >/dev/null 2>&1; then
    echo "[syncthing-up] stopping existing syncthing ..."
    killall syncthing 2>/dev/null
    # Wait up to 5s for clean exit
    i=0
    while pgrep -x syncthing >/dev/null 2>&1 && [ "$i" -lt 5 ]; do
        sleep 1
        i=$((i + 1))
    done
    pgrep -x syncthing >/dev/null 2>&1 && killall -9 syncthing 2>/dev/null
fi

mkdir -p "$HOME_DIR"

# First-run config generation: syncthing creates config.xml on first
# `syncthing generate`. We then rewrite the addresses + disable hostcheck
# so the daemon binds where we want from the very first start.
CONFIG="$HOME_DIR/config.xml"
if [ ! -f "$CONFIG" ]; then
    echo "[syncthing-up] generating initial config in $HOME_DIR ..."
    syncthing generate --home="$HOME_DIR" >/dev/null 2>&1 || {
        echo "[syncthing-up] syncthing generate failed" >&2
        exit 1
    }
fi

# Patch config.xml in place:
#   <address>127.0.0.1:8384</address>           → <address>0.0.0.0:8384</address>
#   <insecureAdminAccess>...</insecureAdminAccess> remains
#   add/replace <insecureSkipHostcheck>true</insecureSkipHostcheck>
#
# BusyBox sed; use a temp file approach since -i.bak suffix handling varies.
TMP="$CONFIG.tmp.$$"
awk -v gui_addr="$GUI_ADDR" -v listen_addr="$LISTEN_ADDR" '
    BEGIN { in_gui = 0; in_options = 0; hostcheck_set = 0 }
    /<gui[ >]/             { in_gui = 1 }
    /<\/gui>/              { in_gui = 0 }
    /<options>/            { in_options = 1 }
    /<\/options>/ {
        if (!hostcheck_set) {
            print "        <insecureSkipHostcheck>true</insecureSkipHostcheck>"
            hostcheck_set = 1
        }
        in_options = 0
    }
    {
        line = $0
        if (in_gui && line ~ /<address>/) {
            sub(/<address>[^<]*<\/address>/, "<address>" gui_addr "</address>", line)
        }
        if (in_options && line ~ /<listenAddress>/) {
            sub(/<listenAddress>[^<]*<\/listenAddress>/, "<listenAddress>" listen_addr "</listenAddress>", line)
        }
        if (in_options && line ~ /<insecureSkipHostcheck>/) {
            sub(/<insecureSkipHostcheck>[^<]*<\/insecureSkipHostcheck>/, "<insecureSkipHostcheck>true</insecureSkipHostcheck>", line)
            hostcheck_set = 1
        }
        print line
    }
' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

echo "[syncthing-up] config patched: GUI=$GUI_ADDR listen=$LISTEN_ADDR hostcheck=disabled"

# Start syncthing detached. Logs go to $HOME_DIR/syncthing.log.
LOG="$HOME_DIR/syncthing.log"
echo "[syncthing-up] starting syncthing (logs: $LOG) ..."
nohup syncthing serve --home="$HOME_DIR" --no-browser \
    > "$LOG" 2>&1 &
PID=$!
disown 2>/dev/null || true
echo "[syncthing-up] syncthing PID $PID"

# Wait up to 10s for GUI to come up
i=0
while [ "$i" -lt 10 ]; do
    if wget -qO /dev/null --timeout=2 "http://127.0.0.1:8384/" 2>/dev/null; then
        echo "[syncthing-up] GUI ready on $GUI_ADDR"
        echo "[syncthing-up] Browser:   https://linuxontab-tunnel.fly.dev/port/http/<CODE>/8384/"
        echo "[syncthing-up] Local TCP: sh <(curl -sS https://linuxontab.com/local/tunnel-listen.sh) <CODE> 18384 8384"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done
echo "[syncthing-up] WARNING: GUI did not respond within 10s — check $LOG"
exit 0
