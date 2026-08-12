# LinuxOnTab Kernel — Agent Instructions

> The WASM Linux kernel variant of LinuxOnTab. Boots a **real Linux 6.1 kernel
> compiled to WebAssembly** (`@tombl/linux`) instead of the v86 x86 emulator.
> No emulation overhead — native-speed processes running inside the browser.
>
> - **Repository:** local at `~/.ai/LinuxOnTab-kernel`
> - **Branch:** `feature/linux-kernel-integration`
> - **Dev URL:** `http://localhost:8765/shell/wasm.html?debuglog&autoboot`
> - **Kernel source:** `https://github.com/tombl/linux` (Linux 6.1, wasm32)
> - **Upstream static site:** `~/.ai/LinuxOnTab` (main branch, v86 version)

---

## Project Overview

`shell/wasm.html` boots a Linux 6.1 kernel compiled to `wasm32` via `@tombl/linux`.
Processes run as WASM modules inside Web Workers. The kernel manages a real ext4
rootfs, fork/exec, networking (virtio-net), and block device (ext4 image).

Key difference from the v86 branch: **no x86 emulation**. The kernel and every
userland binary are native WASM. Binaries must be compiled with a WASM toolchain
(musl-libc sysroot, clang wasm32 target) and asyncified with `wasm-opt --asyncify`.

---

## Directory Structure

```
~/.ai/LinuxOnTab-kernel/
├── serve.sh                    # Dev server (port 8765) — COOP/COEP headers required
├── build-rootfs.sh             # Rebuilds shell/linux-dist/rootfs.ext4 from rootfs/
├── rootfs/                     # Staging tree packed into rootfs.ext4
│   ├── etc/rc                  # System init script (runs after switch_root)
│   ├── etc/ssh/sshd_config     # OpenSSH sshd config
│   ├── etc/ssh/ssh_host_ed25519_key  # Pre-generated host key
│   ├── usr/local/libexec/
│   │   ├── sshd-session        # OpenSSH sshd-session, WASM standalone mode
│   │   └── sftp-server         # OpenSSH sftp-server, asyncified
│   └── sbin/busybox            # Static BusyBox (most userland)
├── shell/
│   ├── wasm.html               # THE app — WASM kernel + xterm + WispSlirp + JS tunnel
│   ├── linux-dist/             # Kernel distribution (from @tombl/linux npm package)
│   │   ├── dist/               # index.js, Machine/BlockDevice/NetworkDevice APIs
│   │   ├── vmlinux.wasm        # Linux 6.1 kernel compiled to WASM
│   │   ├── initramfs.cpio      # Initramfs (switch_root → rootfs.ext4)
│   │   └── rootfs.ext4         # 64MB ext4 rootfs (rebuilt by build-rootfs.sh)
│   ├── coi-serviceworker.js    # SharedArrayBuffer COOP/COEP polyfill
│   └── xterm.js, xterm.css, xterm-addon-fit.js
├── kernels/linux/              # tombl/linux kernel source (clone when needed)
├── services/                   # CF Workers + Fly backends (same as main branch)
└── .github/agents/
    ├── linuxontab.agent.md     # LinuxOnTab v86 agent (main branch)
    └── lot-kernel.agent.md     # ← this file
```

---

## Dev Workflow

```sh
cd ~/.ai/LinuxOnTab-kernel

# Start dev server (required — file:// doesn't work; SharedArrayBuffer needs HTTPS headers)
./serve.sh 8765
# → http://localhost:8765/shell/wasm.html?debuglog&autoboot

# URL params:
#   ?autoboot       boot + start SSH tunnel automatically on page load
#   ?debuglog       POST syscall traces to /log → /tmp/wasm-kernel-debug.log
#   ?cachebust=N    force reload of rootfs.ext4 / initramfs.cpio

# Rebuild rootfs after changing files in rootfs/
./build-rootfs.sh

# After any change to wasm.html or rootfs:
# No build step — just hard-refresh the browser (Cmd+Shift+R).
# The dev server has Cache-Control: no-store so assets always reload.
```

The debug log lives at `/tmp/wasm-kernel-debug.log` and is appended to on every
POST to `/log`. Use it to trace syscalls, boot events, and tunnel activity.

### E2E Playwright Tests

```sh
# Install once:
mkdir -p /tmp/pw-test && cd /tmp/pw-test && npm init -y && npm i playwright
npx playwright install chromium

# Run the clang E2E test:
cd ~/.ai/LinuxOnTab-kernel
NODE_PATH=/tmp/pw-test/node_modules node test-clang.js
# → Expects: "CLANG_EXIT_0" printed, test passes
```

`test-clang.js` boots the kernel, runs `clang -cc1 -triple wasm32-unknown-unknown -emit-obj -o /tmp/t.o /tmp/t.c`, checks exit code.  
Boot detection regex: `/~\s*#/` (NOT end-of-string — kernel prints wasm_call_clone messages AFTER the prompt).  
URL: `http://localhost:8765/shell/wasm.html?autoboot&debuglog&cachebust=27`

