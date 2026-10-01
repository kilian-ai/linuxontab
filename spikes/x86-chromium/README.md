# Spike: headless Chromium in the wasm guest, under Blink

**Result (2026-09-29): works.** Unmodified x86-64 Chromium 131 (Alpine 3.20
`chromium` package) runs headless inside the LinuxOnTab guest, under the
Blink x86-64 emulator from [../x86-blink](../x86-blink): it fetches a page
over HTTP from nginx in the same guest, runs the page's JavaScript, and
prints the DOM.

    ~ # /opt/x86/chromium --dump-dom http://127.0.0.1:8080/t2.html
    <!DOCTYPE html>
    <html><head><title>t</title></head><body><p id="x">JS-OK 42 Safari/537.36</p>...

About 41 s per run (start to exit, trivial page), exit status 0.

## How to run

    sh spikes/x86-chromium/make-image.sh   # -> shell/linux-dist/x86-chromium.ext4

Boot `wasm.html?xdisk=linux-dist/x86-chromium.ext4` (the page attaches the
image read-only as `/dev/vdc`), then:

    mkdir -p /opt/x86 && mount -t ext4 -o ro /dev/vdc /opt/x86
    nginx-demo                             # or any web server in the guest
    /opt/x86/chromium --dump-dom http://127.0.0.1:8080/

`/opt/x86/chromium` runs `blink chrome --headless=old --no-sandbox
--single-process --no-zygote --disable-gpu --disable-software-rasterizer
--disable-gpu-compositing --disable-dev-shm-usage --js-flags=--jitless`.
Every flag is needed: no GPU and no software GL (GL init failing is a
NOTREACHED in `gl::init::CreateGLContext`), one process (no fork server
under Blink), no JIT (V8 would generate x86 code; Blink can run it, but
`--jitless` is what was tested).

## What it took

Blink fixes (`blink-chromium.patch`, on top of `../x86-blink/blink-lot.patch`):
- **`cmpss`/`cmpsd`/`cmpps`/`cmppd` wrote the float value of the mask**
  (`x.f = Cmps(...)`: -1 became -1.0f = 0xBF800000 instead of all-ones). An
  upstream CPU bug; `gfx::Vector2dF::IsZero()` returned false for (0,0) and
  the compositor CHECK-failed. NLT/NLE now also hold for unordered operands.
- `prlimit`/`getrlimit` into a read-only page returns EFAULT (was SIGSEGV):
  Chromium's `base::ProtectedMemory` proves pages read-only that way.
  (The pointer checks were joined with `&&` instead of `||`.)
- `SOCK_SEQPACKET` socketpairs; PI futexes return EOPNOTSUPP (PulseAudio).
- virtual-address cap 64 GB -> 512 GB: PartitionAlloc, V8 and Oilpan each
  reserve 32 GB+ of PROT_NONE.
- wasm host: a 48-bit guest layout (the probe found ~32 bits and squeezed
  image, mmap arena, interpreter and stack into 4 GB); 4 KiB host pages
  (sysconf says 16 KiB; rounding unmaps down to it freed a library's first
  page still in use -> ld-musl read zeros); mprotect/msync sizes over 4 GB
  (V8's sandbox) no longer EOVERFLOW in nolinear mode; exit_group exits
  directly (waiting for threads parked in futexes ended in SIGKILL, 137).
- crash reports print before other threads are stopped, one at a time.

Host mmap (`lot_mmap-chromium.patch`, on `../x86-blink/lot_mmap.c`):
- **MAP_SHARED file mappings share one buffer per file.** They were private
  copies, so single-process Chromium's browser and renderer (Mojo shared
  memory: files in /tmp, memfd is missing) never saw each other's writes:
  the headless command page got no DevTools replies and Chromium exited 0
  without loading anything. Cached files stay open (a dup at fd >= 900) so
  ext4 can't hand their inode number to the next shm file (that mixed up
  regions: "SyntaxError" in `headless_command.js`, only with /tmp on ext4).
- munmap frees a block only when the whole mapping goes.

