#!/bin/sh
# social.sh — Nostr-backed public folder follow/sync for v86 Alpine guests.
#
# Lays out the canonical guest convention (default root: /root):
#   /root/public/                         ← what YOU publish
#   /root/.nsec                           ← your private key (hex)
#   /root/.npub                           ← cached bech32 pubkey
#   /root/.social.tunnel                  ← cached base URL for serving public/
#   /root/following/.list                 ← npubs you follow (one per line)
#   /root/following/<npub>/               ← mirrored content from each followed user
#
# (Legacy: earlier versions used /mnt/host via 9P. The viewer now reads
#  through the tunnel CDN, so the 9P bind-mount is no longer required.
#  /mnt/host is still honored as a fallback if it exists and is writable.)
#
# Crypto goes through traits-build.fly.dev REST (social.nostr trait).
# Relay I/O via websocat. File mirror via wget.
#
# Usage:
#   social.sh init                  # generate keypair (or import: social.sh init <nsec1...>)
#   social.sh pubkey                # show your npub
#   social.sh tunnel-up [ports...]  # start tunnel-up.sh (default: 8080); cache base_url
#   social.sh publish               # build manifest of SOCIAL_HOME/public, sign, push to relays
#   social.sh follow <npub> [--no-sync]   # add to follow list, mkdir, immediate sync
#   social.sh unfollow <npub> [--purge]
#   social.sh list                  # show follow list
#   social.sh sync                  # one-shot: pull each followed user's manifest + mirror files
#   social.sh sync --watch [N]      # loop forever, default 60s
#   social.sh search <query>        # NIP-50 keyword search across relays (kind 0 profiles)
#
# Config (env overrides):
#   SOCIAL_API     default: https://traits-build.fly.dev/traits/social/nostr
#   SOCIAL_RELAYS  default: wss://relay.damus.io wss://nos.lol wss://relay.nostr.band
#   SOCIAL_HOME    default: auto (/root → /mnt/host legacy → current working directory)

set -eu

# NOTE: LinuxOnTab does not yet host its own Nostr REST signer. The default
# points at the upstream traits.build deployment, which exposes the same
# `social.nostr` trait. Override with SOCIAL_API to self-host.
API="${SOCIAL_API:-https://traits-build.fly.dev/traits/social/nostr}"
API_CANDIDATES="${SOCIAL_API_CANDIDATES:-$API https://traits-build.fly.dev/traits/social/nostr}"
RELAYS="${SOCIAL_RELAYS:-wss://relay.damus.io wss://nos.lol wss://relay.nostr.band}"

auto_home_dir() {
    # Prefer /root (real ext4/tmpfs in the v86 guest, always writable as
    # the user we run as). Fall back to /mnt/host for guests that still
    # have a 9P bind-mount populated by an older social.sh, then $PWD.
    for d in /root /mnt/host; do
        if [ -d "$d" ] || mkdir -p "$d" 2>/dev/null; then
            t="$d/.social.home.probe.$$"
            if (: > "$t") 2>/dev/null; then
                rm -f "$t" 2>/dev/null || true
                printf '%s\n' "$d"
                return 0
            fi
        fi
    done
    pwd
}

HOME_DIR="${SOCIAL_HOME:-$(auto_home_dir)}"
PUBLIC_DIR="$HOME_DIR/public"
FOLLOW_DIR="$HOME_DIR/following"
NSEC_FILE="$HOME_DIR/.nsec"
NPUB_FILE="$HOME_DIR/.npub"
TUNNEL_FILE="$HOME_DIR/.social.tunnel"
FOLLOW_LIST="$FOLLOW_DIR/.list"

die() { echo "social: $*" >&2; exit 1; }
log() { echo "[social] $*" >&2; }

need() {
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool (try: apk add $tool)"
    done
}

