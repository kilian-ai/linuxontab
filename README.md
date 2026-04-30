# LinuxOnTab — Real Linux in a browser tab

> **A real x86 Linux kernel + Alpine userland, booted inside a browser tab via
> WebAssembly. Zero install. Zero server. A local-first, lightweight Docker
> alternative for instant, disposable Linux shells.**
>
> Live at **[linuxontab.com](https://linuxontab.com/)** — boot the shell at
> [linuxontab.com/shell/](https://linuxontab.com/shell/).

**Keywords:** linux in browser · webassembly linux · v86 · x86 emulator ·
alpine linux · docker alternative · local-first · in-browser terminal ·
online linux shell · browser sandbox

A standalone, browser-only Linux desktop with a file viewer, port tunnels, and
a Nostr-backed public-folder social layer. Boots a real x86 kernel + Alpine
Linux in a tab via the [v86](https://github.com/copy/v86) WebAssembly emulator
— no server, no install, no Docker daemon.

Originally extracted from the `#/shell` page of traits.build; now standalone
under **linuxontab.com**.

## Why?

| Need                                              | LinuxOnTab        | Docker         | Cloud shell    |
|---------------------------------------------------|-------------------|----------------|----------------|
| Disposable Linux shell with zero install          | ✅                 | ❌ (daemon)     | ⚠️ (account)    |
| Runs offline                                      | ✅                 | ✅              | ❌              |
| Real Linux kernel                                 | ✅ (x86 in WASM)   | ✅              | ✅              |
| Cleanup                                           | Close the tab     | Containers, volumes | Stop VM   |
| Resource cost                                     | Browser RAM       | Daemon overhead| $/hour          |
| Best for                                          | Sandboxes, demos, teaching | Reproducible builds | Long-running compute |

## Quick start (local dev)

```sh
cd shell
python3 -m http.server 8000
# open http://localhost:8000/?autoboot=1&iso=alpine.iso
```

Or just double-click `shell/index.html` (works from `file://`).

## Layout

```
LinuxOnTab/
├── index.html              SEO landing page (CTA → shell/)
├── CNAME                   linuxontab.com
├── shell/                  v86 + xterm terminal page
│   ├── index.html          main UI (entry point)
│   ├── libv86.js, v86.wasm, seabios.bin, vgabios.bin
│   ├── alpine.iso (default), linux{,3,4}.iso
│   └── xterm.js, xterm.css, xterm-addon-fit.js
├── viewer/index.html       ~/public viewer (used as #/viewer?code=XXXX)
├── local/                  guest + host helper scripts
│   ├── tunnel-up.sh, tunnel-down.sh
│   ├── tunnel-listen.sh, tunnel-listen-ftp.sh, tunnel-ssh.sh
│   └── social.sh
└── services/               backend source — deploy to own the stack end-to-end
    ├── relay/                 CF Worker → relay.linuxontab.com (DoH/CORS/WS)
    ├── relay-tunnel/          CF Worker → tunnel.linuxontab.com (port tunnels)
    └── tunnel-server-fly/     Fly Node alternative for port tunnels
```

## Endpoints

All URLs in the HTML and helper scripts already point at the linuxontab.com
brand (rebrand is done — see commits). To bring the stack online, deploy:

| Endpoint                       | Source                            | Provider             |
|--------------------------------|-----------------------------------|----------------------|
| `linuxontab.com`               | this repo via GitHub Pages        | GitHub               |
| `relay.linuxontab.com`         | `services/relay/`                 | Cloudflare Workers   |
| `tunnel.linuxontab.com`        | `services/relay-tunnel/`          | Cloudflare Workers   |
| `linuxontab-net.fly.dev`       | (fork of apptron-traits-build)    | Fly.io — WISP TCP    |
| `linuxontab-tunnel.fly.dev`    | `services/tunnel-server-fly/`     | Fly.io — tunnel fallback |
| `linuxontab-api.fly.dev`       | (Nostr REST signer; not in repo)  | Fly.io — `social.sh` |

The `linuxontab-net` Fly app must run a WISP v1 server (the same backend
apptron-traits-build uses). The `linuxontab-api` REST endpoint is only required
if you want `social.sh` to do server-side Nostr signing — you can replace
`social.sh` with a self-contained signer (`nak`, `nostril`, etc.) instead.

## Deploy checklist

1. **GitHub Pages** — push, enable Pages from `main` root, add `linuxontab.com`
   custom domain in repo settings.
2. **Cloudflare Workers**:
   ```sh
   cd services/relay-tunnel && npm i && npx wrangler deploy
   cd ../relay              && npm i && npx wrangler deploy
   ```
   Add custom-domain routes `tunnel.linuxontab.com/*` and
   `relay.linuxontab.com/*` in the CF dashboard.
3. **Fly.io** (port tunnel fallback):
   ```sh
   cd services/tunnel-server-fly && fly launch --name linuxontab-tunnel --copy-config
   ```
4. **Fly.io** (WISP TCP egress) — deploy any WISP v1 server under app name
   `linuxontab-net`, expose `wss://linuxontab-net.fly.dev/wisp`.
5. **Nostr REST** — optional; either deploy your own and point
   `linuxontab-api.fly.dev` at it, or rewrite `social.sh` to use a client-side
   signer.

## What works today

- Boot any of 4 ISOs, save/restore snapshots in IndexedDB.
- Full xterm UI with Cmd/Ctrl+C copy, Cmd+V paste, Cmd+A select-all.
- Side panels: file viewer (toggle + draggable divider + fullscreen),
  social, tunnels lifecycle.
- Inside the VM (Alpine): networking via WISP, DoH, `apk add`, `wget`,
  `curl`, ssh, ftp, syncthing.
- Expose any TCP port from the VM (after services are deployed):
  ```sh
  wget -qO- https://linuxontab.com/local/tunnel-up.sh | sh
  ```
- Mac side, plain ssh/scp:
  ```sh
  sh <(curl -sS https://linuxontab.com/local/tunnel-listen.sh) CODE
  ssh -p 2222 root@localhost
  ```

## Storage

Large binary blobs (`*.iso`, `*.wasm`, `*.bin`) are tracked with **Git LFS**.
After a regular clone, run `git lfs pull` to fetch them.

## License

Components carry their upstream licenses:
- v86 (BSD 2-Clause) — copy.sh
- xterm.js (MIT) — Microsoft / xterm contributors
- Alpine Linux ISOs — Alpine Linux project
