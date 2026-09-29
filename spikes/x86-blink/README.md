# Spike: transparent x86-64 emulation in the wasm guest

Goal: run x86-64 Linux binaries (things we cannot compile to wasm) inside the
guest, launched like native programs. Result (2026-09-29): works.

## How it fits together

- **Blink** (github.com/jart/blink @ f006a4f, ISC): an x86-64 Linux *user-mode*
  emulator in portable C. Built as an ordinary wasm guest binary by `build.sh`.
  Guest syscalls become host (our kernel's) syscalls, so emulated processes
  share the filesystem, pipes, sockets and job control with native ones.
- **binfmt_misc** (kernel `CONFIG_BINFMT_MISC=y`, not yet in the shipped
  defconfig): any file starting with the x86-64 ELF header execs through Blink.
- **x86 userland**: Alpine x86_64 packages. Dynamic binaries find their loader
  and libraries in an isolated root via `BLINK_OVERLAYS=/opt/x86/root:`.

Register (after mounting binfmt_misc):

    mount -t binfmt_misc none /proc/sys/fs/binfmt_misc
    printf '%s' ':x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/opt/x86/blink:' > /proc/sys/fs/binfmt_misc/register

## Verified in the guest (kernel 7.1 + binfmt_misc, lean image)

- static x86-64 C program: argv, `uname` → x86_64, 64 MB heap, clean exit
- `./x86/hello` runs directly (binfmt_misc → Blink)
- unmodified Alpine `busybox.static` 1.36.1: uname, ls, sha256sum, its `sh`
  with arithmetic, loops, pipelines, `$(...)`, fork
- mixed chains both ways: x86 sh → x86 hello → wasm `head`;
  wasm `sha256sum` → x86 `cut`; an x86 shell running `uname` gets the wasm one
- dynamically linked x86-64 program via Alpine's `ld-musl-x86_64.so.1`

## Shims (why each exists)

Spike-local:
- `lot_mman.h` / `lot_mmap.c`: the sysroot has no mmap. On a 32-bit host Blink
  runs "nolinear" (software page tables), so it only needs zeroed anonymous
  chunks and private read-only file images. Both come from malloc; munmap
  frees only bases it handed out.
- (removed) `lot_sigaction.c`: SA_SIGINFO compat now lives in the 7.1 worker
  (6e583e7); the wrapper's global table broke SIGCHLD with vfork children.

From the sysroot (bugs this spike found, fixed there for every port):
- brk grew wasm memory 4x faster than the heap, capping dlmalloc heaps at
  ~54 MB (3c5a41c; now 243 MB)
- `wasm_dlmalloc.c` / `wasm_dlmalloc_mt.c`: musl's internal `__libc_malloc`
  (pthread_create's stack + TLS) went to mallocng, whose large-block path
  traps without mmap; `_mt` adds locking for threaded ports (1ac3cfd)
- `wasm_fork.c`: the fork child now restores `__stack_pointer` and
  `__tls_base` (1ac3cfd)
- `wasm_clone.c`: per-thread TLS for CLONE_SETTLS clones, a fresh TLS block
  for CLONE_VFORK children with their own stack (Blink's vfork child runs an
  emulator there), and the `__lot_clone_sets_sp` marker (1ac3cfd)

## Performance (primes < 200000, same C source)

| build                         | time    | vs native wasm (0.007 s) |
|-------------------------------|---------|--------------------------|
| Blink rel, asyncify -O3       | 1.64 s  | ~235x                    |
| Blink rel, no asyncify        | 1.15 s  | ~165x                    |

Asyncify (needed for fork) costs ~40-50 %. The rest is nolinear mode: every
guest memory access walks a software TLB/page table.

## Threads (`THREADS=1 sh build.sh`)

Guest `clone(CLONE_THREAD)` runs each guest thread on a host pthread.
Verified: 4 threads x 20000 atomic + mutex increments exact, condvar
ping-pong 2000 rounds (~46 us/handoff), per-thread guest TLS (%fs), a
sleeping thread's join value; fork + pipes + `$(...)` still work.
Test programs: `threads.c`, `forkthreads.c`.

Three more platform problems surfaced here (internal allocator, fork-child
globals, no per-thread TLS; native probe `tlsprobe`: 3 of 4 threads saw
another thread's value). They were fixed spike-locally first and now live in
the sysroot (1ac3cfd), listed under Shims above.

### Spawning children from a threaded guest (`LOT_VFORK`, blink-lot.patch)

The 7.1 kernel refuses a memory-copying clone while another thread shares the
address space (`-EOPNOTSUPP`, arch/wasm/kernel/fork.c: the snapshot can't be
coherent while other workers run), and stock Blink maps guest fork, vfork and
`clone(CLONE_VM|CLONE_VFORK)` all to a host copying fork. Node's
child_process needs this (libuv: posix_spawn when a vfork probe shows shared
memory, else fork()).

With `LOT_VFORK`, a guest vfork/posix_spawn clone runs as a host
`clone(CLONE_VM|CLONE_VFORK)`: a real process (own pid, own host fd table)
sharing memory, with the caller blocked until the child execs or exits. The
child gets its own copy of Blink's `System` (guest fd table, pid, signal
table), sharing only the guest page tables, and its own `Machine`. Details:
- plain `fork()` in a threaded guest takes the same path; its child resumes on
  the parent's x86 stack, so the stack window is snapshotted and restored
  before the parent resumes (the parent never sees the child's writes there)
- Blink runs x86 execve in-process (wipes and reloads guest memory); a vfork
  child instead host-execs Blink itself (`blink -0 PROG ARGV0 ...`)
- a vfork child unpins the guest pages its syscall pinned (PAGE_LOCKS in the
  shared page tables) before execve/exit and wakes the parent's waiters, or
  the parent hangs in FreePage() at exit
- guest threads get 1 MB host stacks (the same patch)

**Needs the worker to keep `CLONE_VM`:** worker.ts turns `CLONE_VM|CLONE_VFORK`
into a copy for every asyncify module (old musl __clone left the child on
the parent's stack). It now skips that for modules exporting
`__lot_clone_sets_sp`, which sysroot/wasm_clone.c does (worker.ts change committed in
6e583e7 together with the SA_SIGINFO compat).

Verified (threaded build, `spawntest.c`, `forkthreads.c`): libuv's vfork
probe sees the child's write; posix_spawn with a dup2 into a pipe of a WASM
program and of an x86 program, from a process with running threads; fork+exec
of `/bin/echo` x3 with three spinning threads; clean process exit afterwards.
Full regression on both builds: static + dynamic x86 hello, busybox pipes and
`$(...)`, thread stress x3.

## Node.js (x86_64 Alpine build, under threaded Blink)

**Real Node.js v20.15.1 runs in the guest** (Alpine 3.20 `nodejs` + 13 shared
libs, 59 MB, in an isolated root via `BLINK_OVERLAYS`; `fetch-node-root.py
v3.20 <dir>` resolves and unpacks it). `node --jitless` is required (no JIT
under emulation; V8 prints "disabling flag --expose_wasm", which is normal).
`node --version` takes ~2 s, a one-line script ~8 s.

`nodetest.js` in the guest: node/V8/uv versions, os, fs on guest files, crypto,
zlib, JSON/regex/Intl, `execSync` of a WASM program, timers + promises and a
TCP server + client all PASS. The last check, async `child_process.exec`,
hangs or crashes (see below). Under native Linux Blink (Docker) the whole
file passes 11/11 in ~10 s.

What it took (all in blink-lot.patch, behind `LOT_SYSCALLS`):
- **`pop [rsp+X]` bug in Blink's CPU** (`OpPopEvq`): the destination address
  must use rsp AFTER the pop, but C leaves argument evaluation order
  unspecified and clang/gcc computed it first, writing 8 bytes too low. In
  V8's runtime C++ this clobbered a return address and V8 jumped into its
  heap. This is why Node never ran under Blink upstream (jart/blink#87). Found
  with an instruction ring buffer + a stack-slot watchpoint in a native build.
- `eventfd`/`eventfd2` (libuv's loop needs it on Linux; no pipe fallback)
- `mremap` reports EFAULT for unmapped ranges (musl's pthread_getattr_np walks
  the main stack with mremap until EFAULT; ENOMEM for everything looped forever)
- process-wide signals go to a guest thread that doesn't block them (Node's
  workers block everything; SIGCHLD sat pending on one of them)
- the SA_SIGINFO wrapper (lot_sigaction.c) is gone: its global handler table
  was clobbered by vfork children resetting their handlers before exec, so
  the parent lost SIGCHLD. Needs a runtime with 6e583e7.

Later fixes (2026-09-29):
- **copy-on-write stack window for fork in a threaded guest**: the child gets
  its own page-table root and private copies of the committed pages in
  [rsp-128, +256 KiB), copying each intermediate table once; everything else
  stays shared (vfork). Replaces the snapshot + restore, which also discarded
  writes the parent's other threads made to that window.
- **g_hostpages race**: nolinear Blink appended to its host-page index array
  without a lock, so two threads could get the same index (two guest pages on
  one host page). Serialized now; the array starts at 1M entries so realloc
  (which readers still race with) almost never moves it.
- **memory cap**: Node under Blink needs more than the worker's 256 MiB per
  process ("blink: host out of memory (wasm32 heap full)" is now printed; a
  failed page allocation otherwise shows up as a random guest SIGSEGV). Blink
  declares 1 GiB and exports `__lot_big_memory`; worker.ts keeps the declared
  maximum for modules with that export (other C programs stay at 256 MiB).

Result: `nodetest.js` passes **11/11 in the guest** (release: 3.7 s of JS
time, async child_process included; the debug build too). Still open: an
intermittent crash at the TCP step in the release build (1 of 2 runs): a guest
access to unmapped memory, after which Blink hits `unassert(m->canhalt)` in
HaltMachine (release builds turn that into a wasm `unreachable`). The debug
build hasn't shown it, so it looks timing-dependent. Separately, the guest's
hush does not reap a background job whose Blink process died (stays Z).

## Not done / next

- Node: the intermittent release-build crash (above), then a `node`
  wrapper/package (always `--jitless`, BLINK_OVERLAYS, binfmt)
- speed: a wasm32 "offset-linear" memory mode, asyncify only the syscall path,
  then a block JIT that compiles hot x86 code to wasm modules
- packaging: blink as an apk package + binfmt registration in /etc/rc + an
  x86 Alpine root; kernel defconfig change must be pushed to the public fork
  and shipped with kernels/deploy-vmlinux.sh