ensure_dirs() {
    # 9P virtio passes host UIDs through verbatim; chmod often fails with
    # EOVERFLOW ("Value too large for data type") when the host uid doesn't
    # fit the guest's 9P uid type. The reliable fix is rmdir + mkdir as long
    # as the dir is empty and the *parent* is writable.
    #
    # `[ -w DIR ]` lies under 9P (root passes the access check even when an
    # actual write fails), so we use a real write probe.
    probe_writable() {
        _t="$1/.social.probe.$$"
        if (: > "$_t") 2>/dev/null; then
            rm -f "$_t" 2>/dev/null
            return 0
        fi
        return 1
    }
    for d in "$PUBLIC_DIR" "$FOLLOW_DIR"; do
        [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
        if [ -d "$d" ] && ! probe_writable "$d"; then
            # Try chmod (often EOVERFLOW on 9P, ignore failure).
            chmod 777 "$d" 2>/dev/null || true
            if ! probe_writable "$d"; then
                # Empty and parent writable? rmdir + mkdir as current uid.
                if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
                    rmdir "$d" 2>/dev/null || rm -rf "$d" 2>/dev/null || true
                    mkdir -p "$d" 2>/dev/null || true
                fi
            fi
        fi
        [ -d "$d" ] || die "cannot create $d"
        if ! probe_writable "$d"; then
            cat >&2 <<EOF
social: $d is not writable from inside the guest.

This usually means a 9P uid mismatch from the v86 host.
Try ONE of:

  1) Restart the v86 guest after deleting the bad dir on the host:
       rm -rf '$d' on host, then restart.
  2) Set SOCIAL_HOME to a path inside the guest that is writable
     (e.g. /root) — the LinuxOnTab default since /mnt/host is deprecated:
       export SOCIAL_HOME=/root/social
       social init
EOF
            exit 1
        fi
    done
    [ -f "$FOLLOW_LIST" ] || : > "$FOLLOW_LIST"
}

# Call social.nostr trait via REST. Args: action arg1 arg2 ...
api_call() {
    need curl
    action="$1"; shift
    # Build args array as JSON
    args="\"$action\""
    for a in "$@"; do
        # JSON-escape: backslash, quote, control chars
        esc=$(printf '%s' "$a" | sed 's/\\/\\\\/g; s/"/\\"/g')
        args="$args,\"$esc\""
    done
    body="{\"args\":[$args]}"

    tmp_out=$(mktemp /tmp/social-api-out.XXXXXX)
    tmp_err=$(mktemp /tmp/social-api-err.XXXXXX)
    last_err=""
    last_body=""

    # Try configured API endpoints with transport fallbacks. Some guest networks
    # intermittently fail TLS handshakes, so we retry with HTTP/1.1 + TLSv1.2 and
    # a final plain HTTP downgrade.
    for endpoint in $API_CANDIDATES; do
        for opts in "" "--http1.1" "--http1.1 --tlsv1.2"; do
            if curl -sS --connect-timeout 8 --max-time 25 --retry 1 --retry-all-errors \
                $opts -X POST "$endpoint" -H 'Content-Type: application/json' -d "$body" \
                >"$tmp_out" 2>"$tmp_err"; then
                resp=$(cat "$tmp_out")
                if [ -n "$resp" ]; then
                    if printf '%s' "$resp" | grep -q '"error"'; then
                        last_body="$resp"
                    else
                        rm -f "$tmp_out" "$tmp_err"
                        printf '%s\n' "$resp"
                        return 0
                    fi
                fi
            fi
            [ -s "$tmp_err" ] && last_err=$(cat "$tmp_err")
        done

        case "$endpoint" in
            https://*)
                endpoint_http="http://${endpoint#https://}"
                if curl -sS --connect-timeout 8 --max-time 25 --retry 1 --retry-all-errors \
                    --http1.1 -X POST "$endpoint_http" -H 'Content-Type: application/json' -d "$body" \
                    >"$tmp_out" 2>"$tmp_err"; then
                    resp=$(cat "$tmp_out")
                    if [ -n "$resp" ]; then
                        if printf '%s' "$resp" | grep -q '"error"'; then
                            last_body="$resp"
                        else
                            rm -f "$tmp_out" "$tmp_err"
                            printf '%s\n' "$resp"
                            return 0
                        fi
                    fi
                fi
                [ -s "$tmp_err" ] && last_err=$(cat "$tmp_err")
                ;;
        esac
    done

    rm -f "$tmp_out" "$tmp_err"
    [ -n "$last_body" ] && log "api responded with error payload: $last_body"
    [ -n "$last_err" ] && log "api request failed: $last_err"
    return 1
}

