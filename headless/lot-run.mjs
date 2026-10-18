#!/usr/bin/env node
// lot-run — boot LinuxOnTab's wasm Linux kernel headless under Node, with the
// guest console on stdin/stdout and guest networking on the host's real
// sockets (no relay). Same kernel, images and packages as the browser tab.
//
//   lot-run                         interactive shell on the lean image (Ctrl-] quits)
//   lot-run -c 'uname -a'           run a command, print its output, exit with its status
//   lot-run --image full -c '...'   the full image (downloaded once into ~/.cache/lot-run)
//
// See headless/README.md.
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));

// The shim must be loaded with --import so that kernel workers inherit it.
if (!globalThis.__lotShim) {
  // The shim opens the log file when it loads, so --log must be in the
  // environment before the re-exec.
  const env = { ...process.env };
  const argv = process.argv.slice(2);
  const li = argv.findIndex((a) => a === "--log" || a.startsWith("--log="));
  if (li >= 0) {
    const { resolve } = await import("node:path");
    env.LOT_RUN_LOG = resolve(argv[li].startsWith("--log=") ? argv[li].slice(6) : argv[li + 1] || "lot-run.log");
  }
  const r = spawnSync(process.execPath,
    ["--import", pathToFileURL(HERE + "shim.mjs").href, fileURLToPath(import.meta.url), ...argv],
    { stdio: "inherit", env });
  process.exit(r.status ?? (r.signal ? 128 : 1));
}

const fs = await import("node:fs");
const path = await import("node:path");
const os = await import("node:os");
const crypto = await import("node:crypto");
const { parseArgs } = await import("node:util");

const REPO = path.resolve(HERE, "..");
const DIST = path.join(REPO, "shell/linux-dist");

const { values: opt } = parseArgs({
  options: {
    command: { type: "string", short: "c" },
    image: { type: "string", default: "lean" },
    rootfs: { type: "string" },
    xdisk: { type: "string" },
    mem: { type: "string", default: "2048" },
    cpus: { type: "string", default: "1" },
    dns: { type: "string" },
    "no-net": { type: "boolean", default: false },
    timeout: { type: "string", default: "0" },
    time: { type: "boolean", default: false },
    log: { type: "string" },
    "boot-log": { type: "boolean", default: false },
    help: { type: "boolean", short: "h", default: false },
  },
});

if (opt.help) {
  process.stdout.write(`usage: lot-run [options]
  -c, --command <script>   run a shell command non-interactively; exit with its status
  --image lean|full        boot image (default lean, the 3 MB auto-install image)
  --rootfs <path|url>      any ext4 image as /dev/vda (overrides --image)
  --xdisk <path|url>       extra read-only ext4 disk as /dev/vdc
  --mem <MiB>              guest RAM (default 2048)
  --cpus <n>               virtual CPUs (default 1)
  --dns <ip|doh>           guest DNS: a resolver over TCP, or DoH (default: host resolver)
  --no-net                 no network device
  --timeout <s>            kill the guest after s seconds (0 = never)
  --time                   print boot and command timings to stderr
  --boot-log               show the kernel's early boot console on stderr
  --log <file>             write runtime/network logs to <file>
`);
  process.exit(0);
}

const t0 = performance.now();
const stamp = () => ((performance.now() - t0) / 1000).toFixed(2) + "s";
const note = (s) => process.stderr.write(`\x1b[2m[lot-run ${stamp()}] ${s}\x1b[0m\n`);
const logLine = (...a) => console.log(...a);   // the shim decides where this goes

// ── Images ──────────────────────────────────────────────────────────────────
const CACHE = path.join(os.homedir(), ".cache", "lot-run");

// An ext4 image knows its own size (superblock block count x block size).
// Returns null for anything that isn't ext4.
function ext4Size(file) {
  const fd = fs.openSync(file, "r");
  try {
    const sb = Buffer.alloc(1024);
    if (fs.readSync(fd, sb, 0, 1024, 1024) < 1024 || sb.readUInt16LE(0x38) !== 0xef53) return null;
    return sb.readUInt32LE(4) * (1024 << sb.readUInt32LE(24));
  } finally { fs.closeSync(fd); }
}

// A download is complete when it matches the server's length, or failing
// that (the image route streams without one) the size its ext4 superblock
// declares.
function complete(file, total) {
  const size = fs.statSync(file).size;
  if (total) return size === total;
  const want = ext4Size(file);
  return want === null || size >= want;
}

