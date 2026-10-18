# lot-run: headless LinuxOnTab on Node

Boots the same wasm32 Linux 7.1 kernel, images and packages as the browser tab,
but under Node: the guest console is stdin/stdout and guest networking uses the
host's real sockets (no WISP relay). This is step 1 towards running LinuxOnTab
guests as server-side compute (an EC2-style host running many guests).

Requires Node 22.12 or newer (developed on Node 26). No npm dependencies.

```bash
node headless/lot-run.mjs                      # interactive shell, lean image (Ctrl-] quits)
node headless/lot-run.mjs -c 'uname -a'        # run a command, exit with its status
echo 'apk add jq; jq --version' | node headless/lot-run.mjs   # piped stdin runs as a script
node headless/lot-run.mjs --image full -c 'python3 --version' # full image, cached in ~/.cache/lot-run
node headless/lot-run.mjs -p 8080:8080 -c 'python3 -m http.server 8080'   # serve from the guest
node headless/bench.mjs                        # native vs guest benchmark table
```

Options: `-p/--publish [ip:]hostPort:guestPort` (repeatable, binds 127.0.0.1
unless an ip is given), `--mem <MiB>` (default 2048), `--cpus <n>`, `--rootfs <path|url>`,
`--xdisk <path|url>` (read-only `/dev/vdc`), `--dns <ip|doh>`, `--no-net`,
`--timeout <s>`, `--time`, `--boot-log`, `--log <file>`.

## How it works

| Piece | Browser tab | lot-run |
|---|---|---|
| Kernel runtime | `shell/linux-dist-7.1/dist` with Web Workers | the same bundle; its platform layer picks `node:worker_threads` |
| Console | xterm.js | stdin/stdout (raw mode on a TTY) |
| Root disk | lean extents or `rootfs.ext4` in memory + IndexedDB overlay | lean extents in memory, or any ext4 file with an in-memory copy-on-write overlay (the file is never written) |
| Packages | `/dev/vdb` package drop filled by the page's `fetch` | the same protocol, filled by Node's `fetch` |
| Network | `WispSlirp` → WebSocket → WISP relay → internet | the same `WispSlirp` class, loaded from `shell/wasm.html`, on an in-process WISP server (`local-wisp.mjs`) backed by `node:net`/`node:dgram` |
| DNS | DoH | the host's resolver from `/etc/resolv.conf` (the VPC resolver on EC2) |

Files:
- `lot-run.mjs`: the CLI. It re-executes itself with `--import shim.mjs` so that every kernel worker loads the shim too.
- `shim.mjs`: gives Node workers the `self` global the browser bundle expects, and routes `console.*` away from stdout, which carries the guest console. Logs go to `--log <file>`; without it, warnings and errors go to stderr.
- `local-wisp.mjs`: Wisp v2 (TCP + UDP) served onto real sockets. Its `allow(proto, host, port)` hook is where an egress policy, like security groups, plugs in.
- `slirp.mjs`: slices `class WispSlirp` out of `shell/wasm.html` and evaluates it with the few browser globals it needs, so the runner always uses exactly the page's networking code.
- `publish.mjs`: `-p` port forwarding. Each accepted host connection is opened inside the guest with `WispSlirp.injectConnect`, the same call the browser tunnel uses. Backpressure from the guest (`__pause__`/`__resume__`) pauses the host socket.
- `bench.mjs`: runs the same workloads natively and in a guest.

## First benchmark (Apple M3, Node 26, lean image, 1 vCPU)

| workload | native | guest | guest / native |
|---|---:|---:|---:|
| python startup x5 | 0.14 s | 1.44 s | 10.5x |
| python cpu (sum of squares, 3M) | 0.19 s | 1.20 s | 6.3x |
| python json (200k objects) | 0.20 s | 0.70 s | 3.4x |
| lua cpu (30M iterations) | 0.50 s | 0.75 s | 1.5x |
| jq (reduce over 1M) | 0.38 s | 0.99 s | 2.6x |
| fork+exec x300 | 0.50 s | 21.94 s | 43.8x |
| disk write 128 MiB | 0.16 s | 0.44 s | 2.8x |
| download 20 MB (HTTPS, TLS in the guest) | 2.76 s | 2.87 s | 1.0x |

Boot to the first shell prompt takes 3.6 s (lean) or 4.2 s (full image, once cached). Native runs use the host's own
Python 3.11, Lua 5.4 and jq 1.7.1, the same versions as the guest packages.

What this says:
- **CPU-bound code runs 1.5–6x slower than native.** That's slower than a VM, but usable for many workloads.
- **Process creation is the weak spot, at ~73 ms per fork+exec (44x slower).** Every guest process is a Node worker with its own wasm instance. Shell-script-heavy and fork-per-request workloads suffer, and so does Python startup.
- **The network is not the bottleneck.** A 20 MB download runs at native speed, about 10x what the browser tab gets through the relay.
- **Memory needs measuring on Linux.** On macOS the process peaks at 1–1.8 GiB during boot and installs (about 46 threads, one per guest process plus Node's own), then drops below 100 MiB when idle. macOS compresses idle pages, so its RSS overstates the drop. Density figures need an EC2/Linux run.

## Port forwarding results

Tested with `-p` on the same Mac:
- **HTTP from the guest:** `python3 -m http.server` served a 5 MB file at 13.4 MB/s, with a matching SHA-256. 20 parallel 5 MB downloads and 40 parallel page requests all returned 200.
- **SSH (full image, key auth):** logs in in 0.9 s, and 5 parallel sessions work. A 20 MB SFTP upload arrived intact.
- **Edge cases:** a guest port with nothing listening, or a connection made before boot finishes, is accepted and then closed at once.
- **Large SSH downloads fail.** The guest's `sshd-session` traps (`unreachable`) after about 0.6–2 MB of output to the client, both with `ssh ... cat bigfile` and with SFTP `get`. The fault is in that binary, not in the forward: HTTP downloads over the same path are fine. It is an old build (May) that probably lacks the large-allocation fix. It needs rebuilding on the current sysroot with dlmalloc.

## Known limits

- The lean image's busybox shell (hush) can't parse `$(...)` in some places. Use the full image or install `zsh` for real scripts.
- The lean busybox has no `wget` applet, and `/bin/wget` is a wrapper around it. Use `curl` (it installs on first use).
- `exit` in the guest shell doesn't stop the machine (init respawns the shell). Use `-c`, piped stdin, Ctrl-] or `--timeout`.
- All disk writes are lost on exit, the same as a browser tab without `?persist=1`.
- `--image full` downloads 768 MiB once (about 3.5 minutes here). The image route sends no length, doesn't support ranges and ignores `If-None-Match`. So the runner checks each download against the ext4 superblock, retries short ones, and revalidates the cache with a HEAD ETag check.
- Forwards are TCP only and set at startup. Inbound UDP and adding forwards at runtime would come with a host agent API.

## Next steps (towards an EC2-style host)

1. **Persistent disks.** Write the copy-on-write overlay to a file or S3 chunks; snapshots become chunk lists.
2. **IMDS.** Answer `169.254.169.254` inside the guest network with per-instance STS credentials, so the AWS CLI and SDKs work unchanged.
3. **EFS / S3.** Serve a host directory into the guest over virtio-fs (`virtio/fs.ts`, already in the kernel package).
4. **Density.** Measure on Linux, then cut the per-process worker cost: reuse workers, and share compiled user modules.
5. Move `WispSlirp` into its own module shared by `wasm.html` and the runner.
