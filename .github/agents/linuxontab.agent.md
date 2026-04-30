# LinuxOnTab — Agent Instructions

> A standalone, browser-only Linux terminal. Boots a real x86 kernel + Alpine
> Linux in a tab via the [v86](https://github.com/copy/v86) emulator — no
> server, no install. Static site hosted on GitHub Pages, with optional CF
> Workers + Fly.io backends for port tunnels and TCP egress.
>
> - **Repository:** local at `~/.ai/LinuxOnTab` (git origin = your fork)
> - **Homepage:** https://linuxontab.com/
> - **Boots:** https://linuxontab.com/shell/
> - **Origin:** Extracted from the `#/shell` page of `traits.build`. Upstream
>   for shared logic still lives at `~/.ai/traits/Polygrait/A. traits.build/`.

---

## Project Overview

**LinuxOnTab** is a 100% static, browser-only Linux desktop:

- `shell/index.html` — main UI: v86 emulator + xterm.js terminal + side panels
  for file viewer, social, and tunnels.
- `viewer/index.html` — standalone `~/public` viewer at
  `linuxontab.com/viewer/?code=XXXX`, browses guest published files via the
  tunnel CDN.
- `local/*.sh` — guest- and host-side helper scripts (tunnel, social).
- `services/` — backend source (CF Workers + Fly.io) so the stack can be
  hosted end-to-end without depending on traits.build.

Networking inside the v86 guest goes through a **WISP v1 WebSocket** to a
Fly.io backend (`linuxontab-net.fly.dev`). DNS goes over DoH to a Cloudflare
Worker (`relay.linuxontab.com`). TCP port exposure goes through a separate
Cloudflare Worker (`tunnel.linuxontab.com`).

---

## Directory Structure

```
~/.ai/LinuxOnTab/
├── index.html              # redirect → shell/
├── CNAME                   # linuxontab.com (GitHub Pages custom domain)
├── README.md
├── shell/                  # v86 + xterm terminal page (THE app)
│   ├── index.html          # main UI (entry point) — tracks against
│   │                       #   traits/www/static/v86/standalone-v86.html upstream
│   ├── libv86.js, v86.wasm, seabios.bin, vgabios.bin
│   ├── alpine.iso (default), linux{,3,4}.iso  (Git LFS)
│   └── xterm.js, xterm.css, xterm-addon-fit.js
├── viewer/index.html       # `~/public` viewer (used as /viewer/?code=XXXX)
├── local/                  # guest + host helper scripts
│   ├── tunnel-up.sh        # guest: register + bridge ports → tunnel CDN
│   ├── tunnel-down.sh      # guest: kill tunnel bridges
│   ├── tunnel-listen.sh    # host: open local TCP listener → tunnel
│   ├── tunnel-listen-ftp.sh# host: FTP control + passive range
│   ├── tunnel-ssh.sh       # host: one-off ssh ProxyCommand wrapper
│   └── social.sh           # guest: Nostr-backed public-folder publish/follow
├── services/
│   ├── relay/                  # CF Worker → relay.linuxontab.com (DoH/CORS/WS)
│   ├── relay-tunnel/           # CF Worker → tunnel.linuxontab.com (port tunnels)
│   ├── tunnel-server-fly/      # Fly Node alternative for port tunnels
│   └── wisp-backend/fly.toml   # Fly app config for linuxontab-net (WISP v1)
└── .github/agents/
    └── linuxontab.agent.md     # ← this file
```

---

## Service topology

```
linuxontab.com              ← GitHub Pages (this repo, root index.html → /shell/)
linuxontab.com/shell/       ← v86 + xterm UI (the app)
linuxontab.com/viewer/      ← ~/public viewer

relay.linuxontab.com        ← CF Worker  (services/relay)
                              · DoH (/dns-query) → 1.1.1.1
                              · v86 NIC tunnel fallback (legacy x/net)
                              · CORS proxy

tunnel.linuxontab.com       ← CF Worker  (services/relay-tunnel)
                              · POST /port/register, GET /port/status
                              · WS   /port/guest, /port/client
                              · GET  /port/http/CODE/PORT/path  (browser viewer)

linuxontab-net.fly.dev      ← Fly app (linuxontab-net)
                              · WISP v1 server at /wisp
                              · Real tokio TCP egress for v86 guests
                              · Reuses traits binary (sys.serve)
                              · Volume: linuxontab_net_data (/data)
                              · Region: sjc

linuxontab-tunnel.fly.dev   ← Fly Node tunnel-server (services/tunnel-server-fly)
                              · Alternative / fallback to CF tunnel Worker

linuxontab-api.fly.dev      ← Optional Nostr REST signer (out of repo)
                              · social.sh keygen/sign/verify/decode_npub
                              · Replaceable with `nak` or `nostril` for self-host
```

**v86 NIC** connects directly to `wss://linuxontab-net.fly.dev/wisp` (NOT
through `relay.linuxontab.com`). The CF relay is only for DoH and (legacy)
NIC fallback. This is critical: the Fly WISP server speaks real `tokio::net::
TcpStream`, while the CF Worker can't (Worker `connect()` blocks loopback +
many CF-fronted destinations).