---

## @tombl/linux Kernel Architecture

The kernel runs as a WASM module in the main thread. Each Linux **process** runs
in its own **Web Worker** as a separate WASM module instance (the userland binary).
Workers are managed by the kernel via a shared protocol.

```
Browser main thread
  └─ vmlinux.wasm (Linux 6.1)
       ├─ Web Worker: sh (PID 1)    ← /sbin/getty → /bin/sh
       ├─ Web Worker: sh (PID 46)   ← sshd-session instance
       └─ Web Worker: ...
```

**Key APIs** (from `linux-dist/dist/index.js`):
```js
import { Machine, BlockDevice, ConsoleDevice, EntropyDevice, NetworkDevice }
  from './linux-dist/dist/index.js';

const machine = new Machine({ /* config */ });
const netDev  = new NetworkDevice(guestMac, slirp.backend);
// slirp.backend = { send: frame => ..., receive: null }
// NetworkDevice sets backend.receive to a callback that injects frames into kernel
```

**Asyncify**: The kernel uses `wasm-asyncify` so that blocking syscalls
(`accept`, `read`, `ppoll`, etc.) can yield the JS thread without blocking it.
Every userland binary must also be asyncified via `wasm-opt --asyncify -O1`.

---

## WASM Binary Porting — Critical Rules

### Rule 1: `--import-memory` is mandatory for asyncified binaries

The kernel places asyncify rewind data at `~0x210000` (2MB+). A WASM binary
with its **own** memory section (default link behavior) only has a small initial
memory (e.g. 9 pages = 576KB) → OOB crash, `Error: memory access out of bounds`.

**Every binary linked for the WASM kernel must import memory:**
```make
LDFLAGS += -Wl,--import-memory \
           -Wl,--export-memory \
           -Wl,--export-table \
           -Wl,--export=__heap_base \
           -Wl,--export=__data_end \
           -Wl,--shared-memory \
           -Wl,--max-memory=268435456
# Also remove -pie from LDFLAGS — incompatible with --import-memory
```

**Verify a binary is correct:**
```sh
wasm-objdump -x binary.wasm | grep -i memory
# GOOD: Import[1]: env.memory          ← kernel provides memory
# BAD:  Memory[1] initial=9 pages      ← binary has own 576KB memory → OOB crash
```

### Rule 2: Fork-based daemons need standalone-mode patches

Any daemon that does `execv(argv[0])` to re-exec itself after `accept()` will
fail silently in WASM (the kernel doesn't support process self-re-exec in the
same way). **Pattern**: patch to skip the re-exec and call the connection handler
inline. Also bypass privilege separation forks.

**OpenSSH sshd-session patches applied** (`/tmp/openssh-9.9p2/sshd-session.c`):
- **Patch A**: skip re-exec (already running in sshd-session mode from the start)
- **Patch B**: skip privilege separation fork (`UsePrivilegeSeparation no` equivalent)
- **Patch C**: use accepted fd directly rather than passing via socketpair
- **Patch E**: call the session handler inline instead of execv

### Rule 3: Asyncify transform is a separate step

After linking, asyncify with `wasm-opt`:
```sh
wasm-opt --asyncify -O1 /tmp/openssh-9.9p2/sshd-session \
  -o /tmp/sshd-session.asyncified
```
`build-rootfs.sh` applies asyncify to ALL WASM binaries in `rootfs/` automatically,
**except** those listed in `WASM_OPT_SKIP` (pre-patched binaries like `sshd-session`).

### Rule 4: Blocked syscalls wake up correctly via `backend.receive`

You don't need special wakeup logic. Inject a valid TCP frame via
`slirp.backend.receive(ethFrame)` → kernel's TCP stack processes it → wakes up
the blocked worker (e.g. `accept()` returns). The asyncify mechanism handles all
of this transparently.

### Rule 5: Link against the FIXED musl sysroot (mallocng 0x8000 bug)

The original wasm32-musl mallocng `alloc_meta()` discarded sbrk's return and
used the constant address 0x8000 as its meta-area base — malloc metadata
overwrote bytes 0x8000–0xC000 of every process (rodata/data at default
`--global-base=1024`, small binaries' stack region, and eventually malloc's
own earlier meta areas). This caused years of "random" corruption (the CPython
saga). Use `toolchain/musl-sysroot-fixed` (or `toolchain/cpp-sysroot-fixed`);
`packages/build-package.sh` also byte-patches any staged binary that still
links a buggy libc (pattern `41 7f 46 0d 03 41 80 80 02 21 02`), pre-asyncify.
Binaries not yet rebuilt with the fix: dropbear/sshd family, wasm3,
wsbridge/mininetd, xkbcomp, in-guest clang/wasm-ld/wasm-opt.

### Build Toolchain (on Mac)

