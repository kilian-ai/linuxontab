# WALI bridge — running Rust (and any wali-musl program) on the LinuxOnTab guest

Goal: make the guest speak **WALI** (WebAssembly Linux Interface) so Rust's
`wasm32-wali-linux-musl` target — and any wali-musl binary — runs on this
tombl guest. Vehicle for building `trust` and future Rust tooling.

## Status: Rust programs RUN on the guest — `trust` (ratatui TUI IDE) works

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
- NOT yet: threads (`__wasm_thread_spawn` → EAGAIN, so std::thread::Builder
  fails cleanly), fork/exec (ENOSYS), sysinfo/setitimer/getrusage layouts.
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

### Files
- `build-wali-musl.sh` — reproduce the wali-musl sysroot (fetches LLVM 22).
- `build-rust-crate.sh` — cargo config + patches + build + asyncify.
- `patches/` — crate patches (mio, linux-raw-sys, rustix).
- `our-syscall-numbers.json`, `syscall-table.json` — number tables.
- `wali-imports*.js`, `gen-wali-imports.py` — the original generated scaffold
  (superseded by wali-bridge.js; kept for the tables).