---

## Quickstart (in the v86 Alpine guest)

```sh
# Set root password
printf 'lot-tb-61216!\nlot-tb-61216!\n' | passwd root

# Install everything you typically need
apk add websocat curl jq openssh-server unbound

# Bring up port tunnel (registers default ports 22, 8080, 22000, 8384)
wget -qO- https://linuxontab.com/local/tunnel-up.sh | sh
# → prints 4-char CODE (e.g. ARXN)

# DNS hardening (Fly WISP drops UDP/53; force TCP via local unbound)
apk add --no-cache --upgrade unbound libcrypto3 libssl3 && \
printf '%s\n' 'server:' '  interface: 127.0.0.1' '  do-tcp: yes' \
  'forward-zone:' '  name: "."' '  forward-tcp-upstream: yes' \
  '  forward-addr: 1.1.1.1' '  forward-addr: 1.0.0.1' > /etc/unbound/unbound.conf && \
killall -q unbound 2>/dev/null; sleep 1; unbound -c /etc/unbound/unbound.conf & \
sleep 2 && printf 'nameserver 127.0.0.1\nnameserver 1.1.1.1\n' > /etc/resolv.conf
```

## Quickstart (on the Mac, after guest tunnel-up prints CODE)

```sh
# Plain ssh/scp/sftp/rsync via local TCP listener
sh <(curl -sS https://linuxontab.com/local/tunnel-listen.sh) ARXN
ssh  -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost
scp  -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null FILE root@localhost:/tmp/

# Or one-off ssh via ProxyCommand wrapper
sh <(curl -sS https://linuxontab.com/local/tunnel-ssh.sh) ARXN

# Custom local→remote port mapping (e.g. expose Syncthing GUI on :18384)
sh <(curl -sS https://linuxontab.com/local/tunnel-listen.sh) ARXN 18384 8384

# Browser viewer for ~/public
open https://linuxontab.com/viewer/?code=ARXN
```

---

## Hard-won networking lessons (must read before debugging guest networking)

1. **Fly WISP drops UDP/53.** TCP/53 works fine. Use unbound on `127.0.0.1:53`
   with `forward-tcp-upstream: yes`. UDP DNS clients (`getaddrinfo`,
   `nslookup`) silently time out. See `/memories/repo/v86_dns_fix.md` upstream.

2. **WISP v1 only has client→server credit control.** The Fly server's
   server→client side relies on raw WS/TCP backpressure (bounded mpsc +
   actix-ws backpressure). Do **not** add an `outbound_credit` gate — it
   stalls all transfers > buffer size and surfaces as `connection closed
   prematurely` at exactly 1 MB on Alpine `apk` repos.