# Extract a JSON field via jq if available, else crude grep fallback.
json_field() {
    if command -v jq >/dev/null 2>&1; then
        jq -r "$1 // empty" 2>/dev/null
    else
        # crude: only handles top-level "key":"value" strings
        key=$(printf '%s' "$1" | sed 's/^\.//')
        grep -o "\"$key\":\"[^\"]*\"" | head -1 | sed 's/^[^:]*:"//; s/"$//'
    fi
}

# Extract common response fields from either direct or wrapped result payloads:
#   {"nsec":"..."}
#   {"result":{"nsec":"..."}}
json_pick() {
    key="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r ".${key} // .result.${key} // empty" 2>/dev/null
    else
        grep -o "\"$key\":\"[^\"]*\"" | head -1 | sed 's/^[^:]*:"//; s/"$//'
    fi
}

cmd_init() {
    ensure_dirs
    if [ -n "${1:-}" ]; then
        # Import provided nsec
        log "importing nsec..."
        resp=$(api_call import_nsec "$1") || die "API request failed for import_nsec (set SOCIAL_API or SOCIAL_API_CANDIDATES)"
    else
        log "generating new keypair..."
        resp=$(api_call keygen) || die "API request failed for keygen (set SOCIAL_API or SOCIAL_API_CANDIDATES)"
    fi
    nsec=$(printf '%s' "$resp" | json_pick 'nsec')
    npub=$(printf '%s' "$resp" | json_pick 'npub')
    [ -n "$nsec" ] || die "no nsec in response: $resp"
    [ -n "$npub" ] || die "no npub in response: $resp"
    printf '%s\n' "$nsec" > "$NSEC_FILE"
    chmod 600 "$NSEC_FILE"
    printf '%s\n' "$npub" > "$NPUB_FILE"
    echo "npub: $npub"
    echo "nsec stored at: $NSEC_FILE"
}

cmd_pubkey() {
    [ -f "$NPUB_FILE" ] && { cat "$NPUB_FILE"; return; }
    [ -f "$NSEC_FILE" ] || die "no identity yet — run 'social.sh init'"
    nsec=$(cat "$NSEC_FILE")
    resp=$(api_call pubkey "$nsec") || die "API request failed for pubkey"
    npub=$(printf '%s' "$resp" | json_pick 'npub')
    [ -n "$npub" ] || die "no npub in response: $resp"
    printf '%s\n' "$npub" > "$NPUB_FILE"
    echo "$npub"
}

