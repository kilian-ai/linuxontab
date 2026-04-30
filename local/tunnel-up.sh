#!/bin/sh
# tunnel-up.sh — Expose local TCP ports through linuxontab-tunnel.fly.dev
# (CF Worker tunnel.linuxontab.com kept as fallback in helper scripts)
# Usage: tunnel-up.sh [port1] [port2] ...
# Defaults: sshd(22), public-http(8080 → ~/public), syncthing-sync(22000),
#           syncthing-gui(8384)
# FTP note: if port 21 is requested, this script auto-adds a passive range
# (default 30000-30010) so FTP data channels can traverse relay too.
#
# Requires: websocat, curl
# Install: apk add --no-cache websocat curl
#
# After running, SSH access:
#   sh <(curl -sS https://linuxontab.com/local/tunnel-ssh.sh) CODE
#
# ~/public browsing (any HTTPS client):
#   curl  https://linuxontab-tunnel.fly.dev/port/http/CODE/8080/
#   open  https://linuxontab.com/#/viewer?code=CODE

set -u

# Survive shell logout / backgrounding. Without this, putting the script
# under '&' and exiting the parent terminal sends SIGHUP and kills every
# bridge subshell within seconds.
trap '' HUP

# ── Singleton / lifecycle management ─────────────────────────────────────
# Stale bridges accumulate fast: each tunnel-up.sh invocation registers a
# fresh pairing code and spawns POOL_SIZE × len(PORTS) websocat bridges +
# a reclaim watchdog. Without this guard, re-running the script (e.g.
# from `social tunnel-up`, the v86 Social overlay, or a respawn loop)
# leaves the previous generation running indefinitely with its own code.
#
# Behavior:
#   tunnel-up.sh               → if a cached code is active on the relay,
#                                print + exit 0 (idempotent).
#   tunnel-up.sh --reset       → kill all prior bridges/watchdogs, drop
#                                cached state, unregister cached code, exit.
#   tunnel-up.sh --new ...     → kill priors first, then start fresh.
#   TUNNEL_FORCE_NEW=1 ...     → same as --new (env-var form).
TUNNEL_PID_FILE="${TUNNEL_PID_FILE:-/tmp/tunnel.pids}"
TUNNEL_CODE_FILE="${TUNNEL_CODE_FILE:-/tmp/tunnel.code}"
TUNNEL_FORCE_NEW="${TUNNEL_FORCE_NEW:-0}"

case "${1:-}" in
    --reset|--down|--stop)
        DO_RESET=1; DO_EXIT_AFTER_RESET=1; shift ;;
    --new|--restart)
        DO_RESET=1; DO_EXIT_AFTER_RESET=0; shift ;;
    *)
        if [ "$TUNNEL_FORCE_NEW" = "1" ]; then
            DO_RESET=1; DO_EXIT_AFTER_RESET=0
        else
            DO_RESET=0; DO_EXIT_AFTER_RESET=0
        fi ;;
esac

kill_prior_processes() {
    # Kill tracked PIDs first (precise).
    if [ -s "$TUNNEL_PID_FILE" ]; then
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            kill "$pid" 2>/dev/null || true
        done < "$TUNNEL_PID_FILE"
    fi
    # Belt-and-suspenders: also pkill any websocat that points at a
    # tunnel guest URL. This catches bridges from earlier sessions
    # that pre-date the PID file.
    pkill -f 'websocat.*port/guest\?code=' 2>/dev/null || true
    # Kill prior tunnel-up.sh processes EXCEPT ourselves and our parent
    # (the parent may be a `sh -c "curl ... | sh"` wrapper from
    # social tunnel-up; killing it would terminate this script too).
    self_pid=$$
    parent_pid=$(awk '{print $4}' /proc/$$/stat 2>/dev/null || echo 0)
    for pid in $(pgrep -f 'tunnel-up\.sh' 2>/dev/null); do
        [ "$pid" = "$self_pid" ] && continue
        [ "$pid" = "$parent_pid" ] && continue
        kill "$pid" 2>/dev/null || true
    done
    rm -f "$TUNNEL_PID_FILE"
}

if [ "${DO_RESET:-0}" = "1" ]; then
    echo "[tunnel] reset: stopping prior bridges + watchdogs ..."
    kill_prior_processes
    if [ -s "$TUNNEL_CODE_FILE" ]; then
        old_code=$(head -1 "$TUNNEL_CODE_FILE")
        if [ -n "$old_code" ]; then
            echo "[tunnel] reset: unregistering $old_code"
            curl -sS --max-time 5 -X POST \
                "${TUNNEL_BASE:-https://linuxontab-tunnel.fly.dev}/port/unregister" \
                -H 'Content-Type: application/json' \
                -d "{\"code\":\"$old_code\"}" >/dev/null 2>&1 || true
        fi
        rm -f "$TUNNEL_CODE_FILE"
    fi
    if [ "${DO_EXIT_AFTER_RESET:-0}" = "1" ]; then
        echo "[tunnel] reset: done."
        exit 0
    fi
