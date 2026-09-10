# WALI bridge — running Rust (and any wali-musl program) on the LinuxOnTab guest

Goal: make the guest speak **WALI** (WebAssembly Linux Interface) so Rust's
`wasm32-wali-linux-musl` target — and any wali-musl binary — runs on this
tombl guest. Vehicle for building `trust` and future Rust tooling.

## Status: Rust programs RUN on the guest — `trust` works, and **rustc compiles ON the guest**

`shell/linux-dist/dist/wali-bridge.js` is the bridge (imported by worker.js;
only modules that import `wali.*` use it, C binaries are untouched). It does:
- x86-64 → asm-generic syscall numbers, legacy → *at() rewrites;
- LP64 ↔ LP32 layout translation where a struct carries a `long`: stat family
  served from statx, rt_sigaction (no restorer, 32-bit flags), lseek → llseek,
  gettimeofday/select/pselect6 (timeval/sigset args), poll → ppoll_time64.
  timespec-carrying calls use the *_time64 syscalls, whose 64-bit layout IS
  WALI's (clock_gettime → 403, nanosleep → 407, futex → 422, ppoll → 414 …);
- host-side memory: mmap/munmap/mremap/brk over memory.grow with a 64 KB-granule
  free list (mallocng churns 4 KB mmaps per frame; growing per call exhausted
  --max-memory in minutes), mprotect/madvise/msync no-ops, file mmap via pread;
- argv/env from the kernel's get_args; env is handed to wali-musl as the
  KEY=VALUE\n file its init_env() expects (written to /tmp/.wali-env-<pid>);
- unbridged SYS_* resolve to an ENOSYS stub (logged once) instead of a LinkError.
- threads: `__wasm_thread_spawn(fn, args)` → kernel clone(fn, args, 0x50f00);
  the worker's WALI `switch_entry` branch calls `fn(gettid(), args)` and keeps
  that entry as `call_entry` so an asyncify fork from a thread rewinds through
  it (parent and child — the entry travels to the child as fork_entry_fn/arg);
  fork/vfork → clone(SIGCHLD) (the kernel's asyncify fork; child memories
  inherit the module's 4 GB maximum via parent_mem_max, or a >256 MB rustc
  could not fork); `__clone` (posix_spawn) → clone(fn, arg, flags).
- NOT yet: sysinfo/setitimer/getrusage layouts; copy_file_range (x86-64 326)
  is not in wali-musl's table ("Invalid syscall var call -- NR 326" is noise,
  std falls back to read/write).
Debug: `WALI_DEBUG=1 prog` traces every syscall to the browser console.

Terminal size: the kernel tty reported 0x0 (no resize path), so the page now
puts `lot_tty=ROWSxCOLS` on the cmdline and /etc/rc applies it with stty —
that also gives ncurses apps their real size instead of the 80x24 fallback.

### Build a Rust crate for the guest
```
./toolchain/wali/build-wali-musl.sh                 # once: LLVM 22 + wali-musl -> /tmp/wali-sysroot
./toolchain/wali/build-rust-crate.sh <crate> out.wasm   # build-std + link + asyncify
LEAN_EXTRA_BIN=out.wasm ./cloudflare/build-lean-rootfs.sh   # local test image
```
Crates that hard-code "wasm32 has no OS" need `patches/` (applied to vendored
copies by the script): mio (compile_error gate), linux-raw-sys (wasm32 → x32
layouts: the x86-64 kernel ABI with 32-bit pointers — exactly WALI), rustix
(ioctl encoding). `trust` (crossterm + ratatui + serde) then builds unmodified.

### rustc on the guest (`packages/rustc-1.99.0.tar.gz`, 70 MB)
`lot-rustc hello.rs && ./hello` in the guest. rustc 1.99.0-nightly (rust @1a98b1e)
is built as a `wasm32-wali-linux-musl` *host* compiler; hello.rs compiles to an
object in ~2 s. Pieces:
- `rustc-bootstrap.toml` — the bootstrap config (host+target wasm32-wali-linux-musl,
  `[target] cc/cxx/linker` = `tools/` wrappers, llvm-config shim over the LLVM 23
  libs cross-built with `tools/wali.cmake` + `-DLLVM_COMPILER_CHECKED=ON`).
  `WASM_MUSL_SYSROOT=/tmp/wali-sysroot x.py build --stage 2 --host wasm32-wali-linux-musl
  --target wasm32-wali-linux-musl --warnings warn compiler/rustc`, then the target std
  with `LOT_EMBED_METADATA=1 x.py build --stage 1 --target wasm32-wali-linux-musl
  --warnings warn library/std` (patches/rustc-bootstrap-embed-metadata.patch: full
  metadata inside the rlibs, so the package ships no .rmeta; with
  `debuginfo-level-std = 0` the sysroot is 90 MB instead of 550).
- `patches/` — rustc-wali-host.patch (Cargo [patch] entries for the vendored
  linux-raw-sys 0.11 / rustix 1.1.2 / object / libc 0.2.183 fixes, rustc_driver as
  rlib, static target spec, sysroot lookup falls back to current_exe: the driver is
  not a dylib so dladdr() has nothing), libc-0.2.183.patch (`c_long = i64` on
  wasm32-linux — WALI's `long` is 64-bit; the mismatch showed up as a
  call_indirect signature trap in `sysconf`), rustix-1.1.2.patch (`syscall!()`
  varargs widened to `long`: wali-musl reads every vararg as 8 bytes).