cmd_tunnel_up() {
    need curl
    ensure_dirs
    ports="${*:-8080}"

    # Prefer the locally running tunnel's actual code over the social cache.
    # tunnel-up.sh writes the live pairing code to /tmp/tunnel.code (or
    # $TUNNEL_CODE_FILE). If that file exists and the relay still has a real
    # guest bridge on port 8080, just adopt it — even if .social.tunnel
    # disagrees (common after a relay restart, manual tunnel-up.sh restart,
    # or stale social cache).
    live_code_file="${TUNNEL_CODE_FILE:-/tmp/tunnel.code}"
    live_code=""
    [ -s "$live_code_file" ] && live_code=$(head -1 "$live_code_file" 2>/dev/null | tr -dc 'A-Z0-9')
    base_host="${SOCIAL_TUNNEL_BASE:-https://linuxontab-tunnel.fly.dev}"

    # Strict-check helper: returns 0 only if relay has a guest bridge on :8080
    # for the given code (active=true alone is not enough — the session can
    # outlive its websockets).
    tunnel_alive() {
        c="$1"
        [ -n "$c" ] || return 1
        s=$(curl -sS --max-time 4 "$base_host/port/status?code=$c" 2>/dev/null) || return 1
        case "$s" in *'"code not found"'*|'') return 1 ;; esac
        # Look for "guest_ports":[...8080...] OR a non-zero queue/pair on 8080.
        case "$s" in
            *'"guest_ports":['*'8080'*) return 0 ;;
            *'"guest_queue_depth":{'*'"8080":'[1-9]*) return 0 ;;
            *'"active_pairs":{'*'"8080":'[1-9]*) return 0 ;;
        esac
        return 1
    }

    cached_url=""
    cached_code=""
    if [ -s "$TUNNEL_FILE" ]; then
        cached_url=$(head -1 "$TUNNEL_FILE" 2>/dev/null)
        cached_code=$(printf '%s' "$cached_url" | sed -n 's|.*/port/http/\([A-Z0-9]\{4\}\)/.*|\1|p')
    fi

    chosen_code=""
    chosen_reason=""
    # Priority 1 (UNCONDITIONAL): live code from /tmp/tunnel.code is the
    # source of truth. The local tunnel-up.sh respawn loop is actively
    # re-registering against the relay with this code; trust it over any
    # stale relay status (Fly tunnel-server keeps in-memory phantom
    # records across instance restarts that report active=true / phantom
    # guest_ports for codes that no longer have live websockets).
    if [ -n "$live_code" ]; then
        chosen_code="$live_code"
        chosen_reason="adopted from $live_code_file"
    # Priority 2: cached code, but only if relay confirms a live guest.
    elif [ -n "$cached_code" ] && tunnel_alive "$cached_code"; then
        chosen_code="$cached_code"
        chosen_reason="reusing — already active"
    fi

    if [ -n "$chosen_code" ]; then
        new_url="$base_host/port/http/$chosen_code/8080"
        prev_url="$cached_url"
        printf '%s\n' "$new_url" > "$TUNNEL_FILE"
        echo "tunnel code: $chosen_code  ($chosen_reason)"
        echo "base_url:    $new_url"
        # Auto-republish if URL changed and we have an identity + content.
        if [ "${SOCIAL_TUNNEL_NO_PUBLISH:-0}" != "1" ] \
            && [ -f "$NSEC_FILE" ] \
            && [ "$new_url" != "$prev_url" ]; then
            nfiles=$(count_public_files 2>/dev/null || echo 0)
            if [ "$nfiles" -gt 0 ]; then
                log "tunnel code changed ($prev_url -> $new_url) — republishing manifest"
                cmd_publish || log "auto-publish failed — run 'social publish' manually"
            fi
        fi
        return 0
    fi

    # Nothing usable — start a fresh tunnel.
    if [ -n "$cached_code" ] || [ -n "$live_code" ]; then
        log "no live tunnel found (cached=$cached_code live=$live_code) — starting fresh"
    fi
    log "starting tunnel for ports: $ports"

    # tunnel-up.sh prints CODE; capture it. Installing websocat/unbound on a
    # fresh guest can take 30-60s, so poll for the pairing code instead of
    # using a fixed sleep.
    tmp=$(mktemp /tmp/social-tunnel.XXXXXX)
    sh -c "curl -sS https://linuxontab.com/local/tunnel-up.sh | sh -s -- $ports" 2>&1 | tee "$tmp" &
    tunnel_pid=$!
    code=""
    # Poll up to ~120s for the code. tunnel-up.sh emits:
    #   [tunnel] pairing code: XXXX
    #   [tunnel] already running — pairing code: XXXX   (idempotent path)
    timeout="${SOCIAL_TUNNEL_TIMEOUT:-120}"
    elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        code=$(grep -oE '(pairing code|CODE)[: =]+[A-Z0-9]{4}' "$tmp" 2>/dev/null | head -1 | grep -oE '[A-Z0-9]{4}$' || true)
        [ -n "$code" ] && break
        # tunnel-up.sh may have exited (failure) — bail early
        kill -0 "$tunnel_pid" 2>/dev/null || break
    done
    if [ -z "$code" ]; then
        log "could not parse tunnel code after ${elapsed}s; check output above"
        rm -f "$tmp"
        return 1
    fi
    base_url="${SOCIAL_TUNNEL_BASE:-https://linuxontab-tunnel.fly.dev}/port/http/$code/8080"
    prev_url=""
    [ -f "$TUNNEL_FILE" ] && prev_url=$(head -1 "$TUNNEL_FILE" 2>/dev/null)
    printf '%s\n' "$base_url" > "$TUNNEL_FILE"
    rm -f "$tmp"
    echo "tunnel code: $code"
    echo "base_url:    $base_url"

    # If the base_url changed (new pairing code) and an identity exists,
    # auto-republish the manifest. Otherwise followers keep fetching the
    # stale code and get HTTP 503 from the relay.
    # Skip with SOCIAL_TUNNEL_NO_PUBLISH=1.
    if [ "${SOCIAL_TUNNEL_NO_PUBLISH:-0}" != "1" ] \
        && [ -f "$NSEC_FILE" ] \
        && [ "$base_url" != "$prev_url" ]; then
        nfiles=$(count_public_files 2>/dev/null || echo 0)
        if [ "$nfiles" -gt 0 ]; then
            log "tunnel code changed — republishing manifest (set SOCIAL_TUNNEL_NO_PUBLISH=1 to skip)"
            cmd_publish || log "auto-publish failed — run 'social publish' manually"
        fi
    fi
}