fi

# Idempotent path: if a cached code exists and the relay still considers
# it active, reuse it. This makes `tunnel-up.sh` safe to call repeatedly
# from buttons / cron / agent scripts without stacking processes.
if [ "${DO_RESET:-0}" = "0" ] && [ -s "$TUNNEL_CODE_FILE" ]; then
    cached_code=$(head -1 "$TUNNEL_CODE_FILE")
    if [ -n "$cached_code" ]; then
        cached_status=$(curl -sS --max-time 4 \
            "${TUNNEL_BASE:-https://linuxontab-tunnel.fly.dev}/port/status?code=$cached_code" \
            2>/dev/null)
        case "$cached_status" in
            *'"active":true'*)
                echo "[tunnel] already running — pairing code: $cached_code"
                echo "[tunnel] pid file: $TUNNEL_PID_FILE"
                echo "[tunnel] to restart: $0 --new"
                echo "[tunnel] to stop:    $0 --reset"
                exit 0
                ;;
        esac
        echo "[tunnel] cached code $cached_code no longer active — starting fresh"
        # Cached but inactive (relay forgot, container reboot, etc.):
        # kill any orphaned bridges from that session before continuing.
        kill_prior_processes
        rm -f "$TUNNEL_CODE_FILE"
    fi
fi

: > "$TUNNEL_PID_FILE"
track_pid() { printf '%s\n' "$1" >> "$TUNNEL_PID_FILE"; }

# Override via env: TUNNEL_BASE=http://localhost:8787 sh tunnel-up.sh
TUNNEL_BASE="${TUNNEL_BASE:-https://linuxontab-tunnel.fly.dev}"
# Derive default WS URL from TUNNEL_BASE (http→ws, https→wss).
if [ -z "${TUNNEL_WS:-}" ]; then
    case "$TUNNEL_BASE" in
        https://*) TUNNEL_WS="wss://${TUNNEL_BASE#https://}" ;;
        http://*)  TUNNEL_WS="ws://${TUNNEL_BASE#http://}" ;;
        *)         TUNNEL_WS="$TUNNEL_BASE" ;;
    esac
fi
PORTS="${*:-22 8080 22000 8384}"
FTP_PASV_MIN="${FTP_PASV_MIN:-30000}"
FTP_PASV_MAX="${FTP_PASV_MAX:-30010}"

has_port() {
    local target="$1"
    local existing_port
    for existing_port in $PORTS; do
        [ "$existing_port" = "$target" ] && return 0
    done
    return 1
}

append_port() {
    local candidate_port="$1"
    has_port "$candidate_port" || PORTS="$PORTS $candidate_port"
}

add_ftp_passive_ports_if_needed() {
    has_port 21 || return 0
    local pasv_port="$FTP_PASV_MIN"
    while [ "$pasv_port" -le "$FTP_PASV_MAX" ]; do
        append_port "$pasv_port"
        pasv_port=$((pasv_port + 1))
    done
}

add_ftp_passive_ports_if_needed

is_ftp_passive_port() {
    local candidate_port="$1"
    has_port 21 || return 1
    [ "$candidate_port" -ge "$FTP_PASV_MIN" ] && [ "$candidate_port" -le "$FTP_PASV_MAX" ]
}

# Ensure loopback is up (websocat → tcp:127.0.0.1:PORT needs it).
# Done early so DoH seeding below can use HTTPS via the host network too.
if ! ip addr show lo 2>/dev/null | grep -q 'inet 127\.'; then
    ifconfig lo 127.0.0.1 up 2>/dev/null || ip link set lo up 2>/dev/null
fi

