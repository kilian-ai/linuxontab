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
- `lot_sigaction.c`: on 7.1 runtimes before 6e583e7, SA_SIGINFO handlers in
  pre-7.1-musl binaries killed the process ("Invalid siginfo trampoline").
  Wraps sigaction to install them as plain handlers through a thunk. Kept so
  the spike also runs on older runtimes; 6e583e7 fixed it in the worker.

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
6e583e7 together with the SA_SIGINFO compat, which also makes lot_sigaction.c
unnecessary on that runtime; it is kept so older runtimes still work).

Verified (threaded build, `spawntest.c`, `forkthreads.c`): libuv's vfork
probe sees the child's write; posix_spawn with a dup2 into a pipe of a WASM
program and of an x86 program, from a process with running threads; fork+exec
of `/bin/echo` x3 with three spinning threads; clean process exit afterwards.
Full regression on both builds: static + dynamic x86 hello, busybox pipes and
`$(...)`, thread stress x3.

## Not done / next

- Node itself: Alpine x86_64 nodejs + its shared libs in the x86 root
- speed: a wasm32 "offset-linear" memory mode, asyncify only the syscall path,
  then a block JIT that compiles hot x86 code to wasm modules
- packaging: blink as an apk package + binfmt registration in /etc/rc + an
  x86 Alpine root; kernel defconfig change must be pushed to the public fork
  and shipped with kernels/deploy-vmlinux.sh