# Pick a non-empty public dir. Prefer $PUBLIC_DIR; otherwise scan canonical
# roots (/root, /mnt/host legacy, $HOME, $PWD) for a public/ that actually has files.
# Sets the global PUBLIC_DIR if it found a better candidate.
resolve_public_dir() {
    if [ -d "$PUBLIC_DIR" ] && [ -n "$(find "$PUBLIC_DIR" -type f 2>/dev/null | head -1)" ]; then
        return 0
    fi
    for cand in /root/public /mnt/host/public "$HOME/public" "$PWD/public"; do
        [ "$cand" = "$PUBLIC_DIR" ] && continue
        if [ -d "$cand" ] && [ -n "$(find "$cand" -type f 2>/dev/null | head -1)" ]; then
            log "using non-empty public dir: $cand (was: $PUBLIC_DIR)"
            PUBLIC_DIR="$cand"
            return 0
        fi
    done
    return 1
}

# Walk PUBLIC_DIR, emit JSON manifest content.
build_manifest_content() {
    need sha256sum
    base="${1:-}"
    printf '{"v":1'
    [ -n "$base" ] && printf ',"base":"%s"' "$base"
    printf ',"files":['
    first=1
    if [ -d "$PUBLIC_DIR" ]; then
        # POSIX find + sort for stable order
        find "$PUBLIC_DIR" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
            rel=${f#"$PUBLIC_DIR"/}
            sz=$(wc -c < "$f" | tr -d ' ')
            sh=$(sha256sum < "$f" | cut -d' ' -f1)
            [ "$first" -eq 0 ] && printf ','
            # JSON-escape rel path (basic: backslash + quote)
            relesc=$(printf '%s' "$rel" | sed 's/\\/\\\\/g; s/"/\\"/g')
            printf '{"p":"%s","h":"sha256:%s","s":%s}' "$relesc" "$sh" "$sz"
            first=0
        done
    fi
    printf ']}'
}

# Count files under PUBLIC_DIR (used for empty-manifest guard).
count_public_files() {
    [ -d "$PUBLIC_DIR" ] || { echo 0; return; }
    find "$PUBLIC_DIR" -type f 2>/dev/null | wc -l | tr -d ' '
}

cmd_publish() {
    need websocat
    [ -f "$NSEC_FILE" ] || die "no identity yet — run 'social.sh init'"
    nsec=$(cat "$NSEC_FILE")
    base=""
    [ -f "$TUNNEL_FILE" ] && base=$(cat "$TUNNEL_FILE")

    # Verify the cached base_url is still active. If the tunnel code was
    # rotated (new tunnel-up.sh invocation, Fly redeploy + reclaim
    # failure, etc.) we'd publish a manifest pointing at a 503'ing URL.
    if [ -n "$base" ] && [ "${SOCIAL_PUBLISH_SKIP_CHECK:-0}" != "1" ]; then
        cached_code=$(printf '%s' "$base" | sed -n 's|.*/port/http/\([A-Z0-9]\{4\}\)/.*|\1|p')
        if [ -n "$cached_code" ]; then
            tbase="${SOCIAL_TUNNEL_BASE:-https://linuxontab-tunnel.fly.dev}"
            status=$(curl -sS --max-time 4 "$tbase/port/status?code=$cached_code" 2>/dev/null)
            # Strict: require an actual guest bridge on port 8080. The
            # session can survive past websocket drop and report
            # active=true while serving 503s, so look for guest_ports/queue.
            ok=0
            case "$status" in
                *'"guest_ports":['*'8080'*) ok=1 ;;
                *'"guest_queue_depth":{'*'"8080":'[1-9]*) ok=1 ;;
                *'"active_pairs":{'*'"8080":'[1-9]*) ok=1 ;;
            esac
            if [ "$ok" -ne 1 ]; then
                log "WARNING: tunnel code $cached_code has no live guest bridge on :8080"
                log "         followers will get HTTP 503. run 'social tunnel-up' first to refresh."
            fi
        fi
    fi
    # Resolve non-empty public dir. If still empty, refuse to publish a
    # 0-file manifest — that just litters the relays with noise.
    resolve_public_dir || true
    nfiles=$(count_public_files)
    if [ "$nfiles" -eq 0 ]; then
        cat >&2 <<EOF