# Seed /etc/hosts via DoH (DNS-over-HTTPS).
# The Fly WISP backend used by v86/Alpine does NOT pass UDP/53 reliably,
# so plain `nslookup`/getaddrinfo to 1.1.1.1:53 times out and every
# `wget`/`curl`/`apk` fails with "bad address". HTTPS to 1.1.1.1 works,
# so we resolve the canonical traits.build + Alpine apk hosts via
# 1.1.1.1's DoH JSON endpoint and write them straight into /etc/hosts.
# Idempotent (marker block so repeated runs don't accumulate duplicates).
# IMPORTANT: must run BEFORE any `apk add` because apk also needs DNS.
seed_hosts_via_doh() {
    # Skip if hostnames already resolve via real DNS (e.g. host has
    # working UDP/53). Cheap probe with a 1s timeout via busybox wget.
    if wget -qO- --timeout=1 -t 1 https://linuxontab.com/robots.txt \
            >/dev/null 2>&1; then
        return 0
    fi
    echo "[tunnel] DNS lookup failed — seeding /etc/hosts via DoH (1.1.1.1)"
    # Includes Alpine apk mirror so `apk add websocat` works post-seed.
    local hosts="linuxontab.com tunnel.linuxontab.com relay.linuxontab.com \
linuxontab-tunnel.fly.dev linuxontab-net.fly.dev linuxontab-api.fly.dev \
dl-cdn.alpinelinux.org"
    # Strip any previous block we wrote (in-place busybox sed).
    sed -i '/# traits-doh-begin/,/# traits-doh-end/d' /etc/hosts 2>/dev/null
    {
        echo '# traits-doh-begin'
        for h in $hosts; do
            ip=$(wget -qO- --timeout=4 -t 1 \
                "https://1.1.1.1/dns-query?name=${h}&type=A" \
                --header='Accept: application/dns-json' 2>/dev/null \
                | tr ',' '\n' \
                | sed -n 's/.*"data":"\([0-9.]*\)".*/\1/p' \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
                | head -1)
            [ -n "$ip" ] && echo "$ip $h"
        done
        echo '# traits-doh-end'
    } >> /etc/hosts
}

seed_hosts_via_doh

# Install websocat + a TCP-DNS forwarder (unbound) if missing.
# Fly WISP passes TCP fine, including TCP/53, but drops UDP/53.
# unbound's `forward-tcp-upstream: yes` resolves all hostnames over
# TCP to 1.1.1.1, so getaddrinfo / wget / curl / ping work normally
# without needing the /etc/hosts seed for every host.
if ! command -v websocat >/dev/null 2>&1 \
        || ! command -v unbound >/dev/null 2>&1; then
    echo "[tunnel] installing websocat + unbound..."
    # Alpine ISO/initramfs may ship with only its bundled in-CD repo, which
    # lacks websocat. Seed edge/main + edge/community (idempotent) so apk
    # can find it. Safe to add even if apk has e.g. only the iso repo —
    # apk will just try the new mirrors after DNS is up.
    grep -q "edge/main" /etc/apk/repositories 2>/dev/null \
        || echo "https://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories
    grep -q "edge/community" /etc/apk/repositories 2>/dev/null \
        || echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
    apk update >/dev/null 2>&1 || true
    # libcrypto3/libssl3 upgrade is required: the unbound in the current
    # apk index is built against newer openssl symbols
    # (EVP_MD_CTX_get_size_ex) than the libcrypto shipped in older Alpine
    # base images, so without this upgrade unbound dies with a relocation
    # error at startup.
    apk add --no-cache --upgrade websocat curl unbound libcrypto3 libssl3 \
            >/dev/null 2>&1 \
        || { echo "[tunnel] apk failed — install packages manually"; exit 1; }
fi

# Bring up unbound on 127.0.0.1:53 forwarding via TCP to 1.1.1.1.
# Idempotent: if an existing unbound process can actually resolve a
# query, keep it. Otherwise kill it (likely a zombie from an earlier
# libcrypto-mismatched start that bound the socket but can't serve)
# and relaunch with the current config.
start_dns_proxy() {
    if pidof unbound >/dev/null 2>&1; then
        if nslookup -timeout=2 cloudflare.com 127.0.0.1 >/dev/null 2>&1; then
            return 0
        fi
        echo "[tunnel] stale unbound detected — restarting"
        killall -q unbound 2>/dev/null
        sleep 1
    fi
    echo "[tunnel] starting local DNS proxy (unbound TCP→1.1.1.1)"
    mkdir -p /etc/unbound /var/lib/unbound 2>/dev/null
    cat > /etc/unbound/unbound.conf <<'UNBCONF'
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 53
    do-udp: yes
    do-tcp: yes
    do-ip4: yes
    do-ip6: no
    access-control: 127.0.0.0/8 allow
    chroot: ""
    pidfile: "/var/run/unbound.pid"
    use-syslog: no
    logfile: ""
    hide-identity: yes
    hide-version: yes
    qname-minimisation: no
    harden-glue: yes
    cache-min-ttl: 60
    cache-max-ttl: 3600
    # Skip auto-trust-anchor — fetching the IANA root key needs DNS.
    auto-trust-anchor-file: ""
    trust-anchor-file: ""
    val-permissive-mode: yes

forward-zone:
    name: "."
    forward-tcp-upstream: yes
    forward-first: no
    forward-addr: 1.1.1.1
    forward-addr: 1.0.0.1
UNBCONF
    unbound -c /etc/unbound/unbound.conf >/dev/null 2>&1 &
    # Wait for it to start serving.
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if nslookup -timeout=2 google.com 127.0.0.1 >/dev/null 2>&1; then
            printf 'nameserver 127.0.0.1\nnameserver 1.1.1.1\n' > /etc/resolv.conf
            echo "[tunnel] DNS proxy resolving OK"
            return 0
        fi
        sleep 1
    done
    echo "[tunnel] unbound did not respond — falling back to /etc/hosts seed"
    return 1
}
start_dns_proxy