- `package-rustc.sh` — strip + asyncify rustc (148 MB module), ship
  `bin/rustc.wasm -> rustc.real.wasm` (rustc only trusts argv[0] for the sysroot
  when it is a symlink) and `lib32 -> lib` (a 32-bit host looks in lib32/rustlib),
  the rlibs + self-contained crt1/libc/builtins, and **rust-lld**: lld 23 from the
  same llvm-project, cross-built standalone for wasm32-wali against the LLVM 23 build
  tree (`cmake -S llvm-project/lld -DLLVM_DIR=/tmp/llvm23-wali/lib/cmake/llvm
  -DCMAKE_TOOLCHAIN_FILE=tools/wali.cmake -DHAVE_CXX_ATOMICS_WITHOUT_LIB=1
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON`, full link flags in CMAKE_EXE_LINKER_FLAGS
  since it overrides the toolchain's _INIT flags). The guest's C-toolchain
  wasm-ld 19 traps (OOB) on any rustc-built object ≥ 16 KB — LLVM mmap()s inputs
  that size and that musl's mmap can't back a file — while the same lld 19 on the
  host links it fine; a WALI lld goes through the bridge's pread-backed mmap.
- `guest/` — `rustc` (sysroot, target, `-C linker=lot-rust-ld -C panic=abort`),
  `lot-rust-ld` (rust-lld `--threads=1` + libc + libunwind + builtins +
  `--import-memory --export-table --export=__heap_base --export=__data_end -z
  stack-size=8M`; lld's parallel readers on WALI threads hit a kernel BUG in
  fs/buffer.c), `lot-rustc` (rustc + wasm-opt --asyncify; asyncify is only needed
  for fork/Command::spawn — raw modules run with threads, sleep and blocking reads,
  so lot-rustc keeps the raw module when wasm-opt fails). The package depends on
  `wasm-opt`: binaryen 129 cross-built for WALI by the same cmake recipe as lld
  (the old C-toolchain wasm-opt traps in musl's allocator on a 500 KB module);
  `package-linkers.sh` registers it and the C toolchain's `wasm-ld`.
- Bridge additions for the toolchain: writable MAP_SHARED file mappings are written
  back with pwrite on munmap/msync (lld's OnDiskBuffer; the fd is dup'ed at mmap
  time), `setjmp`/`longjmp` host imports (LLVM CrashRecoveryContext) are stubs.
- Kernel cmdline gets `rcupdate.rcu_cpu_stall_suppress=1` (wasm.html): a link
  that holds the single CPU for minutes triggers the RCU stall report, whose
  show_regs() is a BUG() in this port and halted the guest.
- **cargo** (`packages/cargo-0.100.0.tar.gz`, 11 MB, depends on rustc): built by the
  same bootstrap, `x.py build --stage 2 --host wasm32-wali-linux-musl src/tools/cargo`
  with `build.cargo-native-static = true` (vendored OpenSSL 3 / curl / nghttp2 /
  libgit2 / libssh2 / zlib / sqlite, all compiled by the cc crate through the wali
  wrappers; OpenSSL needs patches/openssl-src-300.6.1.patch mapping the triple to
  `linux-generic32 no-asm`; an empty `libatomic.a` in the sysroot satisfies a
  `-latomic` some build script emits). cargo has its own workspace and lockfile, so
  the crate fixes are vendored again for its versions (patches/cargo-wali-host.patch
  = the `[patch.crates-io]` block): rustix 1.1.4 + linux-raw-sys 0.12.1 + mio 1.2.1
  (as for trust), gix-pack (a `not(wasm32)` gate on gix-tempfile), is_executable
  (unix + wasm impls both matched), filetime (stub module for any non-emscripten
  wasm). Guest: `package-cargo.sh`, wrapper `guest/cargo` (seeds
  `$CARGO_HOME/config.toml`: build.rustc = the guest rustc wrapper, linker,
  panic=abort, jobs=1; `CARGO_HTTP_MULTIPLEXING=false`).
- Not possible yet: proc-macro crates (need a dynamic loader).
- Local test image: `LEAN_SIZE_MIB=1024 LEAN_EXTRA_TREE=<unpacked pkgs>
  ./cloudflare/build-lean-rootfs.sh` (rustc + wasm-opt trees; 512 MiB overflows
  silently — mke2fs fails and the stale image is served).

### Files
- `build-wali-musl.sh` — reproduce the wali-musl sysroot (fetches LLVM 22).
- `build-rust-crate.sh` — cargo config + patches + build + asyncify.
- `patches/` — crate patches (mio, linux-raw-sys, rustix; rustc build patches above).
- `our-syscall-numbers.json`, `syscall-table.json` — number tables.
- `wali-imports*.js`, `gen-wali-imports.py` — the original generated scaffold
  (superseded by wali-bridge.js; kept for the tables).