social: no files to publish under $PUBLIC_DIR

Drop something into one of these and re-run:
  $PUBLIC_DIR/
  /root/public/
Or override:  SOCIAL_HOME=/some/path social publish
EOF
        exit 2
    fi
    log "building manifest for $PUBLIC_DIR (files=$nfiles)${base:+ base=$base}"
    content=$(build_manifest_content "$base")
    bytes=$(printf '%s' "$content" | wc -c | tr -d ' ')
    log "manifest: $bytes bytes"

    # Build tags: [["d","public-folder"]] + optional ["r", base_url]
    if [ -n "$base" ]; then
        tags='[["d","public-folder"],["r","'"$base"'"]]'
    else
        tags='[["d","public-folder"]]'
    fi
    now=$(date +%s)
    log "signing event (kind 30000)..."
    resp=$(api_call sign_event "$nsec" "30000" "$content" "$tags" "$now")
    # Extract event JSON. Prefer jq when available. Fallback sed must NOT be greedy:
    # API response is {"result":{"event":{...},"ok":true}} — a naive `.*"event":\({.*}\)` matches
    # through the trailing `,"ok":true}}` wrapper and produces invalid JSON. Anchor on `,"ok":`.
    event=$(printf '%s' "$resp" | (command -v jq >/dev/null 2>&1 && jq -c '.event // .result.event' || sed -n 's/.*"event":\({.*\}\),"ok":.*/\1/p'))
    [ -n "$event" ] && [ "$event" != "null" ] || die "sign failed: $resp"

    # Extract event id for OK matching from relay responses.
    evid=$(printf '%s' "$event" | (command -v jq >/dev/null 2>&1 && jq -r '.id' || sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p') | head -1)

    msg='["EVENT",'"$event"']'
    ok_count=0
    fail_count=0
    for relay in $RELAYS; do
        # --text silences "recommend --binary or --text" warning;
        # -E (--exit-on-eof) closes the websocket once stdin EOFs (after sleep);
        # without -E (or with -n/--no-close) websocat hangs forever and the publish
        # loop never terminates.
        out=$( ( printf '%s\n' "$msg"; sleep 3 ) | websocat --text -E - "$relay" 2>/dev/null | head -5 )
        if printf '%s' "$out" | grep -q '"OK"'; then
            # NIP-20: ["OK", <id>, <true|false>, <message>]
            if printf '%s' "$out" | grep -q '"OK","'"$evid"'",true'; then
                log "→ $relay  OK"
                ok_count=$((ok_count + 1))
            else
                reason=$(printf '%s' "$out" | sed -n 's/.*"OK","[0-9a-f]*",false,"\([^"]*\)".*/\1/p' | head -1)
                log "→ $relay  REJECTED${reason:+: $reason}"
                fail_count=$((fail_count + 1))
            fi
        else
            log "→ $relay  no-ok-reply"
            fail_count=$((fail_count + 1))
        fi
    done
    npub=$(cmd_pubkey)
    echo "published as $npub  (ok=$ok_count fail=$fail_count files=$nfiles bytes=$bytes)"
    [ "$ok_count" -gt 0 ] || exit 3
}

cmd_follow() {
    npub="${1:?usage: follow <npub> [--no-sync]}"
    case "$npub" in npub1*) ;; *) die "expected npub1...";; esac
    no_sync=0
    [ "${2:-}" = "--no-sync" ] && no_sync=1
    ensure_dirs
    if grep -qx "$npub" "$FOLLOW_LIST" 2>/dev/null; then
        echo "already following: $npub"
    else
        printf '%s\n' "$npub" >> "$FOLLOW_LIST"
        mkdir -p "$FOLLOW_DIR/$npub"
        echo "now following: $npub"
    fi
    if [ "$no_sync" -eq 0 ]; then
        need websocat
        cmd_sync_one "$npub" || log "initial sync failed (try: social sync)"
    fi
}