# Build ports JSON array  e.g. "22 8384" → [22,8384]
PORTS_JSON=$(printf '['; first=1
for p in $PORTS; do
    [ "$first" = 1 ] || printf ','
    printf '%s' "$p"
    first=0
done
printf ']')

echo "[tunnel] registering ports $PORTS_JSON ..."
RESP=$(curl -sS -X POST "$TUNNEL_BASE/port/register" \
    -H 'Content-Type: application/json' \
    -d "{\"ports\":${PORTS_JSON}}")

# Parse code from JSON without python — grep/sed only
CODE=$(printf '%s' "$RESP" | sed -n 's/.*"code"[[:space:]]*:[[:space:]]*"\([A-Z0-9]\{4\}\)".*/\1/p')
if [ -z "$CODE" ]; then
    echo "[tunnel] registration failed: $RESP"
    exit 1
fi

echo "[tunnel] pairing code: $CODE"
echo "[tunnel] relay: $TUNNEL_BASE"
echo ""

# Auto-start sshd if port 22 requested and no listener
auto_start_sshd() {
    if ! command -v sshd >/dev/null 2>&1; then
        echo "[tunnel]   installing openssh-server..."
        apk add --no-cache openssh-server >/dev/null 2>&1 || { echo "[tunnel]   apk add failed"; return 1; }
    fi
    if [ ! -f /etc/ssh/ssh_host_rsa_key ] && [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        echo "[tunnel]   generating host keys (ed25519 only for speed)..."
        ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key >/dev/null 2>&1
    fi
    grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config 2>/dev/null \
        || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
    if [ ! -s /root/.ssh/authorized_keys ] && ! grep -q '^root:[^*!]' /etc/shadow 2>/dev/null; then
        echo "[tunnel]   WARNING: root has no password/authorized_keys — run 'passwd' first"
    fi
    echo "[tunnel]   launching sshd..."
    /usr/sbin/sshd 2>&1 | head -5
}

# The single source of truth for the public docroot. When fs9p is mounted
# we use /mnt/host/public directly so the host browser, SFTP (via the
# ~/public symlink), and httpd/viewer all see the exact same dir without
# any copy/symlink chain on the read path.
public_root() {
    if grep -q ' /mnt/host ' /proc/mounts 2>/dev/null; then
        printf '/mnt/host/public'
    else
        printf '%s/public' "${HOME:-/root}"
    fi
}

# Seed <docroot>/cgi-bin/ls — JSON listing endpoint for the viewer.
# Must run even when httpd is already up (user may have started it
# before upgrading this script), because BusyBox httpd picks up new
# cgi-bin scripts without a restart.
seed_public_cgi() {
    local dir
    dir="$(public_root)"
    mkdir -p "$dir/cgi-bin"
    # Bake the absolute docroot into the CGI script so listings are
    # independent of whatever cwd/HOME httpd happens to inherit.
    cat > "$dir/cgi-bin/ls" <<CGI
#!/bin/sh
printf 'Content-Type: application/json\r\n'
printf 'Access-Control-Allow-Origin: *\r\n'
printf '\r\n'
base="$dir"
CGI
    cat >> "$dir/cgi-bin/ls" <<'CGI'
qs="${QUERY_STRING:-}"
sub=$(printf '%s' "$qs" | awk -v RS='&' -F= '$1=="dir"{print $2; exit}')
sub="${sub:-/}"
dec=$(printf '%s' "$sub" | sed 's/+/ /g; s/%\(..\)/\\x\1/g')
sub=$(printf '%b' "$dec")
case "$sub" in *..*) sub="/" ;; esac
sub=$(printf '%s' "$sub" | sed 's|//*|/|g')
[ "${sub#/}" = "$sub" ] && sub="/$sub"
full="$base${sub%/}"
[ "$sub" = "/" ] && full="$base"
if [ ! -d "$full" ]; then
    printf '{"error":"not a directory","dir":"%s"}' "$sub"
    exit 0
fi
printf '{"dir":"'
printf '%s' "$sub" | sed 's/\\/\\\\/g; s/"/\\"/g'
printf '","entries":['
first=1
for f in "$full"/.[!.]* "$full"/..?* "$full"/*; do
    [ -e "$f" ] || continue
    name="${f##*/}"
    case "$name" in .|..|.\*|\*|\.\[\!\.\]\*|\.\.?\*) continue ;; esac
    if [ -d "$f" ]; then
        t=dir
        sz=0
    else
        t=file
        sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)
    fi
    nj=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
    [ $first -eq 1 ] || printf ','
    first=0
    printf '{"name":"%s","type":"%s","size":%s}' "$nj" "$t" "$sz"