Page: `shell/wasm.html` `?xdisk=<path>` attaches an extra read-only disk.

Native Blink (Docker, arm64, same flags) was the test bed: the same fixes
make it print the DOM there in ~17 s (debug build, JIT off).

## Numbers

- disk: Alpine's chromium pulls 175 packages / 635 MB (mesa's 145 MB
  libLLVM, xorg drivers...). A headless run opens 417 of those files: 383 MB,
  220 MB of it the chromium binary. `chromium-files.txt` is that trace.
- memory (native Blink, same run): peak RSS ~760 MB. About 200 MB of that is
  Blink's page tables for ~100 GB of PROT_NONE reservations (64 MB of tables
  per 32 GB reserved). The wasm build declares a 4 GiB maximum and exports
  `__lot_big_memory` (the worker keeps big maxima only for such modules).
- speed: ~41 s per headless run in the guest vs ~17 s under native (debug)
  Blink. Blink's own CPU speed on wasm is close to its native debug build
  (primes bench 1.64 s vs 2.2 s); the rest is threads, syscalls and page
  faults through the guest kernel.

## Under X (xtiny)

**Native test bed: works.** The same Chromium draws a real window on xtiny
(our X server, `xtiny.c`) with no xtiny changes: antialiased text, the
infobar, the page and its JS (`xtest/native-xtiny.png`). `xtest/run-x.sh`
runs xtiny, a Python HTTP server and Chromium under native Blink in one
arm64 Alpine container and grabs xtiny's framebuffer with `xtest/snap.py`
(a minimal RFB client; xtiny always answers in RRE):

    docker run --rm --platform linux/arm64 -v $SCRATCH:/w -e APP=1 \
      -e BLINK_OPTS="-m -j" -e SNAPS="70 110" alpine:3.20 sh /w/x/run-x.sh

What the full (non-headless) browser needed on top of headless:
- `--disable-crashpad-for-testing`: Crashpad's handshake uses SO_PASSCRED,
  SCM_CREDENTIALS and signal setups Blink doesn't emulate (SO_PASSCRED is
  added to blink-chromium.patch anyway)
- (`--app=URL` at first: the location bar crashed in URL parsing — the
  host-page realloc race fixed in ../x86-blink; the full browser works now)
- `HOME=/root`: with the guest's HOME=/ Chrome can't place its profile
  ("Failed to get the path for 1001")
- GTK 3 in the image (keyboard input); its guest hang was the `lock btr`
  deadlock below
- ~960 files instead of ~420 (NSS softokn, GLib/GIO modules, ...): 398 MB

**In the guest: works (2026-10-01).** `/opt/x86/chromium-x [URL]` on xtiny
opens the full browser (tab strip, address bar) inside the wasm guest,
renders pages correctly, runs their JS, and takes mouse and keyboard input:
typing `127.0.0.1:8080/` into the address bar + Enter loads nginx-demo's page.
First paint takes ~3 min. `CHROMIUM_APP=1` gives the old toolbar-less
`--app=` window. GTK 3 must be in the image (Chrome's input method context
comes from it; without GTK typed keys never reach the page).

    # boot wasm.html?disk=full&xdisk=linux-dist/x86-chromium.ext4, then:
    mkdir -p /opt/x86 && mount -t ext4 -o ro /dev/vdc /opt/x86
    xtiny > /tmp/xtiny.log 2>&1 &
    /opt/x86/chromium-x http://127.0.0.1:8080/ > /tmp/cx.log 2>&1 &
    # page: "X display" -> "connect :5900"; click the canvas to give it keys

**One click:** console.html's Images table has a `chromium` row (kind "X
app"). It opens `wasm.html?disk=full&xdisk=linux-dist/x86-chromium.ext4&x&cmd=…`:
the page downloads the disk once (Cache Storage, keyed by its ETag), the
`cmd=` line mounts it and runs `/opt/x86/chromium-desktop` (xtiny +
nginx-demo + `chromium-x http://127.0.0.1:8080/`), and `?x` connects the X
display panel by itself. On the site the disk comes from R2
(`IMAGE=x86-chromium.ext4 cloudflare/upload-rootfs.sh`, served by
`cloudflare/functions/linux-dist/x86-chromium.ext4.js`).