cmd_unfollow() {
    npub="${1:?usage: unfollow <npub> [--purge]}"
    purge=0
    [ "${2:-}" = "--purge" ] && purge=1
    if [ -f "$FOLLOW_LIST" ]; then
        tmp=$(mktemp); grep -vx "$npub" "$FOLLOW_LIST" > "$tmp" || true
        mv "$tmp" "$FOLLOW_LIST"
    fi
    [ "$purge" -eq 1 ] && rm -rf "$FOLLOW_DIR/$npub"
    echo "unfollowed: $npub"
}

cmd_list() {
    [ -f "$FOLLOW_LIST" ] || { echo "(empty)"; return; }
    n=$(wc -l < "$FOLLOW_LIST" | tr -d ' ')
    echo "following $n:"
    cat "$FOLLOW_LIST"
}

# Query a relay for the latest kind-30000 d=public-folder event from <hex_pk>.
# Echoes the matching event JSON or empty.
relay_fetch_manifest() {
    relay="$1"
    hex_pk="$2"
    sub="sub-$$"
    filter='{"kinds":[30000],"authors":["'"$hex_pk"'"],"#d":["public-folder"],"limit":1}'
    req='["REQ","'"$sub"'",'"$filter"']'
    ( printf '%s\n' "$req"; sleep 4 ) | websocat --text -E - "$relay" 2>/dev/null \
        | grep -E '^\["EVENT",' | head -1
}

