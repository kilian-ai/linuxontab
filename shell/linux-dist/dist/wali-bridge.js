// WALI bridge: lets a wasm32-wali-linux-musl binary (Rust's Linux-on-wasm
// target, or anything built against wali-musl) run on this guest.
//
// WALI (github.com/arjunr2/WALI) is "the x86-64 Linux syscall ABI, imported":
// the module imports one function per syscall, `wali.SYS_<x86-64 name>`, with
// x86-64 argument conventions and LP64 struct layouts (long = 64-bit, pointers
// and size_t = 32-bit — see wali-musl/arch/wasm32/bits/alltypes.h.in:
// _Addr int, _Int64 long, _Reg long). This guest's kernel is a 32-bit
// asm-generic Linux (long = 32-bit) reached through one `linux.syscall(nr,
// a0..a5)` import. So every SYS_* here does three things:
//   1. number translation x86-64 -> asm-generic (write 1 -> 64, ...), with the
//      legacy calls rewritten to their *at() forms (open -> openat, ...);
//   2. layout translation where a struct contains a `long`: stat (served from
//      statx), rt_sigaction (kernel sigaction has no restorer and a 32-bit
//      flags), lseek (32-bit kernel = llseek with a result pointer), timeval;
//      timespec is handled by using the *_time64 syscalls, whose 64-bit layout
//      is exactly WALI's;
//   3. host-side memory: this kernel has no mmap/brk (C musl grows wasm
//      memory itself), so mmap/munmap/mremap/brk are served here via
//      memory.grow; file mappings are emulated by reading the file in.
// argv/env come from the kernel's get_args export; the environment is handed
// to wali-musl the way it expects it — a KEY=VALUE\n file it reads at startup.
//
// The `syscall` callback must be the worker's full linux.syscall closure (with
// its clock/getrandom/sigaltstack shims), not the raw kernel export.