3. **v86 snapshot restore needs an `eth0` bounce.** On snapshot restore the
   `WispNetworkAdapter` + WS are recreated fresh, but the NE2K driver inside
   x86 state does not re-emit `net0-mac`, so the adapter keeps a zero
   `vm_mac` and silently drops frames. Fix: `ip link set eth0 down/up` with
   retries, then re-apply static IPv4 (`192.168.86.100/24` + gw
   `192.168.86.1` + static ARP `52:54:00:01:02:03`). See `shell/index.html`
   `restoreNetCmd`.

4. **NEVER use `udhcpc &` after restore.** Use static IPv4. Backgrounded
   `udhcpc` races the snapshot restore and clobbers routing.

5. **Apk community APKINDEX is ~50 MB.** If it stalls at exactly 1008k →
   WISP credit gate bug (see lesson 2). If it stalls at multiple MB →
   suspect Fly hard-shutdown of long-lived WS, or v86 receive buffer
   overflow.

6. **`ip` is broken in v86 (longjmp/setjmp).** Use BusyBox `ifconfig` +
   `route` instead. `ip addr` will crash the shell. Listing interfaces:
   `cat /proc/net/dev` or `ls /sys/class/net/`.

7. **DHCP from snapshot needs DHCP defaults.** v86 + Wisp DHCP topology is
   `192.168.86.0/24` with gw `192.168.86.1`. After bounce + udhcpc, parse
   `server` from `/tmp/.udhcpc.log` and apply default route + resolv.conf.

8. **Tunnel-up.sh respawn loop is mandatory.** websocat 1.x is single-shot:
   it exits when the client disconnects. `tunnel-up.sh` wraps each port
   bridge in `while :; do websocat ...; sleep 1; done`.

9. **CF Worker tunnel must buffer guest→client bytes pre-pair.** sshd sends
   the SSH banner immediately on TCP accept. Without per-port buffering, the
   banner is dropped before any Mac client connects. Implemented in
   `services/relay-tunnel/src/index.js` (`PortSession` DO).

10. **Multi-pair queue model.** SFTP/Filezilla open multiple parallel SSH
    sessions. The relay must use a guest-pool model (`guestWs: Map<port,
    Set<ws>>` + `pairs: Map<ws, ws>`), NOT 1:1 client-per-port pairing.
    Recycling guests on new client is wrong — it kills active siblings.

---

## v86 shell UI (`shell/index.html`) conventions

- **Default tunnel command must be POSIX-portable.** BusyBox/hush in Alpine
  does not support bash process substitution `<(...)`. Use:
  ```js
  const TUNNEL_DEFAULT_CMD =
    'wget -qO- https://www.traits.build/local/tunnel-up.sh | sh -s 22 8080 22000 8384';
  ```
  Or use the `linuxontab.com/local/tunnel-up.sh` mirror once Pages is live.

- **`edit cmd` overrides persist via `localStorage`.** Default cmd is stored
  under sentinel key `__default__`. `tnEffectiveCmd(code)` resolves:
  per-code override → `__default__` override → hard-coded `TUNNEL_DEFAULT_CMD`.

- **Cmd+C / Cmd+V hooks must preserve host clipboard.** macOS users select
  text in the terminal and Cmd+C copies; Cmd+V types into stdin. Don't
  trap these globally.

- **Snapshot restore order matters:**
  1. Boot v86, wait for `boot-done`.
  2. Restore x86 state from IndexedDB.
  3. Bounce eth0 (with retry loop polling `/sys/class/net/eth0/operstate`).
  4. Apply static IPv4 + ARP.
  5. Reset resolv.conf with fallback `1.1.1.1`.
  Skipping step 3 leaves the NIC adapter dead.

- **`/shell/index.html` mostly mirrors traits/www/static/v86/standalone-v86.html
  upstream.** When fixing bugs in one, check whether the other needs the same
  fix. The upstream file is auto-vendored into LinuxOnTab on rebrand.

---

## Backend conventions