cmd_sync_one() {
    npub="$1"
    log "sync: $npub"
    # Decode npub → hex
    resp=$(api_call decode_npub "$npub" || true)
    hex=$(printf '%s' "$resp" | json_pick 'pubkey_hex')
    [ -n "$hex" ] || { log "  decode failed: $resp"; return 1; }

    # Try each relay until we get an event
    raw=""
    for relay in $RELAYS; do
        log "  query $relay"
        raw=$(relay_fetch_manifest "$relay" "$hex" || true)
        [ -n "$raw" ] && break
    done
    [ -n "$raw" ] || { log "  no manifest event found"; return 1; }

    if ! command -v jq >/dev/null 2>&1; then
        log "  jq required for sync (apk add jq)"; return 1
    fi
    content=$(printf '%s' "$raw" | jq -r '.[2].content')
    base=$(printf '%s' "$raw" | jq -r '.[2].tags[] | select(.[0]=="r") | .[1]' | head -1)
    if [ -z "$base" ] || [ "$base" = "null" ]; then
        # Try base from manifest content itself
        base=$(printf '%s' "$content" | jq -r '.base // empty')
    fi
    if [ -z "$base" ]; then
        log "  manifest has no base URL — skipping file mirror"
        return 0
    fi
    log "  base_url: $base"

    dest="$FOLLOW_DIR/$npub"
    mkdir -p "$dest"
    # Save the raw manifest event for inspection
    printf '%s\n' "$raw" > "$dest/.manifest.json"

    # Iterate files
    file_count=$(printf '%s' "$content" | jq '.files | length')
    log "  $file_count files"
    i=0
    while [ "$i" -lt "$file_count" ]; do
        p=$(printf '%s' "$content" | jq -r ".files[$i].p")
        h=$(printf '%s' "$content" | jq -r ".files[$i].h")
        local_path="$dest/$p"
        local_dir=$(dirname "$local_path")
        mkdir -p "$local_dir"
        # Skip if already correct hash
        if [ -f "$local_path" ]; then
            existing="sha256:$(sha256sum < "$local_path" | cut -d' ' -f1)"
            if [ "$existing" = "$h" ]; then
                i=$((i+1)); continue
            fi
        fi
        url="$base/$p"
        log "    fetch $p"
        wget -qO "$local_path.tmp" "$url" && mv "$local_path.tmp" "$local_path" \
            || { log "    failed: $url"; rm -f "$local_path.tmp"; }
        i=$((i+1))
    done
    log "  done: $npub"
}

cmd_sync() {
    need websocat
    ensure_dirs
    watch=0; interval=60
    if [ "${1:-}" = "--watch" ]; then
        watch=1
        [ -n "${2:-}" ] && interval="$2"
    fi
    while :; do
        if [ -s "$FOLLOW_LIST" ]; then
            while IFS= read -r npub; do
                [ -z "$npub" ] && continue
                cmd_sync_one "$npub" || true
            done < "$FOLLOW_LIST"
        else
            log "follow list empty"
        fi
        [ "$watch" -eq 0 ] && break
        log "sleep ${interval}s..."
        sleep "$interval"
    done
}

cmd_search() {
    need websocat
    q="${1:?usage: search <query>}"
    sub="search-$$"
    # NIP-50 search filter (relays that support it: relay.nostr.band)
    filter='{"kinds":[0],"search":"'"$q"'","limit":10}'
    req='["REQ","'"$sub"'",'"$filter"']'
    log "searching for: $q"
    for relay in $RELAYS; do
        ( printf '%s\n' "$req"; sleep 3 ) | websocat --text -E - "$relay" 2>/dev/null \
            | grep -E '^\["EVENT",' | while IFS= read -r line; do
                if command -v jq >/dev/null 2>&1; then
                    pk=$(printf '%s' "$line" | jq -r '.[2].pubkey')
                    name=$(printf '%s' "$line" | jq -r '.[2].content' | jq -r '.name // .display_name // "?"' 2>/dev/null || echo "?")
                    npub=$(api_call encode_npub "$pk" 2>/dev/null | json_pick 'npub')
                    echo "$npub  $name"
                else
                    echo "$line"
                fi
            done
    done | sort -u
}

cmd_help() {
    sed -n '2,40p' "$0"
}

case "${1:-help}" in
    init)        shift; cmd_init "$@";;
    pubkey)      shift; cmd_pubkey;;
    tunnel-up)   shift; cmd_tunnel_up "$@";;
    publish)     shift; cmd_publish;;
    follow)      shift; cmd_follow "$@";;
    unfollow)    shift; cmd_unfollow "$@";;
    list|ls)     shift; cmd_list;;
    sync)        shift; cmd_sync "$@";;
    search)      shift; cmd_search "$@";;
    help|-h|--help) cmd_help;;
    *) die "unknown command: $1 (try: social.sh help)";;
esac