done
printf ']}'
CGI
    chmod +x "$dir/cgi-bin/ls"
}

# Ensure ~/public is a symlink to /mnt/host/public so SFTP uploads (which land
# in $HOME), v86 host fs9p writes, and the viewer all see the same dir.
# Idempotent — safe to call multiple times. Falls back to a plain dir when
# /mnt/host isn't mounted (headless test runs).
ensure_public_symlink() {
    local home="${HOME:-/root}"
    local link="$home/public"
    local target="/mnt/host/public"
    if ! grep -q ' /mnt/host ' /proc/mounts 2>/dev/null; then
        mkdir -p "$link" 2>/dev/null
        return 0
    fi
    mkdir -p "$target" 2>/dev/null
    if [ -L "$link" ]; then
        if [ "$(readlink "$link")" = "$target" ]; then
            return 0
        fi
        rm -f "$link"
        ln -s "$target" "$link"
        echo "[tunnel]   ~/public -> $target (relinked)"
        return 0
    fi
    if [ -d "$link" ]; then
        if [ -n "$(ls -A "$link" 2>/dev/null)" ]; then
            cp -a "$link"/. "$target"/ 2>/dev/null || true
            echo "[tunnel]   migrated existing ~/public contents into $target"
        fi
        rm -rf "$link" 2>/dev/null || {
            # Couldn't remove (busy?) — try to empty it instead so at least
            # the dir is consistent with /mnt/host/public next time.
            echo "[tunnel]   WARNING: could not remove ~/public (cwd?). cd / and re-run."
            return 1
        }
    fi
    ln -s "$target" "$link"
    echo "[tunnel]   ~/public -> $target"
}