### `services/relay/` (CF Worker → relay.linuxontab.com)
- `/dns-query` — DoH passthrough to Cloudflare 1.1.1.1.
- `/x/net`, `/wisp` — legacy NIC tunnel fallback (kept for compatibility,
  but v86 should connect to Fly directly).
- CORS proxy for `relay.linuxontab.com/proxy/*`.

### `services/relay-tunnel/` (CF Worker → tunnel.linuxontab.com)
- TCP-over-WS port exposure with 4-char pairing codes.
- DO `PortSession` per code, persisted to `state.storage` (CF free plan
  hibernates DOs — restore in constructor via `state.blockConcurrencyWhile`).
- Endpoints:
  ```
  POST /port/register    { code?, ports: [22, 8080, ...] }
  WS   /port/guest?code=XXXX&port=22
  WS   /port/client?code=XXXX&port=22
  GET  /port/http/CODE/PORT/path?query   ← browser-friendly HTTP-over-WS
  GET  /port/status?code=XXXX
  POST /port/unregister  { code }
  ```
- Multi-pair queue model: `guestWs: Map<port, Set<ws>>`, `pairs: Map<ws, ws>`.

### `services/wisp-backend/` (Fly app `linuxontab-net`)
- Reuses prebuilt traits binary from upstream `apptron-traits-build` image, OR
  builds from `~/.ai/traits/Polygrait/A. traits.build/Dockerfile` via
  `fly deploy -c services/wisp-backend/fly.toml --remote-only`.
- Exposes `/wisp` (WISP v1 WebSocket — `traits/sys/serve/wisp.rs` upstream).
- Env: `TRAITS_PORT=8090`, `RELAY_URL=https://relay.linuxontab.com`,
  `RUST_LOG=info`.
- Volume mount: `linuxontab_net_data` → `/data` (binary auto-update target).
- VM: shared CPU, 1 vCPU, 256 MB RAM, region `sjc`.

### `services/tunnel-server-fly/` (Fly Node app `linuxontab-tunnel`)
- Pure-Node alternative to CF Worker tunnel.
- In-memory only (NOT persisted across deploys). Every redeploy invalidates
  active codes; guest must re-run `tunnel-up.sh`.
- Has same multi-pair queue model as the CF version.

---

## Deploy checklist

1. **GitHub Pages** — push to `main`, enable Pages from root, add
   `linuxontab.com` custom domain.
2. **Cloudflare Workers**:
   ```sh
   cd services/relay-tunnel && npm i && npx wrangler deploy
   cd ../relay              && npm i && npx wrangler deploy
   ```
   Add custom-domain routes `tunnel.linuxontab.com/*` and
   `relay.linuxontab.com/*` in CF dashboard.
3. **Fly.io WISP backend**:
   ```sh
   # Reuse upstream image:
   fly apps create linuxontab-net  # if not exists
   fly deploy -a linuxontab-net -c services/wisp-backend/fly.toml \
              --image registry.fly.io/apptron-traits-build:deployment-XXX \
              --ha=false --remote-only
   # OR build from traits.build source:
   cd ~/.ai/traits/Polygrait/A.\ traits.build
   fly deploy -a linuxontab-net -c ~/.ai/LinuxOnTab/services/wisp-backend/fly.toml \
              --ha=false --remote-only
   ```
4. **Fly.io tunnel fallback** (optional):
   ```sh
   cd services/tunnel-server-fly && fly launch --name linuxontab-tunnel --copy-config
   ```
5. **Nostr REST** (optional, only if using `social.sh`) — deploy your own,
   point `linuxontab-api.fly.dev` at it, or rewrite `social.sh` to use
   client-side `nak`/`nostril`.

---

## Common debug commands (in guest)

