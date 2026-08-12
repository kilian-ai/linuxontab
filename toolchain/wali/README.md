# WALI bridge — running Rust (and any wali-musl program) on the LinuxOnTab guest

Goal: make the guest speak **WALI** (WebAssembly Linux Interface) so Rust's
`wasm32-wali-linux-musl` target — and any wali-musl binary — runs on this
tombl guest. Vehicle for building `trust` and future Rust tooling.

## Status: Rust RUNS on the guest, blocked on a syscall-ABI compat layer

A Rust binary built for `wasm32-wali-linux-musl` now **instantiates and
executes** on the guest (via the bridge in `shell/linux-dist/dist/worker.js`),
reaches its startup, and makes syscalls through the bridge. It does not yet
complete because WALI targets the **x86-64 Linux ABI** while this guest kernel
is **32-bit asm-generic** — so a compatibility layer is needed (below).

### What works (this session)
- **Rust std compiles** for the target (nightly + `-Zbuild-std`).
- **wali-musl built**: `build-wali-musl.sh` fetches LLVM 22.1.3 (the only clang
  with the `wasm32-linux-muslwali` LP64 triple; our clang-19/21 lack it),
  builds wali-musl → sysroot (`libc.a` + `crt1-command.o`). Rust links clean
  against it (no ABI warnings — LP64 matches).
- **Bridge wired into worker.js** (`makeWaliImports_INLINE`): provides the
  `wali` import module (149 `SYS_*` + `__cl_*` argv + `__init/__deinit/
  __proc_exit/__get_init_envfile` lifecycle hooks) and `env._Unwind_*` stubs.
  All imports resolve; the module runs.
- Syscall-number translation **x86-64 → asm-generic** (write 1→64, openat
  257→56, set_tid_address 218→96, …) plus **legacy→modern rewrites**
  (`open`→`openat`, `stat`→`fstatat`, `dup2`→`dup3`, `mkdir`→`mkdirat`, …).

### What remains (the compat layer — next session)
The guest kernel is x86-64-ABI-incompatible in three more ways:
1. **Memory syscalls are host-side.** Our kernel has NO `mmap`/`munmap`/`brk`
   syscall — our C musl implements mmap via wasm `memory.grow` (worker.js:126).
   wali-musl calls `SYS_mmap` as a syscall, so the bridge must implement
   mmap/munmap/mremap/brk in JS via `memory.grow` (WALI-style host mmap).
   Currently these return `-ENOSYS` (the immediate blocker after signal setup).
2. **LP64↔LP32 struct layout.** WALI structs (`stat`, `timespec`, `pollfd`…)
   are 64-bit-long layout; our kernel fills 32-bit-long layout. The bridge must
   translate the buffers for stat/fstat/nanosleep/poll/etc.
3. **Real argv.** `__cl_*` is stubbed to `argv[0]="rgtest"`; bridge it to the
   guest's `linux.get_args`.

### Files
- `build-wali-musl.sh` — reproduce the wali-musl sysroot (fetches LLVM 22).
- `wali-imports-inline.js` — the exact bridge injected into worker.js.
- `gen-wali-imports.py`, `wali-imports.js` — module-form generator/output.
- `our-syscall-numbers.json` — the guest kernel's asm-generic number map.
- `cargo-config.reference.toml` — Rust link config against the wali sysroot.
- `syscall-table.json` — WALI (x86-64) syscall table from the libc crate.

### Build a Rust binary for the guest (once sysroot exists)
```
./toolchain/wali/build-wali-musl.sh                # -> /tmp/wali-sysroot
cd yourcrate && cargo +nightly build --release --target wasm32-wali-linux-musl \
  # with cargo-config.reference.toml pointing -L at /tmp/wali-sysroot/lib
wasm-opt --asyncify -O2 target/.../bin.wasm -o bin.wasm   # then install in guest
```
Milestone: a Rust hello-world printing on the guest. Then `trust`
(crossterm+ratatui+serde, all pure Rust) is a normal cargo build.