What it took, all found with the debugging aids below:

1. **Main-thread deadlock — `lock btr/bts/btc` on a quadword** (GLib's
   `g_param_spec_ref_sink`): OpBit held the bus lock and wrote back with
   Store64, which on a 32-bit host takes the same (non-recursive) lock.
2. **`FUTEX_WAIT_BITSET`/`FUTEX_WAKE_BITSET`** weren't emulated (EINVAL is a
   fatal CHECK in Chrome's futex waiter); now absolute-deadline waits.
3. **Host-page slot table** (nolinear mode): every page fault appended a
   slot that was never reused, and the array was realloc()ed under lock-free
   readers; a contended page fault also freed a slot *index* as a page
   pointer. Fixed array + free list.
4. **Shared memory, the render bugs** (lot_mmap.c): a MAP_SHARED file is one
   buffer per (dev, ino), refcounted, **written back to the file on the last
   unmap** (Chrome draws into a shm file, unmaps, and the compositor maps it
   again later — the second mapping read stale bytes: blank frames), and
   Blink now has **HAVE_MAP_ANONYMOUS** on wasm (configure couldn't see it):
   without it every anonymous host allocation was an unlinked
   /tmp/blink.dat.* file that lot_mmap pinned as shared memory, ~500 pinned
   fds, the fd limit, reused inode numbers → unrelated buffers aliased
   (duplicated tiles). SQLite databases (named, writable, outside /tmp) are
   refused MAP_SHARED so it falls back to pread (the "profile error" dialog).

Debugging aids that found them:
- `BLINK_DUMP=<s> BLINK_DUMP_FILE=f` (debug Blink): every guest thread's
  registers + backtrace at that interval.
- `xtest/harness/`: native arm64 Blink built with `-DLOT_FORCE_32BIT_HOST`
  (a 32-bit host's code paths) and lot_mmap.c linked in via
  `lot_redirect.h` — reproduces wasm-only bugs at native speed (a headless
  `--screenshot` run is ~1 min instead of ~5 in the guest).
- `xtest/harness/difftest.c`: ~170 SSE/SSSE3/BMI2/PCLMUL/integer ops hashed
  over random inputs; diff real x86 vs native Blink vs wasm Blink. (Found:
  float→int out-of-range results, unpckhpd, pextrw, sqrtpd, cvtpd2ps wrong
  on every host — not yet fixed; pinsrw/SSE4.1 unimplemented.)
- In the guest, a stuck terminal is often the guest's own busybox crashing
  (lean image, `memory access out of bounds` in the console): boot
  `?disk=full` for these tests.

## Open

- **Run time is erratic.** Five runs finished in ~41 s (13:05-13:10 local,
  2026-09-29); later runs of the same image and the same Blink sat at 100%
  CPU for 3+ minutes, with 7 of 18 threads runnable and one thread at ~40 s
  of system time, on a host with load average 7-9 (and a peer-rebuilt lean
  image). One vCPU (`nr_cpus=1`) shared by Chromium's ~18 threads, several of
  them polling (Blink's 50 ms futex polling), is the suspect; not yet
  measured on a quiet host. A debug build with `-s` finished in ~4 min.
- The first run on a fresh guest builds fontconfig's cache (writable
  /var/cache/fontconfig in the guest); make-image.sh ships a prebuilt one
  when the fetched root has it.
- `file://` pages come back as text/plain in the guest (natively text/html).
  Chrome opens and reads the file fine; the MIME decision differs, so some
  computation differs between wasm Blink and native Blink. Likely another
  32-bit-host bug in Blink (`long` is 32-bit on wasm32). HTTP works.
- `/proc/<pid>/statm` reads all zeros in the guest (Chrome's memory metrics).
- Lazy PROT_NONE reservations (no page tables until touched) would save
  ~200 MB of wasm memory.
- Not packaged; the lean disk (495 MB) can't hold the root, hence `xdisk`.