export function makeWaliImports({ memory, kernel, syscall, log }) {
    const B = BigInt;
    const dbg = log || (() => {});
    // i64 imports arrive as BigInt, i32 as Number. Everything the kernel takes
    // is a 32-bit long; pointers/lengths are unsigned, offsets signed — both
    // fit in the low 32 bits after asIntN.
    const n = (x) => (typeof x === 'bigint' ? Number(B.asIntN(64, x)) : x);
    const i32 = (x) => n(x) | 0;
    const big = (x) => (typeof x === 'bigint' ? B.asIntN(64, x) : B(x | 0));
    const R = (r) => B(r | 0);                         // i32 result -> i64
    const sc = (nr, ...a) => syscall(nr, ...[0, 1, 2, 3, 4, 5].map((k) => i32(a[k] === undefined ? 0 : a[k])));
    const dv = () => new DataView(memory.buffer);
    const u8 = () => new Uint8Array(memory.buffer);

    // One 64 KiB scratch page in guest memory for translated structs. Every
    // SYS_* starts from offset 0; a call never needs more than a few KiB.
    const PAGE = 65536;
    const SCRATCH = memory.grow(1) * PAGE;
    let sp = 0;
    const scratch = (size, align = 8) => { sp = (sp + align - 1) & ~(align - 1); const p = SCRATCH + sp; sp += size; if (sp > PAGE) throw new Error('wali scratch overflow'); return p; };
    const reset = () => { sp = 16; };                  // byte 0..15: a NUL string + padding
    const EMPTY_STR = SCRATCH;                         // "" for AT_EMPTY_PATH
    const zero = (p, len) => u8().fill(0, p, p + len);

    const AT_FDCWD = -100, AT_EMPTY_PATH = 0x1000, AT_SYMLINK_NOFOLLOW = 0x100, AT_REMOVEDIR = 0x200;
    const ENOSYS = -38, EINVAL = -22, ENOMEM = -12, EBADF = -9;

    // ---- args / env from the kernel -----------------------------------------
    // struct wasm_process_args { int len, envc, argc; char **argv, **envp; char data[]; }
    let args = null, debugAll = false;
    const loadArgs = () => {
        if (args) return args;
        args = { argv: [], envp: [] };
        try {
            const len = kernel.exports.get_args_length();
            if (len <= 0) { dbg('wali: get_args_length=' + len); return args; }
            const pages = Math.ceil(len / PAGE);
            const buf = memory.grow(pages) * PAGE;
            const gr = kernel.exports.get_args(buf);
            if (gr < 0) { dbg('wali: get_args=' + gr); return args; }
            const d = dv(), m = u8();
            const envc = d.getInt32(buf + 4, true), argc = d.getInt32(buf + 8, true);
            dbg('wali: args len=' + len + ' argc=' + argc + ' envc=' + envc);
            const argv = d.getUint32(buf + 12, true), envp = d.getUint32(buf + 16, true);
            const cstr = (p) => { let e = p; while (m[e]) e++; return new TextDecoder().decode(m.slice(p, e)); }; // slice: TextDecoder rejects shared views
            for (let i = 0; i < argc; i++) args.argv.push(cstr(d.getUint32(argv + 4 * i, true)));
            for (let i = 0; i < envc; i++) args.envp.push(cstr(d.getUint32(envp + 4 * i, true)));
            if (args.envp.includes('WALI_DEBUG=1')) debugAll = true;   // per-process syscall trace
        } catch (e) { dbg('wali: get_args failed: ' + e); }
        return args;
    };
    const putStr = (p, s, max) => { const b = new TextEncoder().encode(s); const k = Math.min(b.length, max - 1); u8().set(b.subarray(0, k), p); u8()[p + k] = 0; return k; };

    // ---- host-side memory ---------------------------------------------------
    const MAP_ANONYMOUS = 0x20;
    // Page allocator over memory.grow. wasm memory never shrinks, and mallocng
    // mmaps/munmaps 4 KB groups constantly (every ratatui frame), so growing a
    // fresh 64 KB wasm page per mmap exhausted --max-memory in minutes.
    // Freed runs (64 KB granules) go on a free list and are reused, zeroed.
    const free = [];                                   // [{ base, pages }]
    const alloc = (bytes) => {
        const pages = Math.ceil(bytes / PAGE);
        let best = -1;
        for (let i = 0; i < free.length; i++) if (free[i].pages >= pages && (best < 0 || free[i].pages < free[best].pages)) best = i;
        if (best >= 0) {
            const run = free[best], base = run.base;
            if (run.pages === pages) free.splice(best, 1); else { run.base += pages * PAGE; run.pages -= pages; }
            zero(base, pages * PAGE);
            return base;
        }
        try { return memory.grow(pages) * PAGE; } catch (_) { return ENOMEM; }
    };
    const release = (addr, bytes) => {
        const base = addr >>> 0, pages = Math.ceil(bytes / PAGE);
        if (base % PAGE !== 0 || pages === 0) return;
        free.push({ base, pages });
        free.sort((a, b) => a.base - b.base);           // coalesce neighbours
        for (let i = 0; i + 1 < free.length;) {
            if (free[i].base + free[i].pages * PAGE === free[i + 1].base) { free[i].pages += free[i + 1].pages; free.splice(i + 1, 1); } else i++;
        }
    };
    const grow = alloc;
    const host_mmap = (addr, length, prot, flags, fd, offset) => {
        const len = i32(length) >>> 0, fl = i32(flags), f = i32(fd);
        if (len === 0) return EINVAL;
        const base = grow(len);
        if (base < 0) return base;
        if ((fl & MAP_ANONYMOUS) || f < 0) return base;   // fresh pages are zero
        // File mapping: read the range in (MAP_PRIVATE semantics are all the
        // callers here need — wali-musl maps its env file, Rust mmaps nothing).
        let off = Number(big(offset)), got = 0;
        while (got < len) {
            const r = sc(67, f, base + got, len - got, off + got);     // pread64
            if (r <= 0) break;
            got += r;
        }
        return base;
    };
    let brk = 0;
    const host_brk = (addr) => { if (!brk) brk = memory.buffer.byteLength; return brk; }; // never moves -> malloc uses mmap

    // ---- struct translation helpers ------------------------------------------
    // WALI struct stat (x86-64 layout, 144 bytes) from statx (256 bytes).
    const statxToStat = (sx, st) => {
        const d = dv();
        const mkdev = (maj, min) => (B(maj & 0xfffff000) << 32n) | B((maj & 0xfff) << 8) | B((min & 0xffffff00) << 12) | B(min & 0xff);
        zero(st, 144);
        d.setBigUint64(st + 0, mkdev(d.getUint32(sx + 136, true), d.getUint32(sx + 140, true)), true); // st_dev
        d.setBigUint64(st + 8, d.getBigUint64(sx + 32, true), true);                                  // st_ino
        d.setBigUint64(st + 16, B(d.getUint32(sx + 16, true)), true);                                 // st_nlink
        d.setUint32(st + 24, d.getUint16(sx + 28, true), true);                                       // st_mode
        d.setUint32(st + 28, d.getUint32(sx + 20, true), true);                                       // st_uid
        d.setUint32(st + 32, d.getUint32(sx + 24, true), true);                                       // st_gid
        d.setBigUint64(st + 40, mkdev(d.getUint32(sx + 128, true), d.getUint32(sx + 132, true)), true); // st_rdev
        d.setBigUint64(st + 48, d.getBigUint64(sx + 40, true), true);                                 // st_size
        d.setBigUint64(st + 56, B(d.getUint32(sx + 4, true)), true);                                  // st_blksize
        d.setBigUint64(st + 64, d.getBigUint64(sx + 48, true), true);                                 // st_blocks
        for (const [from, to] of [[64, 72], [112, 88], [96, 104]]) {                                 // atime, mtime, ctime
            d.setBigInt64(st + to, d.getBigInt64(sx + from, true), true);
            d.setBigInt64(st + to + 8, B(d.getUint32(sx + from + 8, true)), true);
        }
    };
    const doStat = (dirfd, path, st, flags) => {
        const sx = scratch(256);
        const r = sc(291, dirfd, path, flags, 0x7ff, sx);             // statx(STATX_BASIC_STATS)
        if (r === 0) statxToStat(sx, st);
        return r;
    };

    // rt_sigaction: WALI k_sigaction is packed {handler u32, flags u64, restorer u32, mask u64} = 24 B;
    // kernel struct sigaction here is {handler u32, flags u32, mask u64} = 16 B (no SA_RESTORER).
    const sigaction = (sig, act, oact, size) => {
        const d = dv();
        let kact = 0, koact = 0;
        if (act) {
            kact = scratch(16);
            d.setUint32(kact, d.getUint32(act, true), true);
            d.setUint32(kact + 4, Number(d.getBigUint64(act + 4, true) & 0xfbffffffn), true); // drop SA_RESTORER
            d.setBigUint64(kact + 8, d.getBigUint64(act + 16, true), true);
        }
        if (oact) koact = scratch(16);
        const r = sc(134, sig, kact, koact, 8);
        if (r === 0 && oact) {
            zero(oact, 24);
            d.setUint32(oact, d.getUint32(koact, true), true);
            d.setBigUint64(oact + 4, B(d.getUint32(koact + 4, true)), true);
            d.setBigUint64(oact + 16, d.getBigUint64(koact + 8, true), true);
        }
        return r;
    };

    // 32-bit kernel: lseek is llseek(fd, hi, lo, &result, whence).
    const lseek = (fd, off, whence) => {
        const o = big(off), res = scratch(8);
        const r = sc(62, fd, Number((o >> 32n) & 0xffffffffn), Number(o & 0xffffffffn), res, whence);
        return r < 0 ? B(r) : dv().getBigInt64(res, true);
    };

    // timeval {i64 sec, i64 usec} (WALI) from clock_gettime64's timespec.
    const gettimeofday = (tv, tz) => {
        if (!tv) return 0;
        const ts = scratch(16), r = sc(403, 0, ts);
        if (r !== 0) return r;
        const d = dv();
        d.setBigInt64(tv, d.getBigInt64(ts, true), true);
        d.setBigInt64(tv + 8, d.getBigInt64(ts + 8, true) / 1000n, true);
        return 0;
    };
    // poll(fds, nfds, timeout_ms) -> ppoll_time64(fds, nfds, timespec64*, NULL, 8)
    const poll = (fds, nfds, ms) => {
        let ts = 0;
        if (ms >= 0) { ts = scratch(16); const d = dv(); d.setBigInt64(ts, B(Math.floor(ms / 1000)), true); d.setBigInt64(ts + 8, B((ms % 1000) * 1000000), true); }
        return sc(414, fds, nfds, ts, 0, 8);
    };
    // pselect6: the 6th arg points at {sigset*, size} — LP64 {i64,i64} vs kernel {u32,u32}.
    const pselect6 = (nfds, rd, wr, ex, ts, sig6) => {
        let k6 = 0;
        if (sig6) { k6 = scratch(8); const d = dv(); d.setUint32(k6, Number(d.getBigUint64(sig6, true) & 0xffffffffn), true); d.setUint32(k6 + 4, Number(d.getBigUint64(sig6 + 8, true) & 0xffffffffn), true); }
        return sc(413, nfds, rd, wr, ex, ts, k6);
    };
    // getrlimit(res, rlimit{u64,u64}) -> prlimit64(0, res, NULL, old) (same layout).
    const getrlimit = (res, rl) => sc(261, 0, res, 0, rl);
    const setrlimit = (res, rl) => sc(261, 0, res, rl, 0);
    // rusage is 18 longs after two timevals: hand the kernel nothing, report zeros.
    const wait4 = (pid, status, options, rusage) => { const r = sc(260, pid, status, options, 0); if (rusage) zero(rusage, 144); return r; };
    const getrusage = (who, rusage) => { if (rusage) zero(rusage, 144); return 0; };

    // env file for wali-musl's init_env(): KEY=VALUE lines. Written through the
    // kernel so it is an ordinary file the guest can open + mmap (see host_mmap).
    let envfile = null;
    const writeEnvFile = () => {
        if (envfile !== null) return envfile;
        envfile = '';
        const { envp } = loadArgs();
        if (!envp.length) return envfile;
        const name = '/tmp/.wali-env-' + (sc(172) | 0);                    // getpid
        const p = scratch(256); putStr(p, name, 256);
        const fd = sc(56, AT_FDCWD, p, 0x241, 0o600);                      // openat O_WRONLY|O_CREAT|O_TRUNC
        if (fd < 0) { dbg('wali: env file open failed ' + fd); return envfile; }
        const bytes = new TextEncoder().encode(envp.join('\n') + '\n');
        const pages = Math.ceil(bytes.length / PAGE), buf = memory.grow(pages) * PAGE;
        u8().set(bytes, buf);
        let off = 0;
        while (off < bytes.length) { const r = sc(64, fd, buf + off, bytes.length - off); if (r <= 0) break; off += r; }
        sc(57, fd);                                                        // close
        envfile = name;
        return envfile;
    };

    // ---- the import table ----------------------------------------------------
    // Pass-through: same argument list, different number.
    const direct = {
        read: 63, write: 64, close: 57, ioctl: 29, readv: 65, writev: 66, sched_yield: 124,
        dup: 23, dup3: 24, getpid: 172, getppid: 173, getuid: 174, geteuid: 175, getgid: 176, getegid: 177,
        gettid: 178, exit: 93, exit_group: 94, kill: 129, tkill: 130, uname: 160, getcwd: 17, chdir: 49, fchdir: 50,
        openat: 56, mkdirat: 34, unlinkat: 35, symlinkat: 36, linkat: 37, renameat2: 276, readlinkat: 78,
        faccessat: 48, faccessat2: 439, fchmod: 52, fchmodat: 53, fchownat: 54, fchown: 55, fcntl: 25, flock: 32,
        fsync: 82, fdatasync: 83, getdents64: 61, pipe2: 59, set_tid_address: 96, set_robust_list: 99,
        rt_sigprocmask: 135, rt_sigpending: 136, rt_sigsuspend: 133, rt_sigreturn: 139, sigaltstack: 132,
        getrandom: 278, prlimit64: 261, sched_getaffinity: 123, umask: 166, setsid: 157, setpgid: 154, getpgid: 155, getsid: 156,
        getgroups: 158, setgroups: 159, setuid: 146, setgid: 144, setreuid: 145, setregid: 143, setresuid: 147, setresgid: 149,
        epoll_create1: 20, epoll_ctl: 21, epoll_pwait: 22, eventfd2: 19, socket: 198, socketpair: 199, bind: 200, listen: 201,
        accept4: 242, connect: 203, getsockname: 204, getpeername: 205, sendto: 206, recvfrom: 207, setsockopt: 208,
        getsockopt: 209, shutdown: 210, sendmsg: 211, recvmsg: 212, statfs: 43, fstatfs: 44, utimensat: 412, prctl: 167,
        pread64: 67, pwrite64: 68, ftruncate: 46, clock_getres: 406,
        clock_gettime: 403, clock_nanosleep: 407, futex: 422, ppoll: 414, execve: 221, statx: 291, chroot: 51,
        sysinfo: 179, setitimer: 103,
    };
    const wali = {};
    for (const [name, nr] of Object.entries(direct)) wali['SYS_' + name] = (...a) => R(sc(nr, ...a));
    Object.assign(wali, {
        // legacy -> *at()
        SYS_open: (path, flags, mode) => R(sc(56, AT_FDCWD, path, flags, mode)),
        SYS_access: (path, mode) => R(sc(48, AT_FDCWD, path, mode, 0)),
        SYS_chmod: (path, mode) => R(sc(53, AT_FDCWD, path, mode, 0)),
        SYS_chown: (path, u, g) => R(sc(54, AT_FDCWD, path, u, g, 0)),
        SYS_mkdir: (path, mode) => R(sc(34, AT_FDCWD, path, mode)),
        SYS_rmdir: (path) => R(sc(35, AT_FDCWD, path, AT_REMOVEDIR)),
        SYS_unlink: (path) => R(sc(35, AT_FDCWD, path, 0)),
        SYS_link: (a, b) => R(sc(37, AT_FDCWD, a, AT_FDCWD, b, 0)),
        SYS_symlink: (a, b) => R(sc(36, a, AT_FDCWD, b)),
        SYS_rename: (a, b) => R(sc(276, AT_FDCWD, a, AT_FDCWD, b, 0)),
        SYS_readlink: (path, buf, len) => R(sc(78, AT_FDCWD, path, buf, len)),
        SYS_dup2: (a, b) => R(i32(a) === i32(b) ? sc(25, a, 1) >= 0 ? i32(a) : EBADF : sc(24, a, b, 0)),
        SYS_pipe: (fds) => R(sc(59, fds, 0)),
        SYS_eventfd: (c) => R(sc(19, c, 0)),
        SYS_epoll_create: () => R(sc(20, 0)),
        SYS_epoll_wait: (ep, ev, max, ms) => R(sc(22, ep, ev, max, ms, 0, 8)),
        SYS_waitid: (...a) => R(sc(95, ...a)),
        SYS_sched_setscheduler: () => R(0),
        SYS_arch_prctl: () => R(ENOSYS),
        SYS_accept: (s, a, l) => R(sc(242, s, a, l, 0)),
        SYS_select: (nfds, rd, wr, ex, tv) => {
            let ts = 0;
            if (tv) { ts = scratch(16); const d = dv(); d.setBigInt64(ts, d.getBigInt64(tv, true), true); d.setBigInt64(ts + 8, d.getBigInt64(tv + 8, true) * 1000n, true); }
            return R(sc(413, nfds, rd, wr, ex, ts, 0));
        },
        SYS_nanosleep: (req, rem) => R(sc(407, 0, 0, req, rem)),
        SYS_pause: () => R(sc(414, 0, 0, 0, 0, 8)),               // ppoll(NULL) until a signal
        SYS_poll: (fds, nfds, ms) => R(poll(fds, nfds, i32(ms))),
        SYS_pselect6: (...a) => R(pselect6(...a)),
        SYS_gettimeofday: (tv, tz) => R(gettimeofday(i32(tv), tz)),
        // stat family via statx
        SYS_stat: (path, st) => R(doStat(AT_FDCWD, path, i32(st), 0)),
        SYS_lstat: (path, st) => R(doStat(AT_FDCWD, path, i32(st), AT_SYMLINK_NOFOLLOW)),
        SYS_fstat: (fd, st) => R(doStat(fd, EMPTY_STR, i32(st), AT_EMPTY_PATH)),
        SYS_newfstatat: (dirfd, path, st, flags) => R(doStat(dirfd, path, i32(st), i32(flags))),
        // signals, seeking, limits
        SYS_rt_sigaction: (sig, act, oact, size) => R(sigaction(i32(sig), i32(act), i32(oact), i32(size))),
        SYS_lseek: (fd, off, whence) => lseek(fd, off, whence),
        SYS_getrlimit: (res, rl) => R(getrlimit(res, rl)),
        SYS_setrlimit: (res, rl) => R(setrlimit(res, rl)),
        SYS_wait4: (pid, st, opt, ru) => R(wait4(pid, st, opt, i32(ru))),
        SYS_getrusage: (who, ru) => R(getrusage(who, i32(ru))),
        // memory (host-side)
        SYS_mmap: (addr, len, prot, flags, fd, off) => R(host_mmap(addr, len, prot, flags, fd, off)),
        SYS_munmap: (addr, len) => { release(i32(addr), i32(len) >>> 0); return R(0); },
        // Linear memory has no protection bits and no advice: std's stack guard
        // page (mprotect) and allocator hints (madvise) just succeed.
        SYS_mprotect: () => R(0), SYS_madvise: () => R(0), SYS_msync: () => R(0),
        SYS_mremap: (old, oldLen, newLen, flags) => {   // grow + copy (MREMAP_MAYMOVE)
            const b = grow(i32(newLen) >>> 0);
            if (b < 0) return R(b);
            u8().copyWithin(b, i32(old), i32(old) + Math.min(i32(oldLen) >>> 0, i32(newLen) >>> 0));
            release(i32(old), i32(oldLen) >>> 0);
            return R(b);
        },
        SYS_brk: (addr) => R(host_brk(addr)),
        // not provided by this kernel / not bridged (yet): processes, threads
        SYS_fork: () => R(ENOSYS), SYS_vfork: () => R(ENOSYS), SYS_clone: () => R(ENOSYS), SYS_clone3: () => R(ENOSYS),
        SYS_fadvise: () => R(0),
        // lifecycle + argv/env (see wali-musl/arch/wasm32/init_env.h)
        __init: () => { loadArgs(); return 0; },
        __deinit: () => 0,
        __proc_exit: (code) => { sc(94, i32(code)); },
        __cl_get_argc: () => loadArgs().argv.length,
        __cl_get_argv_len: (i) => new TextEncoder().encode(loadArgs().argv[i32(i)] || '').length,
        __cl_copy_argv: (buf, i) => { const s = loadArgs().argv[i32(i)] || ''; const b = new TextEncoder().encode(s); u8().set(b, i32(buf)); u8()[i32(buf) + b.length] = 0; return b.length; },
        __get_init_envfile: (buf, size) => { const f = writeEnvFile(); if (!f) return 0; return putStr(i32(buf), f, i32(size)); },
        // threads (wali-musl pthread_impl.h): not bridged yet — pthread_create
        // fails with EAGAIN so std::thread::Builder::spawn returns an Err
        // instead of the process dying. __set_thread_area just records TLS.
        __wasm_thread_spawn: () => { dbg('wali: __wasm_thread_spawn -> EAGAIN (threads not bridged)'); return -11; },
        __clone: () => ENOSYS,
        __set_thread_area: () => 0,
        __unmapself: () => {},
    });
    // Every SYS_* starts with a fresh scratch page and is logged on request.
    for (const k of Object.keys(wali)) {
        if (!k.startsWith('SYS_')) continue;
        const f = wali[k];
        wali[k] = (...a) => {
            reset(); const r = f(...a);
            if (debugAll || globalThis.__walidebug) {
                let extra = '';
                try {
                    if (k === 'SYS_ioctl' && n(a[1]) === 0x5413) { const d = dv(), p = n(a[2]); extra = ' winsize=' + [0, 2, 4, 6].map((o) => d.getUint16(p + o, true)).join('x'); }
                    if (k === 'SYS_write' && n(a[2]) <= 200) extra = ' ' + JSON.stringify(new TextDecoder().decode(u8().slice(n(a[1]), n(a[1]) + n(a[2]))));
                    if (k === 'SYS_epoll_ctl') { const d = dv(), p = n(a[3]); extra = ' events=0x' + d.getUint32(p, true).toString(16) + ' data=' + d.getBigUint64(p + 8, true); }
                } catch (_) {}
                dbg(k + '(' + a.map(n).join(',') + ') = ' + r + extra);
            }
            return r;
        };
    }
    const envExtra = { _Unwind_Backtrace: () => 0, _Unwind_GetIP: () => 0, _Unwind_GetIPInfo: () => 0, _Unwind_GetCFA: () => 0, _Unwind_GetRegionStart: () => 0 };
    // Any SYS_* a module imports that is not bridged above links to an ENOSYS
    // stub (logged on first use) instead of failing instantiation outright:
    // std links ~150 syscalls it will never call in a given program.
    const missing = new Set();
    const proxied = new Proxy(wali, {
        get(t, k) {
            if (k in t || typeof k !== 'string' || !k.startsWith('SYS_')) return t[k];
            return (...a) => { if (!missing.has(k)) { missing.add(k); dbg('wali: unbridged ' + k + ' -> ENOSYS'); } return B(ENOSYS); };
        },
    });
    return { wali: proxied, envExtra };
}
