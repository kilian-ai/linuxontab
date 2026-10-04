# Spike: Node 24 + npm (and openclaw) in the wasm guest, under Blink

x86-64 Node.js 24.18.1 and npm 11.11.0 from Alpine 3.23 run unmodified in the
LinuxOnTab guest under the Blink emulator (the build from ../x86-chromium,
4 GiB, all fixes), from a read-only extra disk:

    sh spikes/x86-node/make-image.sh                       # -> shell/linux-dist/x86-node.ext4 (117 MB)
    NAME=x86-openclaw PRE_NPM=openclaw sh spikes/x86-node/make-image.sh /tmp/lot-build/x86-oc
                                                           # -> x86-openclaw.ext4 (822 MB, 235 MB gzip'd)

Boot `wasm.html?disk=full&xdisk=linux-dist/x86-node.ext4`, then:

    mkdir -p /opt/x86 && mount -t ext4 -o ro /dev/vdc /opt/x86 && /opt/x86/x86-node-setup
    node -v; npm -v; npm install <pkg>

`x86-node-setup` mounts a tmpfs on /opt/npm (npm prefix + cache: the disk is
read-only and the rootfs nearly full) and links node/npm/npx (and baked bins
such as `openclaw`) into /usr/local/bin. The wrappers (`x86-env`) set
`BLINK_OVERLAYS=/opt/x86/root:` and `NODE_OPTIONS=--jitless`.

## Measured (guest, wasm Blink)

- `node -v` ~1 s, `npm -v` ~21 s
- `npm install is-odd` (2 packages, HTTPS from registry.npmjs.org) ~2 min; one
  TLS handshake costs ~9 s of emulated crypto
- `openclaw --version` 40 s (baked into x86-openclaw.ext4)
- `npm install -g openclaw` in the guest is impractical: 434 packages, 683 MB
  unpacked; under *native* Blink resolution alone took 19.5 min (with the
  corgi patch below) and extraction > 25 min — hours in the browser. The
  baked image installs it in an x86-64 container (`PRE_NPM`, real postinstall
  scripts and linux-x64-musl prebuilds: koffi, node-pty, fs-safe).

## What it took

- **Loader picked up host libraries**: Blink's overlay falls through to the
  host root, and musl searches /lib before /usr/lib, so `libssl.so.3` came from
  the host (arm64 in Docker → "unsupported relocation type 257/1025", which is
  also why Node 22 "failed in ld-musl" earlier). The x86 root gets
  `etc/ld-musl-x86_64.path` listing only /opt/x86/root's lib dirs.
- **The root must not contain tmp/, root/, home/...**: Blink writes into the
  first overlay that has the parent dir.
- **npm 11 fetches full packuments** for every dependency (openclaw's is
  18 MB vs a 0.75 MB corgi): make-image.sh patches arborist's
  `#fetchManifest` to corgis unless `--before`.
- Blink (../x86-chromium/blink-chromium.patch):
  - `/proc/self/exe` read as Blink itself, so `process.execPath` was Blink and
    every self-respawn (openclaw does) ran Blink with Node flags.
  - overlay errors: an EEXIST from the host layer was reported as the first
    layer's ENOENT, and a read-only first layer answered EROFS instead of
    falling through → Node's `mkdir -p /tmp/node-compile-cache/...` looped
    forever (43k mkdirs in 2 min).
- Native Blink's JIT miscomputes something in V8 (`Assertion failed:
  (default_trigger_async_id) >= (0)` on the first TLS connect); `-j` fixes it.
  The wasm build has no JIT.

## Open

- `openclaw onboard` (interactive setup) loads ~1200+ modules twice (it
  re-spawns itself): > 10 min under native Blink, much longer in the guest.
  Node's compile cache would help but openclaw's modules never go through it
  under Blink (the cache works for a plain module) — not yet understood.
- The 32-bit native harness (`blink32m`) now dies 24 instructions into
  ld-musl (`mov 8(%rdi,%rax,8),%r8` with a bogus fault address); the wasm
  build is fine.
