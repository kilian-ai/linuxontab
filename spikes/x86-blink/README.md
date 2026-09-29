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

- `lot_mman.h` / `lot_mmap.c`: the sysroot has no mmap. On a 32-bit host Blink
  runs "nolinear" (software page tables), so it only needs zeroed anonymous
  chunks and private read-only file images. Both come from malloc; munmap
  frees only bases it handed out.
- `lot_sbrk.c`: **platform bug** — the sysroot musl `_brk` grows wasm memory
  4x faster than the heap (16 KiB vs 64 KiB page units), so every dlmalloc port
  tops out at ~54 MB. `toolchain/patches/musl-brk-wasm-page-units.patch` fixes
  it but was never built into `toolchain/musl-sysroot-fixed` (only python3
  byte-patches it). With this shim: 243 MB.
- `lot_sigaction.c`: **platform bug** — on the 7.1 kernel, SA_SIGINFO handlers
  in pre-7.1-musl binaries kill the process ("Invalid siginfo trampoline": the
  kernel calls sa_restorer as a 2-arg trampoline, old musl never sets one).
  Wraps sigaction to install them as plain handlers through a thunk.

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

Three more platform problems, each fixed spike-locally:
- `lot_dlmalloc_mt.c`: musl's *internal* allocations (`__libc_malloc`:
  pthread_create's stack + TLS) go to mallocng, whose large-block path needs
  mmap and traps; every guest clone() died. Routed to a locked dlmalloc.
- `lot_fork.c`: the fork child is a fresh instance rewound into fork();
  asyncify restores locals, not globals, so it came back with
  `__stack_pointer` at the stack top (the worker restores it only when the
  module exports it — none do) and `__tls_base` = 0. The child now writes
  both back from locals right after the fork syscall.
- `lot_clone.c`: no one calls `__wasm_init_tls` for new threads, so all
  threads of every threaded wasm program share one TLS block (native probe
  `tlsprobe`: 3 of 4 threads saw another thread's value). `__clone` now
  gives each thread its own block.

**Open: fork in a process that already has threads.** The 7.1 kernel
refuses a memory-copying clone while another thread shares the mm
(`-EOPNOTSUPP`, arch/wasm/kernel/fork.c: the copy can't be made coherent
while other workers run). Blink maps guest fork, vfork and
`clone(CLONE_VM|CLONE_VFORK)` all to a host copying fork, and the worker
turns CLONE_VM|CLONE_VFORK into a copy for every asyncify module, so a
threaded guest cannot spawn children (`forkthreads.c` fails). This is what
Node's child_process needs (libuv: posix_spawn via CLONE_VM vfork, else fork).

## Not done / next

- fork/spawn from a threaded guest (above)
- speed: a wasm32 "offset-linear" memory mode, asyncify only the syscall path,
  then a block JIT that compiles hot x86 code to wasm modules
- packaging: blink as an apk package + binfmt registration in /etc/rc + an
  x86 Alpine root; kernel defconfig change must be pushed to the public fork
  and shipped with kernels/deploy-vmlinux.sh