```sh
# DHCP + DNS refresh after suspend / WISP reconnect
ip link set eth0 down 2>/dev/null; ip link set eth0 up 2>/dev/null
killall udhcpc >/dev/null 2>&1
udhcpc -i eth0 -q -n -f -T 2 -t 5 >/dev/null 2>&1
printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > /etc/resolv.conf

# DNS over TCP via unbound (Fly WISP drops UDP/53)
apk add --no-cache --upgrade unbound libcrypto3 libssl3
printf '%s\n' 'server:' '  interface: 127.0.0.1' '  do-tcp: yes' \
  'forward-zone:' '  name: "."' '  forward-tcp-upstream: yes' \
  '  forward-addr: 1.1.1.1' '  forward-addr: 1.0.0.1' > /etc/unbound/unbound.conf
killall -q unbound 2>/dev/null; sleep 1
unbound -c /etc/unbound/unbound.conf &
sleep 2; printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
nslookup google.com

# Force WISP NIC bounce (when literal-IP HTTPS also fails)
ip link set eth0 down; sleep 1; ip link set eth0 up
udhcpc -i eth0 -q -n -f -T 2 -t 5
ip route

# Apk repos
echo "https://dl-cdn.alpinelinux.org/alpine/edge/main"      >> /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
apk update

# Tunnels
ps | grep tunnel
cat /tmp/tunnel.code /tmp/tunnel.ports 2>/dev/null
```

---

## Backend status checks

```sh
# WISP backend
curl -si https://linuxontab-net.fly.dev/health | head -3
curl -s  https://linuxontab-net.fly.dev/wisp/debug | jq .
fly logs -a linuxontab-net --no-tail 2>&1 | tail -30

# CF Workers
curl -s 'https://tunnel.linuxontab.com/port/status?code=XXXX'
curl -si https://relay.linuxontab.com/dns-query?name=cloudflare.com&type=A \
  -H 'accept: application/dns-json' | head -10

# Pages
curl -sI https://linuxontab.com/ | head -3
curl -sI https://linuxontab.com/shell/ | head -3
```

---

## Upstream relationship

The shell page (`shell/index.html`) was forked from
`~/.ai/traits/Polygrait/A. traits.build/traits/www/static/v86/standalone-v86.html`.
The WISP backend reuses the `traits` binary verbatim (`sys.serve`).

When fixing networking / v86 / WISP bugs, the fix should usually land in
**both** repos:

- **Upstream** (`traits.build`): canonical Rust source for the WISP server,
  CF Worker source, helper scripts.
- **Downstream** (`LinuxOnTab`): branded copy of the shell page + viewer +
  service configs pointing at `linuxontab.com` brand.

The `local/*.sh` scripts are **mirrors** of `traits.build/local/*.sh` that
serve from `linuxontab.com/local/*.sh` after Pages deploy. Keep them in sync
unless intentionally diverging.

---

## AGENT RULES

- Always commit to git after making changes, with a clear message.
- Never auto-update `shell/alpine.iso` or other Git LFS blobs unless
  explicitly asked. They are large and rebuilds are slow.
- Never run interactive setup wizards (`fly launch`, `wrangler login`)
  without confirmation — they prompt for cloud-account scope.
- Prefer `--remote-only` for `fly deploy` so the local Mac doesn't have to
  build a Linux container image.
- For v86 / WISP bugs, **check upstream `traits.build` first**: the
  authoritative Rust source for `wisp.rs` and the canonical
  `standalone-v86.html` live there.
- Don't add per-feature documentation files. Update this agent file with new
  lessons instead.
- Always use `git add -A` so Pages-deploy-relevant generated files (CNAME,
  index.html redirects) are captured.
- Respect Git LFS: do not commit large binaries directly; use `git lfs
  track` patterns already in `.gitattributes`.
- After modifying `services/relay/` or `services/relay-tunnel/`, run
  `npx wrangler deploy` from that directory to update the Worker.
- After modifying `services/wisp-backend/fly.toml`, redeploy with
  `fly deploy -a linuxontab-net -c services/wisp-backend/fly.toml
  --ha=false --remote-only`.
- After modifying `shell/index.html`, no build step is needed — push to
  `main` and Pages serves it. Hard-refresh the browser to bust the cache.
