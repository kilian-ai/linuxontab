# LinuxOnTab

A standalone, browser-only Linux terminal with file viewer, port tunnels, and a
Nostr-backed public-folder social layer. Boots a real x86 kernel + Alpine Linux
in a tab via the [v86](https://github.com/copy/v86) emulator — no server, no
install.

Originally extracted from [traits.build](https://www.traits.build/#/shell);
target home is **linuxontab.com**.

## Quick start (local)

```sh
cd shell
python3 -m http.server 8000
# open http://localhost:8000/?autoboot=1&iso=alpine.iso
```

Or just double-click `shell/index.html` (works from `file://`).

## Layout

```
LinuxOnTab/
├── index.html          # redirect to shell/
├── shell/              # the v86 + xterm terminal page
│   ├── index.html      # main UI (was standalone-v86.html)
│   ├── libv86.js       # v86 emulator
│   ├── v86.wasm        # v86 CPU core
│   ├── seabios.bin     # BIOS
│   ├── vgabios.bin     # VGA BIOS
│   ├── alpine.iso      # Alpine Linux (default)
│   ├── linux.iso       # Buildroot 2.6.34
│   ├── linux3.iso      # Buildroot 3.x
│   ├── linux4.iso      # Buildroot 4.16 + busybox
│   └── xterm{.js,.css,-addon-fit.js}
├── viewer/             # ~/public viewer for tunnels (#/viewer?code=XXXX)
├── local/              # guest helper scripts (run inside the VM)
│   ├── tunnel-up.sh    # expose guest TCP ports through the tunnel relay
│   ├── tunnel-down.sh
│   ├── tunnel-listen.sh, tunnel-listen-ftp.sh, tunnel-ssh.sh   # host-side
│   └── social.sh       # Nostr-backed public-folder publish/follow/sync
└── services/           # backend source (deploy these to own the domain end-to-end)
    ├── relay/                   # CF Worker — DoH, CORS proxy, /linux/tunnel WS
    ├── relay-tunnel/            # CF Worker — port tunnels (tunnel.traits.build)
    └── tunnel-server-fly/       # Fly.io Node alternative for port tunnels
```

## Network architecture

The shell is fully static, but for networking inside the VM and for tunnels
from outside, it depends on these services (all currently still pointing at
traits.build infrastructure — see migration list below):

| Service                                              | Used for                                  |
|------------------------------------------------------|-------------------------------------------|
| `wisps://apptron-traits-build.fly.dev/wisp`          | v86 NIC tunnel (real TCP egress)          |
| `https://relay.traits.build/dns-query`               | DoH (UDP/53 is dropped by Fly WISP)       |
| `https://relay.traits.build/cors?url=`               | CORS proxy                                |
| `https://tunnel.traits.build/port/*`                 | Port-tunnel relay (SSH/HTTP/FTP exposure) |
| `https://traits-build.fly.dev/traits/social/nostr`   | Nostr keygen/sign REST (called by social.sh) |
| `https://www.traits.build/local/*.sh`                | Guest-fetched helper scripts              |

When `linuxontab.com` is live, the rebrand path is:

1. Host this repo on GitHub Pages → `linuxontab.com` serves `local/*.sh`.
2. Deploy `services/relay-tunnel` as a CF Worker → `tunnel.linuxontab.com`.
3. Deploy `services/relay` as a CF Worker → `relay.linuxontab.com` (DoH/CORS).
4. Deploy `services/tunnel-server-fly` as a Fly app for raw TCP egress (replaces
   the apptron-traits-build WISP backend) → `apptron.linuxontab.com`.
5. Search/replace the URLs in `shell/index.html`, `local/tunnel-*.sh`, and
   `local/social.sh`. Endpoints currently to migrate:
   - `relay.traits.build` → `relay.linuxontab.com`
   - `tunnel.traits.build` / `traits-build-tunnel.fly.dev` → `tunnel.linuxontab.com`
   - `apptron-traits-build.fly.dev` → your Fly app host
   - `www.traits.build/local/` → `linuxontab.com/local/`
   - `traits-build.fly.dev/traits/social/nostr` → wherever you host the Nostr trait
     (or replace `social.sh` with a self-contained signer using `nak` / `nostril`).

## What works today (no migration required)

- Boot any of 4 ISOs, save/restore snapshots in IndexedDB.
- Full xterm UI with Cmd/Ctrl+C copy, Cmd+V paste, Cmd+A select-all.
- Side panels: file viewer (toggle + draggable divider + fullscreen),
  social, tunnels lifecycle.
- Inside the VM (Alpine): networking via Fly WISP, DoH, `apk add`, `wget`,
  `curl`, ssh, ftp, syncthing.
- Expose any TCP port from the VM:
  ```sh
  wget -qO- https://www.traits.build/local/tunnel-up.sh | sh
  # → prints CODE; share to access from outside
  ```
- Mac side, plain ssh/scp:
  ```sh
  sh <(curl -sS https://www.traits.build/local/tunnel-listen.sh) CODE
  ssh -p 2222 root@localhost
  ```

## License

Components carry their upstream licenses:
- v86 (BSD 2-Clause) — copy.sh
- xterm.js (MIT) — Microsoft / xterm contributors
- Alpine Linux ISOs — Alpine Linux project
- shell/index.html UI, helper scripts, services — same license as the source
  traits.build repo.
