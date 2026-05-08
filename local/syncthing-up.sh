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
    # Newer syncthing dropped the `generate` subcommand entirely; the daemon
    # auto-generates config on first launch. Older versions used
    # `syncthing -generate=DIR`, then `syncthing generate --home=DIR`. Try
    # them in order, falling back to a no-op (let `syncthing serve` create it).
    GEN_LOG="$HOME_DIR/.generate.log"
    if syncthing generate --home="$HOME_DIR" >"$GEN_LOG" 2>&1; then
        :
    elif syncthing --generate="$HOME_DIR" >"$GEN_LOG" 2>&1; then
        :
    elif syncthing --no-browser --home="$HOME_DIR" --generate >"$GEN_LOG" 2>&1; then
        :
    else
        echo "[syncthing-up] WARN: explicit config generation failed, will let 'syncthing serve' create it on first run" >&2
        echo "[syncthing-up] last attempt log:" >&2
        sed 's/^/[syncthing-up]   /' "$GEN_LOG" >&2 2>/dev/null || true
        # Pre-touch a stub so the awk patcher below has something to read;
        # serve will overwrite it on first launch if it's not a valid xml.
        # Actually skip patching if no config — patch on second run instead.
        SKIP_PATCH=1
    fi
fi

# Patch config.xml in place:
#   <address>127.0.0.1:8384</address>           → <address>0.0.0.0:8384</address>
#   <insecureAdminAccess>...</insecureAdminAccess> remains
#   add/replace <insecureSkipHostcheck>true</insecureSkipHostcheck>
#
# BusyBox sed; use a temp file approach since -i.bak suffix handling varies.
SKIP_PATCH="${SKIP_PATCH:-0}"

# If we couldn't generate config explicitly, bootstrap it by running syncthing
# briefly so it auto-creates the config files, then kill it and patch.
if [ "$SKIP_PATCH" = "1" ] || [ ! -f "$CONFIG" ]; then
    echo "[syncthing-up] bootstrapping config via 'syncthing serve' ..."
    BOOT_LOG="$HOME_DIR/.bootstrap.log"
    syncthing serve --home="$HOME_DIR" --no-browser >"$BOOT_LOG" 2>&1 &
    BOOT_PID=$!
    # Wait up to 15s for config.xml to appear
    i=0
    while [ ! -f "$CONFIG" ] && [ "$i" -lt 15 ]; do
        sleep 1
        i=$((i + 1))
    done
    kill "$BOOT_PID" 2>/dev/null
    # Wait up to 5s for clean exit so we can rewrite config.xml safely.
    i=0
    while kill -0 "$BOOT_PID" 2>/dev/null && [ "$i" -lt 5 ]; do
        sleep 1
        i=$((i + 1))
    done
    kill -9 "$BOOT_PID" 2>/dev/null || true
    if [ ! -f "$CONFIG" ]; then
        echo "[syncthing-up] FAILED: bootstrap did not create $CONFIG" >&2
        echo "[syncthing-up] bootstrap log:" >&2
        sed 's/^/[syncthing-up]   /' "$BOOT_LOG" >&2 2>/dev/null || true
        exit 1
    fi
    echo "[syncthing-up] bootstrapped config at $CONFIG"
fi

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
        if (line ~ /<gui[ >]/) {
            # Force tls="false" — the HTTP-over-WS tunnel proxy can not do TLS
            # to localhost. If the user toggles HTTPS in the GUI, syncthing
            # rewrites this attr to "true" and the tunnel breaks. We always
            # reset it to false here so re-running this script fixes it.
            sub(/ tls="[^"]*"/, "", line)
            sub(/<gui /, "<gui tls=\"false\" ", line)
        }
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

echo "[syncthing-up] config patched: GUI=$GUI_ADDR listen=$LISTEN_ADDR hostcheck=disabled tls=false"

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