> **ALWAYS use `toolchain/musl-sysroot-fixed` — never the Nix musl-sysroot
> directly.** The original Nix sysroot's mallocng `alloc_meta()` uses a
> hardcoded `0x8000` as its meta-area base (it discards sbrk's return), so
> every binary linked against it has malloc silently overwrite bytes
> 0x8000–0xC000 of its own memory. Fixed July 2026; see
> `toolchain/patches/musl-mallocng-alloc-meta-sbrk.patch` and
> `toolchain/build-musl-sysroot-fixed.sh`. For C++ builds use
> `toolchain/cpp-sysroot-fixed` (same fix applied). `packages/build-package.sh`
> and the `Makefile` already default to the fixed sysroots.

```sh
CLANG=/nix/store/sa4f4iaw4zmkdnfiidjpys8dlgkzridc-clang/bin/clang
SYSROOT=~/.ai/LinuxOnTab-kernel/toolchain/musl-sysroot-fixed
WASM_LD=/nix/store/l62m9j22mhh21n6w9g3rzb5f8kp55f8a-lld-19.1.7/bin/wasm-ld
WASM_OPT=/opt/homebrew/bin/wasm-opt  # brew install binaryen
TARGET=wasm32-unknown-unknown         # or wasm32-wasi

# Compile a C file:
$CLANG -target wasm32 --sysroot=$SYSROOT -c foo.c -o foo.o

# Link (with import-memory):
PATH="$dir_of_wasm_ld:$PATH" $CLANG -target wasm32 --sysroot=$SYSROOT \
  -fuse-ld=lld -static \
  -Wl,--import-memory -Wl,--export-memory -Wl,--export-table \
  -Wl,--export=__heap_base -Wl,--export=__data_end \
  -Wl,--shared-memory -Wl,--max-memory=268435456 \
  foo.o -o foo.wasm

# Asyncify:
wasm-opt --asyncify -O1 foo.wasm -o foo.asyncified.wasm
```

---

## ARM64 Syscall Numbers

The kernel uses **ARM64/AArch64 syscall numbers** (NOT x86). Critical ones:

| nr  | Syscall       | nr  | Syscall      |
|-----|---------------|-----|--------------|
| 56  | openat        | 172 | getpid       |
| 57  | close         | 174 | getuid       |
| 62  | lseek         | 198 | socket       |
| 63  | read          | 200 | bind         |
| 64  | write         | 201 | listen       |
| 73  | ppoll         | 202 | accept       |
| 93  | exit          | 203 | connect      |
| 94  | exit_group    | 204 | getpeername  |
| 96  | gettimeofday  | 205 | getsockname  |
| 134 | rt_sigaction  | 206 | sendto       |
| 155 | getrusage     | 208 | setsockopt   |
| 159 | sched_yield   | 209 | getsockopt   |
| 166 | umask         | 221 | execve       |
| 167 | prctl         | 291 | statx        |
| 403 | clock_gettime |     |              |

---

## Syscall Compatibility Matrix (Keep Updated)

This matrix reflects the current worker-layer syscall behavior in `shell/linux-dist/dist/worker.js`.
Update this section every time a syscall shim/bug/workaround changes.

| Syscall nr | Name | Current status | Handling path | Notes |
|---|---|---|---|---|
| 19 | `epoll_create` | shimmed | worker.js | Legacy epoll create path mapped to fake epoll fd map |
| 20 | `epoll_create1` | shimmed | worker.js | Returns fake epoll fd from JS map |
| 21 | `epoll_ctl` | shimmed | worker.js | Tracks fd/event entries in JS map |
| 22 | `epoll_pwait` | shimmed | worker.js | Reports registered fds readable; avoids kernel OOB path |
| 441 | `epoll_pwait2` | shimmed | worker.js | Uses same JS-ready semantics as `epoll_pwait` |
| 38 | `renameat` | shim-assisted | worker.js + kernel syscall | Used to commit mmap-generated wasm buffers before rename |
| 46 | `ftruncate` | shim-assisted | worker.js + kernel syscall | Tracks candidate output fd+size for wasm writeback fix |
| 57 | `close` | partially shimmed | worker.js + kernel syscall | Fake epoll fds are intercepted; real fds go to kernel |
| 132 | `sigaltstack` | shimmed | worker.js | Returns success + `SS_DISABLE` state |
| 144 | `setgid` | shimmed | worker.js | Returns success to avoid OpenSSH session abort on ENOSYS |
| 147 | `setresuid` | shimmed | worker.js | Returns success to avoid post-auth OpenSSH session exit (255) |
| 149 | `setresgid` | shimmed | worker.js | Returns success to avoid post-auth OpenSSH session exit (255) |
| 159 | `sched_yield` | shimmed | worker.js | Returns success to avoid ENOSYS retry loops |
| 278 | `getrandom` | shimmed | worker.js | Fills userspace buffer from Web Crypto; returns byte count |
| 220 | `clone` | shimmed for WASM fork cases | worker.js + kernel syscall | Handles asyncify fork/vfork/NOMMU clone flow |
| 403 | `clock_gettime` | shimmed | worker.js | Bypasses known kernel copy-to-user crash |
| 9999 | custom `fork` | shimmed | worker.js + kernel syscall | Asyncify unwind/rewind custom path |
| 10000 | custom `vfork` | shimmed | worker.js + kernel syscall | Asyncify unwind/rewind custom path |

Known gaps to prioritize:
- Any repeated `ret=-38` (ENOSYS) or `call() error` signatures in debug logs should be promoted into this matrix.

Observed negative-return baseline (clean Python startup run after current shims):
- `57:-9` appears frequently (EBADF on `close`) and is currently treated as expected noisy userland behavior.
- `221:-2` (ENOENT on `execve`) appears frequently and is expected during shell probing/startup.
- `260:-10` (ECHILD on wait-family syscall) appears repeatedly in shell control flow and is currently non-fatal.
- `291:-2` (ENOENT on `statx`) appears during lookup probes and is currently non-fatal.
- `71:-22`, `78:-22`, `29:-25`, `56:-2/-17`, `34:-17`, `36:-17` were observed at low volume and currently classified as expected/benign for startup scripts.

Escalation rule for this baseline:
- Do not immediately shim these errno returns if Python/boot still progresses; only escalate when a return code newly correlates with fatal `call() error`, process death, or a reproducible feature regression.

---

## Syscall-First Error Triage (Mandatory)

For every runtime error, agents must check syscall health first before patching userland.

1. Always inspect syscall trace evidence first:
  - `rg -n "sc nr=.*ret=-|call\(\) error|unreachable|memory access out of bounds" /tmp/wasm-kernel-debug.log | tail -200`
2. Map failing syscall numbers to ARM64 names and this matrix.
3. Classify each failure as one of:
  - missing (`ENOSYS` / `ret=-38`)
  - kernel bug (trap/OOB/unreachable)
  - userland misuse/regression
4. If missing/buggy syscall is plausible for the failure path, implement or refine shim first.
5. Re-test and only then proceed to userland patches.
6. Update this matrix and notes immediately after each syscall fix.

This is a hard requirement: syscall checks are the first debugging step for new failures.

---

## Syscall Tracing / Debug Methodology

The debug log (`/tmp/wasm-kernel-debug.log`) contains per-worker syscall traces
when `?debuglog` is in the URL.

**Key log patterns:**

```
[HH:MM:SS.mmm] [W:sh (PID)] compile buf=N size=BINARY_SIZE
[HH:MM:SS.mmm] [W:sh (PID)] compile OK size=BINARY_SIZE
[HH:MM:SS.mmm] [W:sh (PID)] instantiate fresh_memory=0|1
[HH:MM:SS.mmm] [W:sh (PID)] call() error: Error: ...    ← crash!
[HH:MM:SS.mmm] [W:sh (PID)] sc nr=NNN a0=V a1=V a2=V   ← syscall entry
[HH:MM:SS.mmm] [W:sh (PID)] sc nr=NNN ret=V             ← syscall return
```

- `fresh_memory=1` → kernel allocated fresh memory for this binary (correct for `--import-memory` binaries)
- `fresh_memory=0` → reusing a cached memory slab (can be correct or a sign of missing `--import-memory`)
- `size=N` is the binary fingerprint — use it to identify which binary is running
- A syscall with no `ret=` line after it means the worker is **blocked** there

**Common trace patterns:**
```
sc nr=202 a0=3               → accept(fd=3) blocking, waiting for connection
sc nr=64 a0=4 a1=BUF a2=52 ret=52  → write(fd=4, ..., 52) = 52, SSH banner sent!
sc nr=94 a0=3                → exit_group(3), process exiting
sc nr=221 ret=-2             → execve() → ENOENT (expected for shell startup)
```

**Typical debug workflow:**
```sh
# Follow a specific process
grep "W:sh (46)" /tmp/wasm-kernel-debug.log | tail -50

# Find crashes
grep "call() error" /tmp/wasm-kernel-debug.log

# Find accept() calls
grep "sc nr=202" /tmp/wasm-kernel-debug.log

# Find SSH banner writes (write of ~52 bytes to the accepted fd)
grep "sc nr=64.*a2=52" /tmp/wasm-kernel-debug.log

# Find tunnel events
grep "jtn\|INJECT\|\[TCP22\]" /tmp/wasm-kernel-debug.log | tail -30
```

---

## Networking: WispSlirp + JS Tunnel

`wasm.html` implements a browser-side TCP/IP stack (`WispSlirp` class) that:
1. Forwards outbound guest TCP via WISP v1 WebSocket to `linuxontab-net.fly.dev`
2. Forwards DNS via DoH to `relay.linuxontab.com/dns-query`
3. Injects **inbound** TCP connections via `injectConnect(port, ws)` for the JS tunnel

**Network topology inside the guest:**
```
eth0: 192.168.86.100/24
GW:   192.168.86.1       ← WispSlirp virtual gateway
DNS:  192.168.86.1       ← DoH relay (also hardcoded /etc/hosts for Fly services)
```

**`backend` object** (bridge between WispSlirp and kernel NetworkDevice):
```js
slirp.backend = {
  send:    frame => slirp.#onGuestFrame(frame),  // guest → slirp
  receive: null,   // set by NetworkDevice constructor: slirp → guest
};
```
After boot, `backend.receive` is set. Call `backend.receive(ethFrame)` to inject
any Ethernet frame into the guest's NIC.

**`injectConnect(guestPort, relayWs)`** — injects an inbound TCP connection:
1. Creates a fake `10.0.2.100:remotePort → 192.168.86.100:guestPort` connection
2. Sends SYN via `backend.receive` → kernel's TCP stack → wakes `accept()` in guest
3. Guest sends SSH banner → `#handleTcp` captures it → `relayWs.send(banner)`
4. `guestSentFirst` flag set → client data from relay WS now flows to guest

**`#serverConns` key**: `'guestPort:remotePort'` (e.g. `'22:25000'`)

---

## Clang in WASM — Current State

**`clang -cc1` working as of 2026-05-25.** E2E tested via Playwright:
```sh
clang -cc1 -triple wasm32-unknown-unknown -emit-obj -o /tmp/t.o /tmp/t.c
# → exits 0 ✓
```

**Binary:** `rootfs/usr/local/bin/clang` — 42,658,027 bytes, asyncified, `--import-memory`. Listed in `WASM_OPT_SKIP`.

**Three bugs fixed to get here:**
1. **sigaltstack (syscall 132)**: Added shim in `shell/linux-dist/dist/worker.js` — the WASM kernel doesn't support this syscall; shim returns 0 silently.
2. **LLD vtable null entries**: wasm-ld had null table entries causing "table index out of bounds".
3. **call_indirect type mismatch** (root cause of SIGSEGV): `fn[36786]` in clang had `call_indirect type=0` (i32,i32→void) but the virtual function at `table[5047] = fn[10126]` is `type=2` (i32,i32→i32). LLVM WASM codegen emitted wrong type for a C++ member function pointer dispatch.

### BUG 3 Fix Details — call_indirect type mismatch

**Location:** `fn[36786]` (type[4]=(i32,i32,i32)→void), body offset `fn_data[1626..1655]`, file offset `0x16e1834`.

**Root cause:** Virtual dispatch via C++ member function pointer. `fn_ptr=20189` (odd → virtual), `vtable_byte_offset=20188`, `vtable_slot=5047`. `table[5047] = fn[10126]` with `type[2]=(i32,i32)→i32`. But `call_indirect type=0=(i32,i32)→void` was encoded → runtime type mismatch trap.

**Fix:** 30-byte in-place patch at `0x16e1834` replacing:
```
; Original (30 bytes):
local.get 2; i32.const 1; i32.and       ; condition: fn_ptr & 1
if -1                                    ; if virtual:
  local.get 0; load+0; local.get 2       ;   vtable_ptr + fn_ptr
  i32.add; i32.const 1; i32.sub; load+0  ;   - 1 → table_idx
else; local.get 2; end                   ; else: fn_ptr directly
call_indirect type=0 table=0             ; ← CRASH: type mismatch
br 1                                     ; exit block -64
```
With:
```
; Patched (30 bytes, same size — select replaces if-else, saves 3B for drop+type fix):
local.get 0; load+0                     ; vtable_ptr = *adj_this
local.get 2; i32.add; i32.const 1; i32.sub; load+0  ; v1: vtable_tbl_idx
local.get 2                             ; v2: fn_ptr (direct)
local.get 2; i32.const 1; i32.and       ; condition
select                                  ; picks v1 if virtual, v2 if direct
call_indirect type=2 table=0            ; ✓ matches (i32,i32)→i32
drop                                    ; discard return value
br 1                                    ; exit block -64 (NOT return — cleanup follows)
nop; nop                                ; filler (2 bytes)
```

**Why `br 1` not `return`:** After `block -64` ends at `fn_data[3642]`, the function runs shadow stack cleanup: `local.get 3; i32.const 688; i32.add; global.set 0` (restores `__stack_pointer`). Skipping this with `return` would leak the 688-byte shadow stack frame. `br 1` exits `block -64` and falls through to cleanup.

**Patch bytes** at `0x16e1834` (30 bytes):
```
20 00 28 02 00 20 02 6A 41 01 6B 28 02 00  (vtable select: v1)
20 02 20 02 41 01 71 1B                    (fn_ptr direct + condition + select)
11 02 00 1A 0C 01 01 01                    (call_indirect type=2, drop, br 1, nop, nop)
```

**DO NOT re-asyncify `rootfs/usr/local/bin/clang`** — it is already asyncified and in `WASM_OPT_SKIP`. Re-asyncifying would corrupt the binary.

---

## Milestone Roadmap — In-Browser Self-Hosting

Goal: **write C code in the browser → compile → run**, entirely inside the WASM kernel.

### Status
| Capability | Status | Notes |
|---|---|---|
| Boot kernel | ✅ | ~20s cold boot |
| SSH (password auth) | ✅ | via JS tunnel |
| SFTP | ✅ | |
| BusyBox userland | ✅ | vi, sh, cat, etc. |
| `clang -cc1` | ✅ | emit-obj, exits 0 |
| `clang` full driver | ❓ | needs execve of cc1 subprocess — untested |
| `wasm-ld` | ❓ | binary present; full link untested |
| C headers/sysroot in guest | ✅ | `/nix/store/lot-musl-sysroot` in rootfs (fixed libc.a/libc.so as of July 2026) |
| Compile+link end-to-end | ❓ | headers + driver + ld all present; pipeline untested |
| Run compiled WASM binary | ❌ | needs asyncify inside guest (or pre-asyncified output) |
| nodejs (qjs-based) | ✅ | `qjs` + `node`/`npm` wrapper scripts; verified in guest |
| Python | ✅ | CPython 3.11.9 boots and runs (July 2026, post-mallocng fix) |

### Next Steps (in order)
1. **Test full clang driver** inside guest: `clang -target wasm32-unknown-unknown -c test.c -o test.o` — this execs cc1 as a subprocess; if execve works it should succeed.
2. **Test wasm-ld** inside guest: `wasm-ld test.o -o test.wasm` — already in rootfs.
3. **Full pipeline**: `clang -cc1 ... -emit-obj` → `wasm-ld` → asyncify (wasm-opt is in rootfs) → run.
4. **Rebuild remaining buggy-libc binaries** (see Rule 5): dropbear/sshd family, wasm3 (needs its socket-extension sources recovered), xkbcomp, in-guest clang/wasm-ld/wasm-opt via `local/build-wasm-toolchain.sh`.

---

## OpenSSH in WASM — Current State

**Working as of 2026-05-24.** SSH password auth end-to-end tested:
```sh
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@localhost 'echo SSH_OK'
# → SSH_OK ✓
```

**How it works:**
- `etc/rc` starts `sshd-session` in a `while true` loop (one connection per instance)
- `sshd-session` binds port 22, calls `accept()`, handles one SSH session, exits
- The loop restarts it immediately for the next connection
- The JS tunnel auto-starts on `?autoboot` (registered as tunnel code, 3 guest WS in pool)

**Binary locations:**
```
rootfs/usr/local/libexec/sshd-session   1,597,675 bytes, asyncified, imports memory
rootfs/usr/local/libexec/sftp-server      242,287 bytes, asyncified
```

**sshd_config:**
```
Port 22
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin yes
PasswordAuthentication yes
LogLevel VERBOSE
Subsystem sftp /usr/local/libexec/sftp-server
```
Root password: `linuxontab` (only the first 8 chars, `linuxont`, are
significant — see below).

> **crypt scheme caveat:** this build's wasm musl `crypt()` supports ONLY
> traditional DES crypt (13-char hashes, no `$` prefix). MD5 (`$1$`), SHA-256
> (`$5$`), and SHA-512 (`$6$`) hashes in `/etc/shadow` can NOT be verified and
> will silently fail every password auth. The old documented password used a
> `$1$` MD5 hash and never actually worked over SSH. `/etc/shadow` now holds a
> DES hash (`root:LtnqhKg6ZIrh6:...`). DES only uses the first 8 password
> chars, so `linuxont` + any suffix authenticates. Regenerate with
> `openssl passwd -crypt -salt XX <pw>` — must match what the guest's own
> `chpasswd`/`passwd` produces.

**To SSH into the running guest:**
```sh
# Start tunnel listener (after browser boots and tunnel is registered)
sh ~/.ai/LinuxOnTab/local/tunnel-listen.sh CODE 2222 22
# CODE is printed in the wasm.html side panel, or check jtn log:
grep "registered code" /tmp/wasm-kernel-debug.log | tail -1

ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost
```

---

## Rootfs Build

```sh
# Full rebuild (runs wasm-opt --asyncify on all WASM binaries, then mke2fs):
./build-rootfs.sh

# Requires:
#   brew install e2fsprogs binaryen
#   WASM_OPT=/opt/homebrew/bin/wasm-opt (default)

# After rebuild:
git add rootfs/ shell/linux-dist/rootfs.ext4
git commit -m "rootfs: <description>"
```

`build-rootfs.sh` skips asyncify for files in `WASM_OPT_SKIP` (binaries already
asyncified as part of their build, like `sshd-session`). Add new pre-asyncified
binaries to that list.

**Adding a new WASM binary:**
1. Build it with `--import-memory` (see toolchain above)
2. Asyncify it: `wasm-opt --asyncify -O1 binary -o binary.asyncified`
3. Copy to `rootfs/` under appropriate path
4. Add the path to `WASM_OPT_SKIP` in `build-rootfs.sh`
5. `./build-rootfs.sh && git add -A && git commit`

---

## Package System

The WASM guest has a custom `apk` package manager (`rootfs/usr/bin/apk`) that
installs WASM-native binaries without network access to real Alpine repos
(Alpine packages are ELF — incompatible with the WASM kernel).

### How it works

```
rootfs/packages/          ← packages baked into the ext4 image (served via virtual GW)
  index.json              ← package index consumed by apk (path: /packages/index.json)
  busybox-1.37.0.tar.gz
  sqlite3-3.51.0.tar.gz
  dropbear-2024.86.tar.gz
packages/                 ← repo-root copy for GitHub Pages (linuxontab.com/packages/)
  index.json              ← SEPARATE index (different SHA256s — different build)
  make-packages.sh        ← extracts Nix build results → .tar.gz + index fragments
```

**Package URL resolution order** (inside guest):
1. Local copy at `/packages/<tarname>` — instant, no network
2. `http://192.168.86.1/packages/<tarname>` — virtual gateway (fast)
3. `https://linuxontab.com/packages/<tarname>` — GitHub Pages (slow)

**In-guest `apk` commands:**
```sh
apk list              # show all packages (installed status)
apk add sqlite3       # install a package
apk del sqlite3       # remove a package
apk upgrade           # upgrade all installed packages
apk info sqlite3      # show package metadata
apk update            # no-op (index is baked in, no network fetch needed)
```

### Adding a package (Mac workflow)

**Preferred: recipe-based build.** Write `packages/recipes/NAME.sh` (see
existing recipes) and run `./packages/build-package.sh NAME` — it uses the
fixed sysroot, checks for the mallocng 0x8000 pattern, asyncifies, packs the
tarball, and updates both index.json files automatically. Add `--no-asyncify`
if the recipe asyncifies internally (e.g. x11vnc). The manual flow below is
legacy (used for tombl/distro Nix outputs like busybox/sqlite3/dropbear):

1. Build the WASM binary with Nix or the clang toolchain (see Build Toolchain above)
2. Create a `pkg-NAME/` dir structure under `/tmp/wasm-pkgs/`:
   ```
   /tmp/wasm-pkgs/NAME-result/bin/NAME   ← the asyncified WASM binary
   ```
3. Run `./packages/make-packages.sh /tmp/wasm-pkgs ./packages`
   → creates `packages/NAME-VERSION.tar.gz` + updates `.index-fragments.txt`
4. Manually merge `.index-fragments.txt` into both `packages/index.json`
   (GitHub Pages copy) AND `rootfs/packages/index.json` (baked rootfs copy)
5. Copy the new tarball into `rootfs/packages/`
6. Run `./build-rootfs.sh`
7. `git add -A && git commit`

### Package tar.gz format

Packages are standard `.tar.gz` with this layout:
```
pkg-NAME/
  bin/NAME          ← WASM binary (pre-asyncified at pack time)
  info              ← name=, version=, built_with=, target= fields
```
`apk` extracts to `/` so `bin/NAME` installs to `/bin/NAME`. Use subdirs for
non-standard paths (e.g. `sbin/dropbear` → `/sbin/dropbear`).

### Asyncify fork-depth limit — CRITICAL

The WASM kernel limits asyncify to a **maximum fork depth of ~3** (current
process spawns child → child spawns grandchild → hard limit). Shell scripts
that use `$()` command substitution, pipes, or subshells add fork depth.

**The `apk` script is carefully written to avoid `$()` at depth 3.**
If you add shell scripts that run inside the guest and call subprocesses,
keep the fork chain shallow. Symptoms of exceeding the limit:
- Script silently hangs with no output
- Process never exits
- `grep`, `sed`, `awk`, `sha256sum` hang when called inside `$()` inside a
  function that is itself called via a `$()` substitution

**Safe patterns inside the guest:**
```sh
# GOOD: redirect capture (no extra fork)
command > /tmp/out && IFS= read -r result < /tmp/out

# BAD at depth ≥ 3: $() spawns a subshell
result=$(command)
```

---

## Installing Packages Directly to a Running Guest

The rootfs.ext4 is writable during a session (changes persist until page reload).
You can install new WASM binaries **without rebuilding rootfs.ext4** by SCP-ing
directly to the running guest via the tunnel.

### Quick install (single binary, session-only)

```sh
# On Mac: build + asyncify the binary (see toolchain above), then:
sh ~/.ai/LinuxOnTab/local/tunnel-listen.sh CODE 2222 22
scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    /path/to/binary.wasm root@localhost:/usr/local/bin/mybinary
# In guest: chmod +x /usr/local/bin/mybinary && mybinary
```

### Full package install (registers with apk, session-only)

```sh
# Mac: build package tarball
./packages/make-packages.sh /tmp/wasm-pkgs ./packages

# Push tarball to running guest's local package cache
sh ~/.ai/LinuxOnTab/local/tunnel-listen.sh CODE 2222 22
scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    packages/NAME-VERSION.tar.gz root@localhost:/packages/

# Push updated index.json to guest
scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    rootfs/packages/index.json root@localhost:/packages/

# In guest: install it
apk add NAME
```

### Making it persistent (survives page reload)

To survive reload, the files must be in the ext4 image baked into rootfs.ext4:
```sh
cp packages/NAME-VERSION.tar.gz rootfs/packages/
# Update rootfs/packages/index.json with new package entry
./build-rootfs.sh
git add -A && git commit -m "packages: add NAME"
```

---

## Services (same as LinuxOnTab main branch)

- `services/relay/` → CF Worker `relay.linuxontab.com` (DoH, CORS proxy)
- `services/relay-tunnel/` → CF Worker `tunnel.linuxontab.com` (TCP-over-WS tunnels)
- `services/wisp-backend/fly.toml` → Fly app `linuxontab-net` (WISP v1 server)

Deploy commands:
```sh
cd services/relay-tunnel && npm i && npx wrangler deploy
cd services/relay        && npm i && npx wrangler deploy

fly deploy -a linuxontab-net -c services/wisp-backend/fly.toml --ha=false --remote-only
```

---

## Known Hard-Won Lessons

### WASM binary crashes

1. **OOB memory crash after asyncify**: Binary has own memory section → fix with `--import-memory`.
   Symptom: `Error: memory access out of bounds` or `Error: Invalid function table` in kernel log.

2. **`execv` fails silently**: Any `execv(self)` pattern in a daemon causes ENOENT.
   Symptom: process starts, does nothing, exits. Fix: standalone-mode patch to skip re-exec.

3. **Privilege separation fork hangs**: `fork()` in WASM forks a new worker but the
   monitor/child communication via socketpair may deadlock. Fix: patch to bypass privsep.

4. **Stack overflow in deeply recursive code**: WASM default stack is smaller than
   Linux native. Add `-z stacksize=N` to linker flags if needed.

5. **`call_indirect` type mismatch**: LLVM WASM codegen sometimes emits the wrong type
   index for a virtual dispatch (e.g. C++ member-function-pointer `call_indirect`).
   Symptom: `RuntimeError: function signature mismatch` or exit 139 (SIGSEGV).
   Diagnosis: find the crashing fn via debug log + `wasm-objdump --disassemble`, compare
   the `call_indirect type=N` index against `table[slot]`'s actual type.
   Fix: in-place binary patch to change `type=N` to the correct type; if return type
   differs (void→i32), add `drop` and adjust surrounding code with `select` if needed
   to stay within the same byte budget. Use `br N` (not `return`) to ensure shadow
   stack cleanup runs after the patched block.

### Network (same lessons as v86 branch)

5. **Fly WISP drops UDP/53**: Always use unbound with `forward-tcp-upstream: yes`
   for DNS inside the guest. Or use hardcoded `/etc/hosts` entries.

6. **`backend.receive` must be set before injecting**: Check `!!slirp.backend.receive`
   before calling `injectConnect`. It's set by `NetworkDevice` constructor at boot.

7. **`injectConnect` SYN vs pending data race**: The code buffers relay data until
   `guestSentFirst` is true (SSH banner received from guest). Don't remove this —
   sshd sends banner immediately on accept; client data before that would be lost.

---

## AGENT RULES

- Always run `./build-rootfs.sh` after modifying any file under `rootfs/`.
- Always commit with `git add -A` (rootfs.ext4 is large but tracked directly, NOT LFS).
- After modifying `shell/wasm.html`, no build step — just hard-refresh the browser.
- Do NOT re-asyncify `sshd-session`, `sftp-server`, or `usr/local/bin/clang` via `build-rootfs.sh` — they are
  already asyncified and listed in `WASM_OPT_SKIP`. Re-asyncifying would corrupt them.
  `clang` has a critical in-place binary patch at `0x16e1834` that asyncify would destroy.
- When rebuilding a WASM binary from source, always verify `--import-memory` with
  `wasm-objdump -x binary.wasm | grep -i memory` before installing to rootfs.
- The dev server (`serve.sh`) must be running at port 8765 for `wasm.html` to work.
  `file://` URLs block SharedArrayBuffer (required for WASM kernel).
- Debug log is at `/tmp/wasm-kernel-debug.log`. It grows large — tail it, don't cat.
- Never modify `shell/linux-dist/vmlinux.wasm` or `shell/linux-dist/initramfs.cpio`
  unless explicitly working on the kernel itself. These come from `@tombl/linux`.
- The branch is `feature/linux-kernel-integration`. Do not merge to main without
  explicit instruction.
- After services changes, deploy the CF Workers (relay-tunnel, relay) via wrangler.
  Never auto-push to GitHub without confirmation.