# Auto-start busybox httpd serving ~/public on port 8080 if requested + no listener.
auto_start_httpd() {
    ensure_public_symlink
    local dir
    dir="$(public_root)"
    if ! command -v httpd >/dev/null 2>&1; then
        # BusyBox httpd is usually built-in; if not, install busybox-extras.
        apk add --no-cache busybox-extras >/dev/null 2>&1 || true
    fi
    if ! command -v httpd >/dev/null 2>&1; then
        echo "[tunnel]   httpd not available — skipping public viewer"
        return 1
    fi
    # Seed a minimal viewer + index page if ~/public is empty.
    if [ ! -e "$dir/index.html" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
        cat > "$dir/index.html" <<'HTML'
<!DOCTYPE html><meta charset="utf-8"><title>~/public</title>
<style>body{font:14px ui-monospace,monospace;padding:2em;background:#0b0d10;color:#d5d8dc}
a{color:#4ade80;text-decoration:none}a:hover{text-decoration:underline}</style>
<h1>~/public</h1>
<p>Drop files here to share them via the tunnel.</p>
<p>Served from <code>$HOME/public</code> in the guest.</p>
HTML
    fi
    # CGI listing endpoint: BusyBox httpd serves index.html when present, so
    # the client can't get an auto-index of the root. /cgi-bin/ls?dir=/sub
    # returns a JSON listing so the viewer can always show files even when
    # index.html exists.
    seed_public_cgi
    echo "[tunnel]   launching httpd -h $dir -p 8080 ..."
    # -f = foreground mode when backgrounded manually with &
    # -h = home directory (serves static files + auto-index)
    httpd -p 127.0.0.1:8080 -h "$dir" 2>&1 | head -3
}

# Auto-start FTP on port 21 with a fixed passive range so relay can proxy
# both control and data connections.
auto_start_ftpd() {
    if ! command -v vsftpd >/dev/null 2>&1; then
        echo "[tunnel]   installing vsftpd..."
        apk add --no-cache vsftpd >/dev/null 2>&1 || {
            echo "[tunnel]   vsftpd install failed"
            return 1
        }
    fi

    if [ ! -f /etc/vsftpd/vsftpd.conf ] && [ ! -f /etc/vsftpd.conf ]; then
        mkdir -p /etc/vsftpd 2>/dev/null || true
    fi

    cat > /tmp/vsftpd-tunnel.conf <<EOF
listen=YES
listen_address=127.0.0.1
listen_port=21
background=YES
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
pasv_enable=YES
pasv_min_port=${FTP_PASV_MIN}
pasv_max_port=${FTP_PASV_MAX}
pasv_address=127.0.0.1
userlist_enable=NO
seccomp_sandbox=NO
xferlog_enable=YES
EOF

    echo "[tunnel]   launching vsftpd (passive ${FTP_PASV_MIN}-${FTP_PASV_MAX})..."
    vsftpd /tmp/vsftpd-tunnel.conf >/tmp/tunnel-ftpd.log 2>&1 || {
        echo "[tunnel]   failed to launch vsftpd (see /tmp/tunnel-ftpd.log)"
        return 1
    }
}

# Check if TCP port has a LISTEN socket via /proc/net/tcp (avoids nc hangs)
port_listening() {
    local port_hex
    port_hex=$(printf '%04X' "$1")
    # State 0A = TCP_LISTEN
    grep -qE ":${port_hex} [0-9A-F:]+ 0A " /proc/net/tcp 2>/dev/null \
        || grep -qE ":${port_hex} [0-9A-F:]+ 0A " /proc/net/tcp6 2>/dev/null
}

# Start one websocat bridge per port
for PORT in $PORTS; do
    echo "[tunnel] checking port $PORT ..."
    # Always (re)seed the CGI listing endpoint when 8080 is requested — even
    # if httpd was already running from a previous tunnel-up.sh session and
    # auto_start_httpd would be skipped, BusyBox httpd picks up new cgi-bin
    # scripts on the next request without needing a restart.
    if [ "$PORT" = "8080" ]; then
        # Set up the symlink (for SFTP) + seed CGI listing into the docroot.
        ensure_public_symlink
        seed_public_cgi
        # If an old httpd is still running with a stale -h docroot (e.g. the
        # plain ~/public dir before the symlink existed), kill it so the
        # branch below restarts it with -h /mnt/host/public.
        if port_listening 8080; then
            old_pid=$(pgrep -nf 'httpd.*-p.*8080' 2>/dev/null)
            old_root=""
            if [ -n "$old_pid" ]; then
                old_root=$(readlink -f "/proc/$old_pid/cwd" 2>/dev/null || true)
            fi
            target_root=$(public_root)
            if [ -n "$old_root" ] && [ "$old_root" != "$target_root" ]; then
                echo "[tunnel] port 8080 — restarting httpd (docroot $old_root -> $target_root)"
                pkill -f 'httpd.*-p.*8080' 2>/dev/null || true
                sleep 0.3 2>/dev/null || sleep 1
            fi
        fi
        echo "[tunnel] port 8080 — seeded $(public_root)/cgi-bin/ls (JSON listing endpoint)"
    fi
    if ! port_listening "$PORT"; then
        if [ "$PORT" = "22" ]; then
            echo "[tunnel] port 22 — no listener, starting sshd..."
            auto_start_sshd
            # Short retry (~3s)
            i=0
            while [ $i -lt 15 ]; do
                port_listening 22 && break
                i=$((i+1)); sleep 0.2 2>/dev/null || sleep 1
            done
        elif [ "$PORT" = "8080" ]; then
            echo "[tunnel] port 8080 — no listener, starting httpd on ~/public..."
            auto_start_httpd
            i=0
            while [ $i -lt 15 ]; do
                port_listening 8080 && break
                i=$((i+1)); sleep 0.2 2>/dev/null || sleep 1
            done
        elif [ "$PORT" = "21" ]; then
            echo "[tunnel] port 21 — no listener, starting ftpd (vsftpd)..."
            auto_start_ftpd
            i=0
            while [ $i -lt 15 ]; do
                port_listening 21 && break
                i=$((i+1)); sleep 0.2 2>/dev/null || sleep 1
            done
        elif is_ftp_passive_port "$PORT"; then
            # FTP passive sockets are opened on demand by vsftpd.
            # Keep relay bridge loops alive even if the port is closed now.
            echo "[tunnel] port $PORT — FTP passive (on-demand), starting bridge loop without pre-listen check"
        fi
    fi
    if ! port_listening "$PORT" && ! is_ftp_passive_port "$PORT"; then
        echo "[tunnel] port $PORT — no local listener, skipping bridge"
        continue
    fi
    WS_URL="${TUNNEL_WS}/port/guest?code=${CODE}&port=${PORT}"
    # POOL_SIZE: how many parallel guest WS bridges to keep open per port.
    #
    # The relay now uses a multi-pair queue: each guest WS sits in a per-port
    # standby pool, and each new TCP client (ssh/sftp/ftp/etc.) pops a fresh
    # bridge from the pool to pair with. This is required for parallel-capable
    # protocols — Filezilla SFTP opens 2+ concurrent SSH connections by
    # default for parallel transfers, and each one needs its own bridge.
    #
    # Default 4 keeps a healthy standby buffer for typical interactive use
    # (ssh + 2 sftp transfers + 1 spare). Each bridge consumed by a client
    # is replaced by the inner respawn loop below within ~100ms.
    #
    # Override with TUNNEL_BRIDGES_PER_PORT=N if you expect many parallel
    # clients per port (HTTP burst, large parallel rsync, many SFTP slots).
    POOL_SIZE="${TUNNEL_BRIDGES_PER_PORT:-4}"
    n=0
    while [ "$n" -lt "$POOL_SIZE" ]; do
        n=$((n+1))
        # --ping-interval 25: keep WS alive across NAT/CDN idle timeouts
        #   (Fly edge proxy and many corporate NATs drop idle WS at ~60s).
        # trap '' HUP: subshell must independently ignore SIGHUP so backgrounding
        #   tunnel-up.sh & + closing the terminal does not kill bridges.
        # No sleep on respawn: lost time = dropped requests during the gap.
        (
            trap '' HUP
            while :; do
                websocat --binary --ping-interval 25 "$WS_URL" "tcp:127.0.0.1:${PORT}" </dev/null
                # tiny jitter to avoid tight loop if TCP refused
                sleep 0.1 2>/dev/null || sleep 1
            done
        ) >> "/tmp/tunnel-${PORT}.log" 2>&1 &
        BPID=$!
        track_pid "$BPID"
        echo "[tunnel] port $PORT → bridge $n/$POOL_SIZE PID $BPID  log: /tmp/tunnel-${PORT}.log"
    done
done

echo ""
echo "──────────────────────────────────────────────────────"
echo "  Connect from any machine:"
echo ""
for PORT in $PORTS; do
    if [ "$PORT" = "22" ]; then
        echo "  SSH (one-liner, shell-safe):"
        echo "    sh <(curl -sS https://linuxontab.com/local/tunnel-ssh.sh) ${CODE}"
        echo ""
        echo "  Plain ssh/scp/sftp via local TCP listener:"
        echo "    sh <(curl -sS https://linuxontab.com/local/tunnel-listen.sh) ${CODE}"
        echo "    ssh  -p 2222 root@localhost"
        echo ""
    fi
    if [ "$PORT" = "8080" ]; then
        echo "  ~/public browser viewer:"
        echo "    https://linuxontab.com/#/viewer?code=${CODE}"
        echo ""
        echo "  ~/public direct HTTP proxy:"
        echo "    curl ${TUNNEL_BASE}/port/http/${CODE}/8080/"
        echo ""
    fi
    if [ "$PORT" = "21" ]; then
        echo "  FTP (control):"
        echo "    host: localhost (via local listener helper)"
        echo "    control port: 2121 -> guest:${PORT}"
        echo "    passive range exposed: ${FTP_PASV_MIN}-${FTP_PASV_MAX}"
        echo "    sh <(curl -sS https://linuxontab.com/local/tunnel-listen-ftp.sh) ${CODE} 2121 ${PORT} ${FTP_PASV_MIN} ${FTP_PASV_MAX}"
        echo ""
    fi
    echo "  WebSocket raw (port ${PORT}): '${TUNNEL_WS}/port/client?code=${CODE}&port=${PORT}'"
done
echo ""
echo "  Status:  curl -s '${TUNNEL_BASE}/port/status?code=${CODE}'"
echo "  Debug:   curl -s '${TUNNEL_BASE}/port/debug?code=${CODE}'"
echo "──────────────────────────────────────────────────────"
echo ""
echo "[tunnel] Bridges running. Press Ctrl-C to teardown."

# Save code for scripts that need it
printf '%s\n' "$CODE" > "$TUNNEL_CODE_FILE"
export TUNNEL_CODE="$CODE"

# Wait for interrupt, then unregister
trap '
    echo ""
    echo "[tunnel] unregistering $CODE ..."
    [ -n "${RECLAIM_PID:-}" ] && kill "$RECLAIM_PID" 2>/dev/null
    # Kill all tracked bridge subshells so websocat exits with them.
    if [ -s "$TUNNEL_PID_FILE" ]; then
        while IFS= read -r tp; do
            [ -n "$tp" ] && kill "$tp" 2>/dev/null
        done < "$TUNNEL_PID_FILE"
    fi
    curl -sS -X POST "$TUNNEL_BASE/port/unregister" \
        -H "Content-Type: application/json" \
        -d "{\"code\":\"$CODE\"}" > /dev/null
    rm -f "$TUNNEL_CODE_FILE" "$TUNNEL_PID_FILE"
    echo "[tunnel] done."
    exit 0
' INT TERM

# Reclaim watchdog ────────────────────────────────────────────────────────
# The relay may forget our code at any time:
#   - Fly tunnel-server keeps sessions in memory only; every redeploy
#     wipes them.
#   - Cloudflare Durable Object hibernation can evict idle sessions.
#   - Network partitions / proxy 502s can drop the session view.
# When that happens, the websocat respawn loops keep dialing
# /port/guest?code=... and the relay returns 403 ("code not found"),
# so traffic silently stops.
#
# This loop polls /port/status?code=$CODE and re-POSTs /port/register
# with the SAME {code, ports} body to reclaim it. Both backends accept
# `code` in the register body and idempotently restore the session
# (CF maps code → DO via idFromName(code); Fly stores by the code
# string). The websocat respawn loops then succeed on their next
# iteration without changing $CODE — so SSH/SFTP/HTTP clients holding
# the old code keep working after a Fly redeploy.
#
# Override poll interval with TUNNEL_RECLAIM_INTERVAL=N (seconds, default 20).
# Override fallback endpoint with TUNNEL_FALLBACK_BASE=... (default CF Worker).
# Inline retries: on register failure, try both endpoints up to N times
# (with backoff) before giving up and waiting the full poll interval.
RECLAIM_INTERVAL="${TUNNEL_RECLAIM_INTERVAL:-20}"
TUNNEL_FALLBACK_BASE="${TUNNEL_FALLBACK_BASE:-https://tunnel.linuxontab.com}"
RECLAIM_TRIES="${TUNNEL_RECLAIM_TRIES:-3}"
# Generous timeouts: Fly machines can cold-start for 15-25s after idle
# auto-stop. The previous 8s budget guaranteed a timeout in that window.
RECLAIM_CONNECT_TIMEOUT="${TUNNEL_RECLAIM_CONNECT_TIMEOUT:-10}"
RECLAIM_MAX_TIME="${TUNNEL_RECLAIM_MAX_TIME:-30}"
STATUS_MAX_TIME="${TUNNEL_STATUS_MAX_TIME:-10}"
(
    trap '' HUP
    # Track which endpoint last succeeded so reclaim sticks to a working
    # backend (avoids hammering a cold/dead Fly machine when CF is healthy).
    active_base="$TUNNEL_BASE"
    fallback_base="$TUNNEL_FALLBACK_BASE"
    [ "$active_base" = "$fallback_base" ] && fallback_base=""

    check_status() {
        # $1 = base url. Echos curl body, returns curl exit.
        curl -sS --connect-timeout 5 --max-time "$STATUS_MAX_TIME" \
            "$1/port/status?code=$CODE" 2>/dev/null
    }
    do_register() {
        # $1 = base url. Echos response (or curl error). Returns curl exit.
        curl -sS \
            --connect-timeout "$RECLAIM_CONNECT_TIMEOUT" \
            --max-time "$RECLAIM_MAX_TIME" \
            -X POST "$1/port/register" \
            -H 'Content-Type: application/json' \
            -d "{\"code\":\"$CODE\",\"ports\":${PORTS_JSON}}" 2>&1
    }

    while :; do
        sleep "$RECLAIM_INTERVAL" 2>/dev/null || sleep 30

        # Probe active endpoint first; if it claims the code is gone (or
        # is unreachable), also probe the fallback before declaring loss.
        STATUS=$(check_status "$active_base")
        case "$STATUS" in
            *'"active":true'*) continue ;;
        esac
        if [ -n "$fallback_base" ]; then
            ALT_STATUS=$(check_status "$fallback_base")
            case "$ALT_STATUS" in
                *'"active":true'*)
                    echo "[tunnel] reclaim: $CODE active on fallback ($fallback_base) — switching"
                    tmp="$active_base"; active_base="$fallback_base"; fallback_base="$tmp"
                    continue
                    ;;
            esac
        fi

        echo "[tunnel] reclaim: relay forgot $CODE (status=${STATUS:-<no response>}), re-registering ..."

        i=0
        ok=0
        while [ "$i" -lt "$RECLAIM_TRIES" ]; do
            i=$((i + 1))
            for base in "$active_base" "$fallback_base"; do
                [ -z "$base" ] && continue
                RESP=$(do_register "$base")
                case "$RESP" in
                    *"\"code\":\"$CODE\""*)
                        echo "[tunnel] reclaim: $CODE reclaimed via $base (try $i)"
                        active_base="$base"
                        # Demote the other endpoint to fallback for next round.
                        if [ "$base" = "$TUNNEL_BASE" ]; then
                            fallback_base="$TUNNEL_FALLBACK_BASE"
                        else
                            fallback_base="$TUNNEL_BASE"
                        fi
                        [ "$active_base" = "$fallback_base" ] && fallback_base=""
                        ok=1
                        break
                        ;;
                    *)
                        # Trim resp to a single line for log readability.
                        short=$(printf '%s' "$RESP" | tr '\n' ' ' | cut -c1-120)
                        echo "[tunnel] reclaim try $i via $base failed: ${short}"
                        ;;
                esac
            done
            [ "$ok" = 1 ] && break
            # Short backoff before next try (don't burn the whole interval).
            sleep 3 2>/dev/null || sleep 5
        done
        if [ "$ok" != 1 ]; then
            echo "[tunnel] reclaim: all retries failed — will retry in ${RECLAIM_INTERVAL}s"
        fi
    done
) &
RECLAIM_PID=$!
track_pid "$RECLAIM_PID"
echo "[tunnel] reclaim watchdog PID $RECLAIM_PID (every ${RECLAIM_INTERVAL}s)"

# Keep alive (background bridges continue)
while :; do sleep 30; done