// http(s) images are downloaded once and revalidated by ETag. The image
// route neither sends a length nor supports ranges, and a long stream can end
// early without an error, so a short download is retried from the start.
async function localImage(src) {
  if (!/^https?:\/\//.test(src)) return path.resolve(src);
  fs.mkdirSync(CACHE, { recursive: true });
  const file = path.join(CACHE, crypto.createHash("sha256").update(src).digest("hex").slice(0, 16) + "-" + path.basename(new URL(src).pathname));
  const etagFile = file + ".etag";
  // The image route ignores If-None-Match, so compare ETags from a HEAD.
  if (fs.existsSync(file) && fs.existsSync(etagFile) && complete(file, 0)) {
    try {
      const head = await fetch(src, { method: "HEAD" });
      if (head.ok && head.headers.get("etag") === fs.readFileSync(etagFile, "utf8")) return file;
    } catch {
      return file;   // offline: the cached copy is the best there is
    }
  }
  for (let attempt = 1; attempt <= 3; attempt++) {
    const res = await fetch(src);
    if (!res.ok) throw new Error(`${src}: HTTP ${res.status}`);
    const type = res.headers.get("content-type") || "";
    if (type.startsWith("text/html")) throw new Error(`${src}: got an HTML page, not a disk image`);
    const total = +res.headers.get("content-length") || 0;
    const tmp = file + ".part";
    const out = fs.openSync(tmp, "w");
    let got = 0, lastStep = -1;
    try {
      for await (const chunk of res.body) {
        fs.writeSync(out, chunk);
        got += chunk.byteLength;
        // Percent when the size is known, otherwise every 64 MiB.
        const step = total ? Math.floor((got / total) * 10) : Math.floor(got / 67108864);
        if (step !== lastStep) {
          note(`downloading ${path.basename(file)}: ${(got / 1048576).toFixed(0)}${total ? ` of ${(total / 1048576).toFixed(0)}` : ""} MiB`);
          lastStep = step;
        }
      }
    } catch (e) {
      note(`download interrupted at ${(got / 1048576).toFixed(0)} MiB: ${e.message}`);
    } finally { fs.closeSync(out); }
    if (complete(tmp, total)) {
      fs.renameSync(tmp, file);
      const etag = res.headers.get("etag");
      if (etag) fs.writeFileSync(etagFile, etag); else fs.rmSync(etagFile, { force: true });
      return file;
    }
    note(`download incomplete (${(got / 1048576).toFixed(0)} MiB), retrying (${attempt}/3)`);
    fs.rmSync(tmp, { force: true });
  }
  throw new Error(`${src}: download kept ending early`);
}

// The lean image ships as just its non-zero extents plus a manifest; expand it
// into a sparse in-memory disk (untouched pages are never committed).
function leanImage() {
  const manifest = JSON.parse(fs.readFileSync(path.join(DIST, "rootfs-lean.manifest.json"), "utf8"));
  const data = fs.readFileSync(path.join(DIST, "rootfs-lean.data"));
  const bytes = new Uint8Array(manifest.size);
  let p = 0;
  for (const [off, len] of manifest.extents) { bytes.set(data.subarray(p, p + len), off); p += len; }
  return memoryStorage(bytes);
}

function memoryStorage(bytes, readOnly = false) {
  return {
    capacity: bytes.byteLength,
    read(offset, target) {
      const n = Math.max(0, Math.min(target.byteLength, bytes.byteLength - offset));
      target.set(bytes.subarray(offset, offset + n));
      return n;
    },
    ...(readOnly ? {} : { write(offset, data) { bytes.set(data, offset); return data.byteLength; } }),
    flush() {},
  };
}

// A file-backed disk with copy-on-write: reads come from the file, writes go
// to an in-memory overlay of 4 KiB blocks, so the image file is never touched
// and N guests can share one base image.
function fileStorage(file, readOnly = false) {
  const fd = fs.openSync(file, "r");
  const capacity = fs.fstatSync(fd).size;
  const BS = 4096;
  const overlay = new Map();
  const readBase = (offset, target) => fs.readSync(fd, target, 0, target.byteLength, offset);
  return {
    capacity,
    read(offset, target) {
      const n = Math.max(0, Math.min(target.byteLength, capacity - offset));
      if (overlay.size === 0) return readBase(offset, target.subarray(0, n));
      let done = 0;
      while (done < n) {
        const pos = offset + done, blk = Math.floor(pos / BS), inBlk = pos - blk * BS;
        const take = Math.min(BS - inBlk, n - done);
        const ob = overlay.get(blk);
        if (ob) target.set(ob.subarray(inBlk, inBlk + take), done);
        else readBase(pos, target.subarray(done, done + take));
        done += take;
      }
      return n;
    },
    ...(readOnly ? {} : {
      write(offset, data) {
        let done = 0;
        while (done < data.byteLength) {
          const pos = offset + done, blk = Math.floor(pos / BS), inBlk = pos - blk * BS;
          const take = Math.min(BS - inBlk, data.byteLength - done);
          let ob = overlay.get(blk);
          if (!ob) { ob = new Uint8Array(BS); readBase(blk * BS, ob); overlay.set(blk, ob); }
          ob.set(data.subarray(done, done + take), inBlk);
          done += take;
        }
        return data.byteLength;
      },
    }),
    flush() {},
    close() { try { fs.closeSync(fd); } catch {} },
  };
}

// ── Boot ────────────────────────────────────────────────────────────────────
const { bootMachine, consoleDevice, entropyDevice, blockDevice, ethernetDevice, ethernetNetwork } =
  await import(pathToFileURL(path.join(REPO, "shell/linux-dist-7.1/dist/index.js")).href);

let rootStorage;
if (opt.rootfs) rootStorage = fileStorage(await localImage(opt.rootfs));
else if (opt.image === "full") rootStorage = fileStorage(await localImage("https://next.linuxontab.com/linux-dist/rootfs.ext4"));
else if (opt.image === "lean") rootStorage = leanImage();
else throw new Error(`unknown --image ${opt.image} (lean|full)`);
const xStorage = opt.xdisk ? fileStorage(await localImage(opt.xdisk), true) : null;
note(`rootfs ${(rootStorage.capacity / 1048576).toFixed(0)} MiB${xStorage ? `, xdisk ${(xStorage.capacity / 1048576).toFixed(0)} MiB` : ""}`);

const initcpio = new Uint8Array(fs.readFileSync(path.join(DIST, "initramfs.cpio")));

// Package drop (/dev/vdb): apk writes "LOTREQ <nonce> <file>" into block 0;
// we fetch the tarball, put it at offset 8192 and answer "LOTRSP <nonce> ok
// <file> <size>" in block 1. Same protocol as the page (see wasm.html).
const pkgDrop = new Uint8Array(100 * 1024 * 1024 + 8192);
let pkgLastReq = "", pkgGen = 0;
const pkgRsp = (text) => { pkgDrop.fill(0, 512, 1024); if (text) pkgDrop.set(new TextEncoder().encode(text + "\n"), 512); };
function pkgReq() {
  const m = /^LOTREQ (\S{1,32}) ([A-Za-z0-9._+-]{1,80})\n/.exec(new TextDecoder().decode(pkgDrop.subarray(0, 512)));
  if (!m || m[0] === pkgLastReq) return;
  const [line, nonce, rel] = m;
  pkgLastReq = line;
  const gen = ++pkgGen;
  pkgRsp("");
  (async () => {
    try {
      logLine("[pkgdrop]", rel, "requested");
      const res = await fetch("https://linuxontab.com/packages/" + rel);
      if (!res.ok) throw new Error("HTTP " + res.status);
      const bytes = new Uint8Array(await res.arrayBuffer());
      if (gen !== pkgGen) return;
      if (8192 + bytes.length > pkgDrop.length) throw new Error("too large");
      pkgDrop.set(bytes, 8192);
      pkgRsp(`LOTRSP ${nonce} ok ${rel} ${bytes.length}`);
      logLine("[pkgdrop]", rel, bytes.length, "bytes ready");
    } catch (e) {
      if (gen === pkgGen) pkgRsp(`LOTRSP ${nonce} err ${String(e && e.message || e).slice(0, 100)}`);
    }
  })();
}
const pkgDropStorage = {
  capacity: pkgDrop.byteLength,
  read(offset, target) { target.set(pkgDrop.subarray(offset, offset + target.byteLength)); return target.byteLength; },
  write(offset, data) { pkgDrop.set(data, offset); if (offset === 0) pkgReq(); return data.byteLength; },
  flush() {},
};

// Network: the page's WispSlirp on an in-process Wisp server.
let netDev = null;
if (!opt["no-net"]) {
  const { loadWispSlirp } = await import("./slirp.mjs");
  const { openLocalWisp } = await import("./local-wisp.mjs");
  const slirpConsole = { log: logLine, info: logLine, debug: logLine, warn: logLine, error: logLine };
  const { WispSlirp } = loadWispSlirp({
    wasmHtml: path.join(REPO, "shell/wasm.html"),
    search: "?nolocal=1",
    openWispTransport: (_url, protocols) => openLocalWisp(protocols, { log: logLine }),
    console: slirpConsole,
  });
  // Guest DNS: WispSlirp answers UDP/53 itself, either over DoH (null) or by
  // asking a resolver over a TCP stream. Default to the host's own resolver,
  // which is what an EC2 guest should use (the VPC resolver).
  let dns = opt.dns === "doh" ? null : opt.dns || null;
  if (!opt.dns) {
    try {
      const m = /^nameserver\s+(\d+\.\d+\.\d+\.\d+)/m.exec(fs.readFileSync("/etc/resolv.conf", "utf8"));
      if (m) dns = m[1];
    } catch {}
  }
  note(`network: host sockets, DNS ${dns || "over HTTPS"}`);
  const slirp = new WispSlirp("local:wisp", dns, null);
  const mac = crypto.getRandomValues(new Uint8Array(6));
  mac[0] = (mac[0] & 0xfe) | 0x02;   // unicast, locally administered
  const lan = ethernetNetwork();
  netDev = ethernetDevice(lan, { macAddress: Array.from(mac) });
  const port = lan.addPort((frame) => { slirp.backend.send(frame); });
  slirp.backend.receive = (frame) => { port.send(frame).catch(() => {}); };
}

// Console: stdin -> guest, guest -> stdout (+ the -c runner's watcher).
// Piped stdin is a script: run it like -c. (A prompt can't tell "waiting for
// more input" from "a slow command is running", and the guest's `exit` only
// respawns the shell, so streaming a pipe would never know when to stop.)
if (!opt.command && !process.stdin.isTTY) opt.command = fs.readFileSync(0, "utf8");
const interactive = !opt.command;
const tty = interactive && process.stdin.isTTY && process.stdout.isTTY;
const cols = process.stdout.columns || 120, rows = process.stdout.rows || 40;
let inputController;
const input = new ReadableStream({ start(c) { inputController = c; } });
const guestWrite = (s) => inputController.enqueue(typeof s === "string" ? new TextEncoder().encode(s) : s);
let onGuestOutput = (chunk) => process.stdout.write(chunk);
const output = new WritableStream({ write(chunk) { onGuestOutput(chunk); } });
const consoleDev = consoleDevice(input, output);

const args = ["loglevel=4", `nr_cpus=${+opt.cpus}`, "rcupdate.rcu_cpu_stall_suppress=1", "rdinit=/init",
  "ip=192.168.86.100::192.168.86.1:255.255.255.0::eth0:off", "lot_ip=192.168.86.100",
  `lot_epoch=${Math.floor(Date.now() / 1000)}`, `lot_tty=${rows}x${cols}`];

let finished = false;
function finish(code) {
  if (finished) return;
  finished = true;
  if (tty) try { process.stdin.setRawMode(false); } catch {}
  try { machine && machine.close(); } catch {}
  // Kernel workers never exit on their own; leave now.
  setTimeout(() => process.exit(code), 50);
}

let machine;
note(`booting Linux 7.1 (wasm32), ${opt.mem} MiB, ${opt.cpus} CPU`);
try {
  machine = await bootMachine({
    cpus: +opt.cpus, args, initcpio, memoryMiB: +opt.mem,
    // Device order is the page's: rootfs /dev/vda, package drop /dev/vdb, xdisk /dev/vdc.
    plugins: [consoleDev, entropyDevice(), blockDevice(rootStorage), blockDevice(pkgDropStorage),
      ...(netDev ? [netDev] : []), ...(xStorage ? [blockDevice(xStorage)] : [])],
  });
} catch (e) {
  note(`boot failed: ${e && e.stack || e}`);
  process.exit(1);
}
// Keep the tail of the early boot console: printed on a panic, live with --boot-log.
let bootTail = "";
(async () => {
  const d = new TextDecoder();
  for await (const c of machine.bootConsole) {
    if (opt["boot-log"]) process.stderr.write(c);
    bootTail = (bootTail + d.decode(c, { stream: true })).slice(-3000);
  }
})().catch(() => {});
machine.closed.then(() => { note("machine stopped"); finish(0); },
  (e) => {
    note(`kernel error: ${e && e.message || e}`);
    if (!opt["boot-log"] && bootTail) process.stderr.write("--- boot console (tail) ---\n" + bootTail + "\n");
    finish(1);
  });
if (tty) consoleDev.resize(cols, rows);
if (+opt.timeout > 0) setTimeout(() => { note(`timeout after ${opt.timeout}s`); finish(124); }, +opt.timeout * 1000).unref();

// The shell's first prompt marks boot done (the page's ?cmd= runner uses the same test).
let tail = "", promptTimer = null, bootDone = false;
const dec = new TextDecoder();
let bootPrompt = "";
function watchPrompt(chunk, then) {
  tail = (tail + dec.decode(chunk, { stream: true })).slice(-64);
  const pm = /(?:^|[\r\n])([^\r\n]{0,40}[#$] )$/.exec(tail);
  if (!pm) return;
  bootPrompt = pm[1];
  clearTimeout(promptTimer);
  promptTimer = setTimeout(() => { if (!bootDone) { bootDone = true; then(); } }, 400);
}

if (interactive) {
  const outFirst = onGuestOutput;
  onGuestOutput = (chunk) => { outFirst(chunk); if (!bootDone) watchPrompt(chunk, () => opt.time && note("boot complete (first prompt)")); };
  if (tty) {
    process.stdin.setRawMode(true);
    process.stderr.write("\x1b[2m[lot-run] Ctrl-] quits\x1b[0m\n");
    process.stdout.on("resize", () => consoleDev.resize(process.stdout.columns, process.stdout.rows));
  }
  process.stdin.on("data", (b) => {
    if (tty && b.includes(0x1d)) { note("quit"); return finish(0); }
    guestWrite(new Uint8Array(b));
  });
} else {
  // -c: silence the boot, then run the script with echo off between two
  // markers. The markers are typed split ("LOTB""EGIN") so the echoed command
  // line can never be mistaken for the guest's output.
  const nonce = crypto.randomBytes(4).toString("hex");
  const BEGIN = `LOTBEGIN-${nonce}\r\n`, END = new RegExp(`LOTEND-${nonce}-(\\d+)\\r?\\n`);
  let buf = "", phase = "boot", tCmd = 0, atLineStart = true;
  onGuestOutput = (chunk) => {
    if (phase === "boot") {
      watchPrompt(chunk, () => {
        if (opt.time) note("boot complete (first prompt)");
        phase = "wait-begin";
        guestWrite(`stty -echo; PS1=''; PS2=''; echo LOTB""EGIN-${nonce}\n`);
      });
      return;
    }
    buf += dec.decode(chunk, { stream: true });
    if (phase === "wait-begin") {
      const i = buf.indexOf(BEGIN);
      if (i < 0) return;
      buf = buf.slice(i + BEGIN.length);
      phase = "run";
      // The tty echoes input when it arrives, not when it is read, so the
      // script goes in only now that echo is off.
      tCmd = performance.now();
      guestWrite(opt.command.replace(/\n*$/, "\n"));
      guestWrite(`echo LOTE""ND-${nonce}-$?\n`);
    }
    const m = END.exec(buf);
    // Pass output through as it arrives; hold back only a trailing partial
    // line that could still turn into the end marker.
    let body = buf;
    if (m) body = buf.slice(0, m.index);
    else {
      const rest = buf.slice(buf.lastIndexOf("\n") + 1), marker = `LOTEND-${nonce}-`;
      if (rest && (marker.startsWith(rest) || rest.startsWith(marker))) body = buf.slice(0, buf.length - rest.length);
    }
    buf = buf.slice(body.length);
    // Some shells (the full image's) keep printing their prompt despite
    // PS1=''; drop it where it starts a line.
    if (bootPrompt) body = body.split("\n").map((l, i) => (i > 0 || atLineStart) && l.startsWith(bootPrompt) ? l.slice(bootPrompt.length) : l).join("\n");
    if (body) { process.stdout.write(body.replace(/\r\n/g, "\n")); atLineStart = body.endsWith("\n"); }
    if (m) {
      if (opt.time) note(`command finished in ${((performance.now() - tCmd) / 1000).toFixed(2)}s`);
      finish(+m[1]);
    }
  };
}

for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => (tty ? guestWrite("\x03") : finish(130)));
