import { assert } from "./util.js";
import { HALT_KERNEL, kernel_imports, } from "./wasm.js";

/**
 * Scan a Uint8Array for a valid WASM module of exactly expectedSize bytes.
 * musl wasm32 mmap() uses memory.grow (MAP_PRIVATE semantics), so LLD's
 * OnDiskBuffer never writes to the output file — the content lives only in
 * linear memory. We search for the WASM magic+version header, then validate
 * the section structure to confirm we found the right block.
 * Returns the byte offset of the module, or -1 if not found.
 */
function findValidWasm(buf, expectedSize, startOffset) {
    if (expectedSize < 8) return -1;
    const start = (startOffset > 0) ? startOffset : 0;
    const limit = buf.length - expectedSize;
    for (let i = start; i <= limit; i++) {
        if (buf[i] !== 0x00 || buf[i+1] !== 0x61 || buf[i+2] !== 0x73 || buf[i+3] !== 0x6d) continue;
        if (buf[i+4] !== 0x01 || buf[i+5] !== 0x00 || buf[i+6] !== 0x00 || buf[i+7] !== 0x00) continue;
        // Walk WASM sections to verify the block is exactly expectedSize bytes.
        let pos = i + 8;
        const end = i + expectedSize;
        let valid = true;
        while (pos < end) {
            if (pos >= buf.length) { valid = false; break; }
            pos++; // section id
            // Decode LEB128 section payload length (up to 4 bytes).
            let sz = 0, shift = 0, lebOk = false;
            for (let k = 0; k < 5 && pos < buf.length; k++) {
                const b = buf[pos++];
                sz |= (b & 0x7f) << shift;
                shift += 7;
                if ((b & 0x80) === 0) { lebOk = true; break; }
            }
            if (!lebOk || sz < 0 || pos + sz > end) { valid = false; break; }
            pos += sz;
        }
        if (valid && pos === end) return i;
    }
    return -1;
}
const unavailable = () => {
    throw new Error("not available on worker thread");
};
const postMessage = self.postMessage;
// Per-syscall tracing, opt-in via ?debuglog (plumbed through the init message).
// The syscall handler calls this twice per syscall, so leaving it on costs a
// postMessage per call and floods the main thread — enough to make the renderer
// unresponsive under any syscall-heavy load. Default off; the early return keeps
// the disabled path down to one boolean test.
let LOG_ENABLED = false;
// Optional syscall allow-list: ?debuglog=98,220 traces only those numbers.
// Tracing every syscall is far too slow to reach an interesting point in a
// Python workload (startup alone is ~100k syscalls), so narrowing to the few
// calls under investigation is usually the only practical way to trace.
// null = trace everything (plain ?debuglog).
let LOG_SYSCALL_FILTER = null;
const workerLog = (msg) => { if (!LOG_ENABLED) return; postMessage({ type: "log", msg: "[W:" + (self.name || '?') + "] " + msg }); };
// Use for the per-syscall trace so the filter applies; `nr` may be null for
// non-syscall messages, which are always emitted when logging is on.
const syscallLog = (nr, msg) => {
    if (!LOG_ENABLED) return;
    if (LOG_SYSCALL_FILTER !== null && !LOG_SYSCALL_FILTER.has(nr)) return;
    workerLog(msg);
};
function user_imports({ kernel_memory, get_kernel_instance, parent_user_module: parent_module, parent_user_memory: parent_memory, fork_bufPtr = null, fork_retPtr = null, setForkOverride, clearForkOverride, setThreadCloneOverride, clearThreadCloneOverride, setSuppressNextFutexWait, consumeSuppressNextFutexWait, isThreadCloneChild = null, }) {
    const HALT_USER = Symbol("halt user");
    const kernel_memory_buffer = new Uint8Array(kernel_memory.buffer);
    let module = null;
    let instance = null;
    let memory = null;
    // Initialize to parent_module so fork children (which inherit parent_module via
    // switch_entry) don't trigger the "module changed" → fresh memory path on their
    // first instantiate(0) call. Only a genuine execve changes module away from this.
    let _lastInstantiatedModule = parent_module ?? null;
    function call_start() {
        assert(instance);
        const { _start } = instance.exports;
        assert(typeof _start === "function", "_start not found");
        _start();
        throw new Error("_start reached the end without exiting");
    }
    let call_entry = call_start;
    // fork()/vfork() state:
    //   pendingFork — set by syscall handler during asyncify unwind (parent side)
    //   forkRewindState — set from message params for asyncify rewind (child side)
    let pendingFork = null;
    // Per-worker asyncify fork scratch region, memory.grow'n on first use.
    // Replaces the old fixed `byteLength - 4MB` buffer for binaries that don't
    // provide their own (busybox $() clone, wasm-stubs fork, legacy wasm_fork).
    // The fixed scheme sat wherever the top of memory happened to be: musl's
    // mmap/sbrk take pages at the END of memory via memory.grow, so after any
    // growth `byteLength - 4MB` pointed INSIDE live mapped data — a fork could
    // clobber e.g. an mmap'd framebuffer, or the mapping's writes could clobber
    // a suspended parent's saved stack. A grown region owns pages the guest
    // allocator can never hand out, so it is collision-free for the worker's
    // lifetime, and one region suffices per worker: a worker has at most one
    // fork in flight (it is suspended inside the syscall until rewind).
    // Layout: [retval i32 @ +0][pad][asyncify buf @ +16 .. size].
    const FORK_SCRATCH_SIZE = 4 * 1024 * 1024;
    let forkScratch = null; // { mem, retPtr, bufPtr, size }
    function acquireForkScratch() {
        if (forkScratch !== null && forkScratch.mem === memory)
            return forkScratch; // reuse; invalidated when execve swaps memory
        let base;
        try {
            base = memory.grow(FORK_SCRATCH_SIZE >> 16) * 65536;
        }
        catch (e) {
            // At max-memory: fall back to the legacy fixed top-of-memory region
            // (still better than failing the fork outright). Not cached.
            workerLog('fork-scratch: memory.grow failed (' + e + '), using fixed top region');
            const fbase = memory.buffer.byteLength - FORK_SCRATCH_SIZE;
            return { mem: memory, retPtr: fbase - 4, bufPtr: fbase, size: FORK_SCRATCH_SIZE };
        }
        forkScratch = { mem: memory, retPtr: base, bufPtr: base + 16, size: FORK_SCRATCH_SIZE - 16 };
        workerLog('fork-scratch: grew region at 0x' + base.toString(16));
        return forkScratch;
    }
    // The {bufPtr, retPtr} the in-flight fork is using, for the rewind
    // (state===2) leg of the clone intercepts: the parent stashes it at unwind
    // time, the child at switch_entry. It can NOT be recomputed from
    // byteLength there — the scratch region is not at a fixed offset (and
    // byteLength itself may have changed by rewind time).
    let activeForkBuf = null;
    // wasm-ld MAP_SHARED mmap workaround:
    //   musl wasm32 mmap() uses memory.grow instead of calling the kernel syscall,
    //   returning a private anonymous buffer. LLD writes WASM output to this buffer
    //   but OnDiskBuffer::commit() calls munmap() (silent free) then renames the
    //   zero-filled temp file — result is all-zero output. We fix this by:
    //   1. Tracking the last ftruncate(fd, size) call to know the output fd+size.
    //   2. At renameat time, scanning linear memory for a valid WASM module of that
    //      size and using pwrite64 to write it into the still-open fd before rename.
    let pendingWasmOutput = null; // { fd, size }
    let forkRewindState = (fork_bufPtr != null) ? { bufPtr: fork_bufPtr, retPtr: fork_retPtr } : null;
    return {
        get module() {
            return module;
        },
        get memory() {
            return memory;
        },
        imports: {
            // program management:
            compile(buf, size) {
                workerLog('compile buf=' + buf + ' size=' + size);
                const bytes = new Uint8Array(kernel_memory_buffer.slice(buf, buf + size));
                // Xvfb hotfix: force the branch gate in func[3616] to true, which
                // bypasses the crash block reached after xeyes connects.
                if (size === 3490984) {
                    const sig = [0x20, 0x00, 0x10, 0xa1, 0x1c, 0x22, 0x04, 0x28, 0x02, 0x14, 0x22, 0x01, 0x41, 0x1f, 0x71];
                    let match = -1;
                    let count = 0;
                    for (let i = 0; i <= bytes.length - sig.length; i++) {
                        let ok = true;
                        for (let j = 0; j < sig.length; j++) {
                            if (bytes[i + j] !== sig[j]) {
                                ok = false;
                                break;
                            }
                        }
                        if (ok) {
                            count++;
                            match = i;
                        }
                    }
                    if (count === 1) {
                        const branchAt = match - 4;
                        if (branchAt >= 0 && bytes[branchAt + 0] === 0x20 && bytes[branchAt + 1] === 0x02 && bytes[branchAt + 2] === 0x0d && bytes[branchAt + 3] === 0x01) {
                            bytes[branchAt + 0] = 0x41;
                            bytes[branchAt + 1] = 0x01;
                        } else {
                            workerLog('xvfb fix: branch signature mismatch at=' + branchAt);
                        }
                    } else {
                        workerLog('xvfb fix: signature matches=' + count);
                    }
                }
                try {
                    module = new WebAssembly.Module(bytes);
                    workerLog('compile OK size=' + size);
                    return 0;
                }
                catch (e) {
                    workerLog('compile FAILED: ' + e);
                    return -8; // exec format error
                }
            },
            instantiate(fresh_memory) {
                workerLog('instantiate fresh_memory=' + fresh_memory);
                assert(module);
                // Always allocate fresh memory when:
                //   (a) kernel explicitly requests it (fresh_memory=1), OR
                //   (b) no memory yet, OR
                //   (c) the module changed since the last instantiate — this is
                //       an execve path where the kernel passes fresh_memory=0 but
                //       the old memory belongs to the previous (sh) process.
                //       Reusing dirty sh heap causes the new binary's malloc
                //       allocator to read garbage chunk headers and crash.
                const moduleChanged = (module !== _lastInstantiatedModule);
                if (fresh_memory || !memory || moduleChanged) {
                    if (moduleChanged && !fresh_memory && memory) {
                        workerLog('instantiate: module changed, forcing fresh memory (was reusing old process memory)');
                    }
                    const size = 2048 + Math.floor(Math.random() * 1000);
                    // TODO: read the real initial size from the module.
                    // TOOD: enforce rlimit via maximum.
                    // maximum > initial so musl's memory.grow-based sbrk can extend
                    // the heap. With initial==maximum, memory.grow always returns -1
                    // and large malloc() calls (e.g. wasm3 loading a 47MB binary) fail.
                    // 4096 pages = 256MB max; SAB uses virtual memory only.
                    memory = new WebAssembly.Memory({
                        initial: size,
                        maximum: 4096,
                        shared: true,
                    });
                }
                _lastInstantiatedModule = module;
                const kernel_instance = get_kernel_instance();
                // Guest clock recovery without running kernel code on this worker.
                // Calling ktime helpers (get_monotonic_ns etc.) from a user worker is
                // NOT safe in every context: pthread-clone child instances never enter
                // the kernel, their shadow-stack pointer still points at init_stack,
                // and any non-leaf kernel call scribbles over CPU 0's idle stack
                // (observed as the whole guest wedging on the next blocking syscall).
                // Instead the kernel publishes clock origins (raw - clock) in
                // wasm_clock_origins[]; get_clock_origins() is a bare i32.const (safe
                // from any instance) and everything else is memory reads + JS math:
                //   CLOCK_x(now) = raw(now) - origin[x],
                //   raw = performance.timeOrigin + performance.now()  (same formula as
                //   the kernel's get_now_nsec import, identical across workers).
                let clockOriginsAddr = 0;
                let clockClampWarned = false;
                const rawNowNs = () => BigInt(Math.round((performance.now() + performance.timeOrigin) * 200)) * 5000n;
                const guestClockNs = (clk) => {
                    const isRealtime = (clk === 0 || clk === 5); // REALTIME, REALTIME_COARSE
                    if (!clockOriginsAddr && typeof kernel_instance.exports.get_clock_origins === 'function') {
                        clockOriginsAddr = kernel_instance.exports.get_clock_origins();
                    }
                    if (clockOriginsAddr) {
                        const dv = new DataView(kernel_memory.buffer);
                        // SIGNED read: the origin (raw - clock) is legitimately negative
                        // whenever the wall clock is set ahead of this worker's raw clock
                        // (worker spawned after a host sleep, clock skew, …). Reading it
                        // as u64 turned e.g. -1h into +584y and python's time.time() died
                        // with "OverflowError: timestamp too large to convert to C
                        // _PyTime_t" (every logging import → pip unusable).
                        const origin = dv.getBigInt64(clockOriginsAddr + (isRealtime ? 8 : 0), true);
                        if (origin !== 0n) {
                            const ns = rawNowNs() - origin;
                            // Sanity clamp: REALTIME must land between 2020 and 2100,
                            // monotonic in [0, 100y). Anything else means the stored
                            // origin is garbage — fall back to host clocks instead of
                            // handing userspace an absurd timespec.
                            const lo = isRealtime ? 1577836800000000000n : 0n;
                            const hi = isRealtime ? 4102444800000000000n : 3155760000000000000n;
                            if (ns >= lo && ns < hi) return ns;
                            if (!clockClampWarned) {
                                clockClampWarned = true;
                                workerLog('clock: insane origin[' + (isRealtime ? 1 : 0) + ']=' + origin + ' ns=' + ns + ' — falling back to host clock');
                            }
                        }
                    }
                    // Kernel without origins support (or pre-initcall): legacy behavior.
                    return BigInt(Math.round((isRealtime ? Date.now() : performance.now()) * 1e6));
                };
                // console.log("instantiating with", memory);
                try {
                    // Emscripten-sjlj runtime: invoke_* wrappers and emscripten_longjmp.
                    // Required when user binaries are built with -mllvm --enable-emscripten-sjlj.
                    // The LLVM transform routes every call inside a setjmp scope through
                    // invoke_*(fn_idx, ...args) so longjmps can be caught here.
                    // emscripten_longjmp writes __THREW__/__threwValue into WASM TLS then throws
                    // a JS exception that invoke_* catches, after which WASM checks __THREW__.
                    const LONGJMP_SENTINEL = { type: 'longjmp' };
                    const inv = (fn, args) => {
                        try {
                            return instance.exports.__indirect_function_table.get(fn)(...args);
                        } catch (e) {
                            if (e !== LONGJMP_SENTINEL) throw e;
                        }
                    };
                    const env_sjlj = {
                        emscripten_longjmp: (buf, val) => {
                            // Prefer the runtime's exported setter (sjlj_rt.c
                            // __sjlj_set_threw): it writes the real TLS slots.
                            // The __get_tp fallback silently poked address 0
                            // when the binary didn't export it — longjmps were
                            // swallowed and control flow corrupted (ash spin).
                            if (instance.exports.__sjlj_set_threw) {
                                instance.exports.__sjlj_set_threw(buf, val);
                            } else {
                                const tp = instance.exports.__get_tp ? instance.exports.__get_tp() : 0;
                                const m32 = new Int32Array(memory.buffer);
                                m32[(tp + 0) >> 2] = buf; // __THREW__
                                m32[(tp + 4) >> 2] = val; // __threwValue
                            }
                            throw LONGJMP_SENTINEL;
                        },
                        // void invoke_*
                        invoke_v:      (f)             => { inv(f, []); },
                        invoke_vi:     (f,a)           => { inv(f, [a]); },
                        invoke_vii:    (f,a,b)         => { inv(f, [a,b]); },
                        invoke_viii:   (f,a,b,c)       => { inv(f, [a,b,c]); },
                        invoke_viiii:  (f,a,b,c,d)     => { inv(f, [a,b,c,d]); },
                        invoke_viiiii: (f,a,b,c,d,e)   => { inv(f, [a,b,c,d,e]); },
                        // i32-returning invoke_*
                        invoke_i:      (f)             => inv(f, []) ?? 0,
                        invoke_ii:     (f,a)           => inv(f, [a]) ?? 0,
                        invoke_iii:    (f,a,b)         => inv(f, [a,b]) ?? 0,
                        invoke_iiii:   (f,a,b,c)       => inv(f, [a,b,c]) ?? 0,
                        invoke_iiiii:  (f,a,b,c,d)     => inv(f, [a,b,c,d]) ?? 0,
                        invoke_iiiiii: (f,a,b,c,d,e)   => inv(f, [a,b,c,d,e]) ?? 0,
                    };
        // --- WALI host bridge: wali.SYS_* (x86-64 names) -> guest linux.syscall (asm-generic).
        //     Auto-generated; see toolchain/wali/. Number translation + legacy->modern *at()
        //     rewrites. TODO(next): host-side mmap/munmap/brk via memory.grow; LP64<->LP32
        //     struct translation (stat/etc.); real argv bridge. See toolchain/wali/README.md.
        function makeWaliImports_INLINE(kernel_instance) {
            const B = BigInt, sc = kernel_instance.exports.syscall;
            const n = (x) => (typeof x === 'bigint' ? Number(x) : x);
            const scv = (nr, args) => B(sc(nr, ...args.map(n)));
            const EXITGRP = 94;
            const wali = {
                __init: () => 0, __deinit: () => 0,
                __proc_exit: (code) => { sc(EXITGRP, n(code)); },
                __get_init_envfile: () => 0,
                __cl_get_argc: () => 1,
                __cl_get_argv_len: (i) => (Number(i)===0?6:0),
                __cl_copy_argv: (buf, i) => { if (Number(i)===0){const m=new Uint8Array(memory.buffer),s='rgtest';for(let k=0;k<6;k++)m[buf+k]=s.charCodeAt(k);m[buf+6]=0;} return 0; },
                SYS_accept: (...a) => scv(202, a),
                SYS_accept4: (...a) => scv(242, a),
                SYS_bind: (...a) => scv(200, a),
                SYS_chdir: (...a) => scv(49, a),
                SYS_chroot: (...a) => scv(51, a),
                SYS_clock_getres: (...a) => scv(114, a),
                SYS_clock_gettime: (...a) => scv(113, a),
                SYS_clock_nanosleep: (...a) => scv(115, a),
                SYS_close: (...a) => scv(57, a),
                SYS_connect: (...a) => scv(203, a),
                SYS_dup: (...a) => scv(23, a),
                SYS_dup3: (...a) => scv(24, a),
                SYS_epoll_create1: (...a) => scv(20, a),
                SYS_epoll_ctl: (...a) => scv(21, a),
                SYS_epoll_pwait: (...a) => scv(22, a),
                SYS_eventfd2: (...a) => scv(19, a),
                SYS_execve: (...a) => scv(221, a),
                SYS_exit: (...a) => scv(93, a),
                SYS_exit_group: (...a) => scv(94, a),
                SYS_faccessat: (...a) => scv(48, a),
                SYS_faccessat2: (...a) => scv(439, a),
                SYS_fchdir: (...a) => scv(50, a),
                SYS_fchmod: (...a) => scv(52, a),
                SYS_fchmodat: (...a) => scv(53, a),
                SYS_fchown: (...a) => scv(55, a),
                SYS_fchownat: (...a) => scv(54, a),
                SYS_fcntl: (...a) => scv(25, a),
                SYS_fdatasync: (...a) => scv(83, a),
                SYS_flock: (...a) => scv(32, a),
                SYS_fstat: (...a) => scv(80, a),
                SYS_fstatfs: (...a) => scv(44, a),
                SYS_fsync: (...a) => scv(82, a),
                SYS_ftruncate: (...a) => scv(46, a),
                SYS_futex: (...a) => scv(98, a),
                SYS_getcwd: (...a) => scv(17, a),
                SYS_getdents64: (...a) => scv(61, a),
                SYS_getegid: (...a) => scv(177, a),
                SYS_geteuid: (...a) => scv(175, a),
                SYS_getgid: (...a) => scv(176, a),
                SYS_getgroups: (...a) => scv(158, a),
                SYS_getpeername: (...a) => scv(205, a),
                SYS_getpgid: (...a) => scv(155, a),
                SYS_getpid: (...a) => scv(172, a),
                SYS_getppid: (...a) => scv(173, a),
                SYS_getrandom: (...a) => scv(278, a),
                SYS_getrlimit: (...a) => scv(163, a),
                SYS_getrusage: (...a) => scv(165, a),
                SYS_getsid: (...a) => scv(156, a),
                SYS_getsockname: (...a) => scv(204, a),
                SYS_getsockopt: (...a) => scv(209, a),
                SYS_gettid: (...a) => scv(178, a),
                SYS_gettimeofday: (...a) => scv(169, a),
                SYS_getuid: (...a) => scv(174, a),
                SYS_ioctl: (...a) => scv(29, a),
                SYS_kill: (...a) => scv(129, a),
                SYS_linkat: (...a) => scv(37, a),
                SYS_listen: (...a) => scv(201, a),
                SYS_lseek: (...a) => scv(62, a),
                SYS_madvise: (...a) => scv(233, a),
                SYS_mkdirat: (...a) => scv(34, a),
                SYS_mprotect: (...a) => scv(226, a),
                SYS_msync: (...a) => scv(227, a),
                SYS_nanosleep: (...a) => scv(101, a),
                SYS_newfstatat: (...a) => scv(79, a),
                SYS_openat: (...a) => scv(56, a),
                SYS_pipe2: (...a) => scv(59, a),
                SYS_ppoll: (...a) => scv(73, a),
                SYS_prctl: (...a) => scv(167, a),
                SYS_pread64: (...a) => scv(67, a),
                SYS_prlimit64: (...a) => scv(261, a),
                SYS_pselect6: (...a) => scv(72, a),
                SYS_pwrite64: (...a) => scv(68, a),
                SYS_read: (...a) => scv(63, a),
                SYS_readlinkat: (...a) => scv(78, a),
                SYS_readv: (...a) => scv(65, a),
                SYS_recvfrom: (...a) => scv(207, a),
                SYS_recvmsg: (...a) => scv(212, a),
                SYS_renameat2: (...a) => scv(276, a),
                SYS_rt_sigaction: (...a) => scv(134, a),
                SYS_rt_sigpending: (...a) => scv(136, a),
                SYS_rt_sigprocmask: (...a) => scv(135, a),
                SYS_rt_sigreturn: (...a) => scv(139, a),
                SYS_rt_sigsuspend: (...a) => scv(133, a),
                SYS_sched_getaffinity: (...a) => scv(123, a),
                SYS_sched_yield: (...a) => scv(124, a),
                SYS_sendmsg: (...a) => scv(211, a),
                SYS_sendto: (...a) => scv(206, a),
                SYS_set_robust_list: (...a) => scv(99, a),
                SYS_set_tid_address: (...a) => scv(96, a),
                SYS_setgid: (...a) => scv(144, a),
                SYS_setgroups: (...a) => scv(159, a),
                SYS_setitimer: (...a) => scv(103, a),
                SYS_setpgid: (...a) => scv(154, a),
                SYS_setregid: (...a) => scv(143, a),
                SYS_setresgid: (...a) => scv(149, a),
                SYS_setresuid: (...a) => scv(147, a),
                SYS_setreuid: (...a) => scv(145, a),
                SYS_setrlimit: (...a) => scv(164, a),
                SYS_setsid: (...a) => scv(157, a),
                SYS_setsockopt: (...a) => scv(208, a),
                SYS_setuid: (...a) => scv(146, a),
                SYS_shutdown: (...a) => scv(210, a),
                SYS_sigaltstack: (...a) => scv(132, a),
                SYS_socket: (...a) => scv(198, a),
                SYS_socketpair: (...a) => scv(199, a),
                SYS_statfs: (...a) => scv(43, a),
                SYS_statx: (...a) => scv(291, a),
                SYS_symlinkat: (...a) => scv(36, a),
                SYS_sysinfo: (...a) => scv(179, a),
                SYS_tkill: (...a) => scv(130, a),
                SYS_umask: (...a) => scv(166, a),
                SYS_uname: (...a) => scv(160, a),
                SYS_unlinkat: (...a) => scv(35, a),
                SYS_utimensat: (...a) => scv(88, a),
                SYS_wait4: (...a) => scv(260, a),
                SYS_write: (...a) => scv(64, a),
                SYS_writev: (...a) => scv(66, a),
                SYS_access: (...a) => scv(48, [-100, a[0], a[1], 0]),
                SYS_chmod: (...a) => scv(53, [-100, a[0], a[1], 0]),
                SYS_chown: (...a) => scv(54, [-100, a[0], a[1], a[2], 0]),
                SYS_dup2: (...a) => scv(24, [a[0], a[1], 0]),
                SYS_fork: (...a) => scv(220, [17, 0, 0, 0, 0]),
                SYS_link: (...a) => scv(37, [-100, a[0], -100, a[1], 0]),
                SYS_mkdir: (...a) => scv(34, [-100, a[0], a[1]]),
                SYS_open: (...a) => scv(56, [-100, ...a]),
                SYS_pipe: (...a) => scv(59, [a[0], 0]),
                SYS_readlink: (...a) => scv(78, [-100, ...a]),
                SYS_rename: (...a) => scv(276, [-100, a[0], -100, a[1], 0]),
                SYS_rmdir: (...a) => scv(35, [-100, a[0], 0x200]),
                SYS_symlink: (...a) => scv(36, [a[0], -100, a[1]]),
                SYS_unlink: (...a) => scv(35, [-100, a[0], 0]),
                SYS_brk: (...a) => B(-38),  // host-mem TODO
                SYS_eventfd: (...a) => B(-38),  // not in kernel
                SYS_fadvise: (...a) => B(-38),  // not in kernel
                SYS_lstat: (...a) => B(-38),  // not in kernel
                SYS_mmap: (...a) => B(-38),  // host-mem TODO
                SYS_mremap: (...a) => B(-38),  // host-mem TODO
                SYS_munmap: (...a) => B(-38),  // host-mem TODO
                SYS_pause: (...a) => B(-38),  // not in kernel
                SYS_poll: (...a) => B(-38),  // not in kernel
                SYS_select: (...a) => B(-38),  // not in kernel
                SYS_stat: (...a) => B(-38),  // not in kernel
            };
            const envExtra = { _Unwind_Backtrace: () => 0, _Unwind_GetIP: () => 0, _Unwind_GetIPInfo: () => 0 };
            return { wali, envExtra };
        }
                    const __wali = makeWaliImports_INLINE(kernel_instance);
                    instance = new WebAssembly.Instance(module, {
                        env: { memory, ...env_sjlj, ...__wali.envExtra },
                        wali: __wali.wali,
                        linux: {
                            syscall: (nr, arg0, arg1, arg2, arg3, arg4, arg5) => {
                                syscallLog(nr, 'sc nr=' + nr + ' a0=' + arg0 + ' a1=' + arg1 + ' a2=' + arg2 + ' a3=' + arg3);
                                // Intercept WASM-fork syscalls (9999=fork, 10000=vfork) before kernel.
                                if (nr === 9999 || nr === 10000) {
                                    if (!instance?.exports?.asyncify_get_state) {
                                        workerLog('sc nr=' + nr + ': not asyncify-transformed, ENOSYS');
                                        return -38; // ENOSYS
                                    }
                                    const state = instance.exports.asyncify_get_state();
                                    if (state === 0) {
                                        // Phase 1 (Normal): initiate asyncify unwind.
                                        //
                                        // Dynamic-buffer ABI (wasm_fork.c): arg2 === WASM_FORK_MAGIC
                                        // ('FORK') means arg0 is a caller-malloc'd buffer already sized to
                                        // THIS call's stack depth (arg3 bytes) with its header written. Use
                                        // it verbatim — it lives in the guest heap, so it can't collide
                                        // with anything and is unique per (nested) call. Legacy binaries
                                        // (old wasm_fork.c, arg2 !== MAGIC) pass a 128KB static buffer too
                                        // small for deep call stacks, so we override those with the
                                        // per-worker grown scratch region.
                                        const WASM_FORK_MAGIC = 0x464f524b; // 'FORK'
                                        let bufPtr, retPtr = arg1;
                                        if (arg2 === WASM_FORK_MAGIC) {
                                            bufPtr = arg0; // header + size already set up in C
                                        } else {
                                            const s = acquireForkScratch();
                                            bufPtr = s.bufPtr;
                                            const h = new Int32Array(memory.buffer);
                                            h[bufPtr >> 2]       = bufPtr + 8;      // cursor
                                            h[(bufPtr >> 2) + 1] = bufPtr + s.size; // end
                                        }
                                        pendingFork = { bufPtr, retPtr, vfork: nr === 10000 };
                                        console.log('[FORK_INIT:' + (self.name||'?') + '] nr=' + nr + ' dyn=' + (arg2===WASM_FORK_MAGIC) + ' bufPtr=0x' + bufPtr.toString(16) + ' sz=' + (arg2===WASM_FORK_MAGIC?arg3:FORK_SCRATCH_SIZE) + ' retPtr=0x' + retPtr.toString(16) + ' memBytes=' + memory.buffer.byteLength);
                                        instance.exports.asyncify_start_unwind(bufPtr);
                                        return 0;
                                    } else if (state === 2) {
                                        // Phase 3 (Rewinding): stop rewind, return fork result.
                                        // retval address is arg1 (guest-provided), not the scratch
                                        // stash — but clear the stash a fork child got in switch_entry.
                                        activeForkBuf = null;
                                        instance.exports.asyncify_stop_rewind();
                                        return new Int32Array(memory.buffer)[arg1 >> 2];
                                    }
                                    return -38; // ENOSYS (unexpected asyncify state)
                                }
                                // Intercept SYS_clone(SIGCHLD,0) — wasm-stubs.c fork() path for asyncified
                                // binaries (e.g. dropbear built with wasm-stubs.c instead of wasm_fork.c).
                                // These don't provide an asyncify buffer, so we use the per-worker
                                // grown scratch region (4 MB — deeply-nested hush/busybox fork chains
                                // add ~100-200 KB of asyncify call-stack data per nesting level).
                                if (nr === 220 && arg0 === 17 && arg1 === 0 && instance?.exports?.asyncify_get_state) {
                                    const state = instance.exports.asyncify_get_state();
                                    if (state === 0) {
                                        // Phase 1 (Normal): initialize asyncify buffer header and start unwind
                                        const s = acquireForkScratch();
                                        const bufPtr = s.bufPtr, retPtr = s.retPtr;
                                        const h = new Int32Array(memory.buffer);
                                        h[bufPtr >> 2] = bufPtr + 8;            // cursor = start of data
                                        h[(bufPtr >> 2) + 1] = bufPtr + s.size; // end of data
                                        pendingFork = { bufPtr, retPtr, vfork: false };
                                        activeForkBuf = { bufPtr, retPtr, size: s.size };
                                        instance.exports.asyncify_start_unwind(bufPtr);
                                        return 0;
                                    } else if (state === 2 && activeForkBuf !== null) {
                                        // Phase 3 (Rewinding): stop rewind, return fork result written by
                                        // handler. Addresses come from the stash (parent: set at unwind;
                                        // child: set at switch_entry) — NOT recomputed from byteLength.
                                        const ab = activeForkBuf;
                                        activeForkBuf = null;
                                        const used = new Int32Array(memory.buffer)[ab.bufPtr >> 2] - (ab.bufPtr + 8);
                                        workerLog('fork rewind: asyncify stack used=' + used + ' bytes');
                                        instance.exports.asyncify_stop_rewind();
                                        return new Int32Array(memory.buffer)[ab.retPtr >> 2];
                                    }
                                    // Fall through to kernel for unexpected asyncify states
                                }
                                // Intercept SYS_clone with CLONE_VFORK (0x4000) — BusyBox NOMMU subshell spawn.
                                // BusyBox hush uses clone(fn=N, fn_arg=0, CLONE_VM|CLONE_VFORK|SIGCHLD) to spawn
                                // $() subshells. The child must resume from after the clone() return point (retval=0),
                                // not from _start() — same asyncify unwind/rewind as the wasm-stubs.c fork path.
                                if (nr === 220 && (arg2 & 0x4000) !== 0 && instance?.exports?.asyncify_get_state) {
                                    const state = instance.exports.asyncify_get_state();
                                    if (state === 0) {
                                        // Phase 1 (Normal): initialize asyncify buffer header and start unwind.
                                        // Save nommuFn/nommuFnArg so the fork handler can pass them to the
                                        // kernel — the child must run fn(fn_arg) natively (NOMMU semantics),
                                        // NOT the asyncify rewind path (which saves 0 bytes and replays
                                        // _start(), landing in the wrong code path for exec'd children).
                                        const s = acquireForkScratch();
                                        const bufPtr = s.bufPtr, retPtr = s.retPtr;
                                        const h = new Int32Array(memory.buffer);
                                        h[bufPtr >> 2] = bufPtr + 8;
                                        h[(bufPtr >> 2) + 1] = bufPtr + s.size;
                                        pendingFork = { bufPtr, retPtr, vfork: true, nommuFn: arg0, nommuFnArg: arg1 };
                                        activeForkBuf = { bufPtr, retPtr, size: s.size };
                                        workerLog('nommu-fork: CLONE_VFORK intercept fn=' + arg0 + ' flags=0x' + arg2.toString(16) + ' buf=0x' + bufPtr.toString(16) + ' starting unwind');
                                        instance.exports.asyncify_start_unwind(bufPtr);
                                        return 0;
                                    } else if (state === 2 && activeForkBuf !== null) {
                                        // Phase 3 (Rewinding): stop rewind, return fork result written by
                                        // handler. Addresses from the stash — see the fork branch above.
                                        const ab = activeForkBuf;
                                        activeForkBuf = null;
                                        const used = new Int32Array(memory.buffer)[ab.bufPtr >> 2] - (ab.bufPtr + 8);
                                        workerLog('nommu-fork rewind: asyncify stack used=' + used + ' bytes');
                                        instance.exports.asyncify_stop_rewind();
                                        return new Int32Array(memory.buffer)[ab.retPtr >> 2];
                                    }
                                    // Fall through to kernel for unexpected asyncify states
                                }
                                // pthread-style clone (CLONE_THREAD, 0x10000) goes straight to the
                                // kernel with UNMODIFIED flags. musl's wasm32 __clone passes args in
                                // the kernel's custom (fn, arg, flags, ptid, ctid, tls) order, and
                                // with thread workers entering the kernel via task_entry the kernel
                                // handles PARENT_SETTID / CHILD_CLEARTID (join wakeups) itself.
                                // The old shim stripped those flags and poked tids from JS, which
                                // broke pthread_join and left stale lock owners.
                                // Intercept SYS_clock_gettime (403) — kernel's copy_to_user for clock_gettime
                                // crashes with RuntimeError: memory access out of bounds for specific stack
                                // addresses (e.g., 773872). This shim writes the timespec directly to user
                                // memory, bypassing the kernel's copy path — but it MUST report the kernel's
                                // own clocks (via the get_monotonic_ns/get_real_ns vmlinux exports), not
                                // Date.now()/performance.now(): absolute deadlines that userspace computes
                                // from these values flow back into the kernel (clock_nanosleep TIMER_ABSTIME,
                                // hrtimer-based poll timeouts), and each worker's performance.now() has a
                                // different origin than the kernel's monotonic clock, which made every such
                                // deadline appear to be in the past (timers fired immediately).
                                if (nr === 403) { // clock_gettime64(clockid, timespec*)
                                    if (arg1 && memory) {
                                        const ns = guestClockNs(arg0);
                                        const view = new DataView(memory.buffer);
                                        view.setBigInt64(arg1,     ns / 1000000000n, true); // little-endian
                                        view.setBigInt64(arg1 + 8, ns % 1000000000n, true);
                                    }
                                    return 0;
                                }
                                // Intercept SYS_sigaltstack (132) — kernel hits unreachable for WASM processes.
                                // Clang calls sigaltstack(NULL, &old_ss) during musl init to query the current
                                // altstack. Return SS_DISABLE (2) in old_ss and succeed.
                                if (nr === 132) {
                                    if (arg1) { // uoss != NULL: write {ss_sp=0, ss_flags=SS_DISABLE=2, ss_size=0}
                                        const u32 = new Uint32Array(memory.buffer);
                                        u32[arg1 >> 2]       = 0; // ss_sp
                                        u32[(arg1 >> 2) + 1] = 2; // ss_flags = SS_DISABLE
                                        u32[(arg1 >> 2) + 2] = 0; // ss_size
                                    }
                                    workerLog('sc nr=132 ret=0 (sigaltstack shim)');
                                    return 0;
                                }
                                // Intercept SYS_sched_yield (159) — some busy userland paths
                                // expect this to exist; ENOSYS can create noisy retry loops.
                                if (nr === 159) {
                                    return 0;
                                }
                                // Intercept SYS_setgid (144) — OpenSSH session setup calls this
                                // while handling an accepted connection. The kernel path currently
                                // returns ENOSYS, which causes sshd-session to abort the handshake.
                                // Treat it as successful in the WASM guest environment.
                                if (nr === 144) {
                                    workerLog('sc nr=144 ret=0 (setgid shim)');
                                    return 0;
                                }
                                // Intercept SYS_setresgid (149) — OpenSSH session setup reaches
                                // this after authentication and exits with code 255 if ENOSYS.
                                // Returning success keeps the authenticated session alive.
                                if (nr === 149) {
                                    workerLog('sc nr=149 ret=0 (setresgid shim)');
                                    return 0;
                                }
                                // Intercept SYS_setresuid (147) — OpenSSH does uid/gid credential
                                // transitions during session setup and exits if this is ENOSYS.
                                if (nr === 147) {
                                    workerLog('sc nr=147 ret=0 (setresuid shim)');
                                    return 0;
                                }
                                // Thread-clone children can hit kernel-side signal-bookkeeping traps on
                                // rt_sigprocmask(). Handle all thread-clone-child calls in userspace and
                                // provide a zeroed old mask when requested.
                                if (nr === 135 && isThreadCloneChild?.()) {
                                    const sigsetSize = (arg3 > 0) ? Math.min(arg3 | 0, 128) : 16;
                                    if (arg2 && memory) {
                                        if (arg2 < 0 || (arg2 + sigsetSize) > memory.buffer.byteLength) {
                                            workerLog('sigmask shim: nr=135 thread-clone child oldset EFAULT old=' + arg2 + ' size=' + sigsetSize);
                                            return -14; // EFAULT
                                        }
                                        new Uint8Array(memory.buffer, arg2, sigsetSize).fill(0);
                                    }
                                    workerLog('sigmask shim: nr=135 thread-clone child how=' + arg0 + ' set=' + arg1 + ' old=' + arg2 + ' size=' + sigsetSize + ' -> ret=0');
                                    return 0;
                                }
                                // Intercept SYS_getrandom (278) — startup-critical for Python/OpenSSL.
                                // Some runtimes expect getrandom to be reliably available very early.
                                // Fill userspace buffer from Web Crypto and return the number of bytes.
                                if (nr === 278) { // getrandom(buf, buflen, flags)
                                    if (!arg0 || arg1 < 0 || !memory) {
                                        return -22; // EINVAL
                                    }
                                    const max = memory.buffer.byteLength - arg0;
                                    if (max < 0) {
                                        return -14; // EFAULT
                                    }
                                    const len = Math.min(arg1, max);
                                    const out = new Uint8Array(memory.buffer, arg0, len);
                                    // getRandomValues rejects SharedArrayBuffer-backed views and has
                                    // a 65536-byte per-call cap, so fill a temporary ArrayBuffer and copy.
                                    if (typeof self.crypto?.getRandomValues === 'function') {
                                        for (let off = 0; off < len; off += 65536) {
                                            const n = Math.min(65536, len - off);
                                            const tmp = new Uint8Array(n);
                                            self.crypto.getRandomValues(tmp);
                                            out.set(tmp, off);
                                        }
                                    } else {
                                        // Fallback keeps process alive in non-crypto environments.
                                        for (let i = 0; i < len; i++) out[i] = (Math.random() * 256) | 0;
                                    }
                                    workerLog('sc nr=278 ret=' + len + ' (getrandom shim)');
                                    return len;
                                }
                                // SYS_futex (98) is handled by the kernel: CONFIG_FUTEX=y.
                                // The former JS Atomics.wait shim blocked the worker while the
                                // kernel still considered the task running — on this 1-CPU guest
                                // that parked the only CPU token and deadlocked pthread handshakes
                                // (parent waiting on the futex, child waiting for a CPU). Kernel
                                // futex waits release the CPU through the scheduler like any other
                                // blocking syscall.
                                // Sleep syscalls from pthread-clone children must be handled in JS:
                                // these workers run user code via switch_entry without entering the
                                // kernel's task context (fn=62), so kernel-side current==NULL and
                                // do_nanosleep sees t->task==NULL — "already woken" — returning 0
                                // immediately, which turns every timed wait into a 100% CPU spin.
                                // Atomics.wait blocks just this worker (= this thread), which is the
                                // correct semantic. Deadline math uses the kernel's own clocks via
                                // the get_monotonic_ns/get_real_ns vmlinux exports.
                                //   nr 101 = nanosleep_time32(req, rem)         — relative
                                //   nr 115 = clock_nanosleep_time32(clk, flags, req, rem)
                                // LOT 2026-09-02: this JS sleep shim dates from the old model where
                                // thread children ran OUTSIDE the kernel's task context. pthread
                                // clones are real kernel tasks now (task_entry fn=62), so a thread
                                // that sleeps here in Atomics.wait never re-enters the scheduler
                                // properly: a daemon thread doing time.sleep(N) never resumed (pure-
                                // Python repro: main busy 25 s, thread sleep(12) — R-WOKE never
                                // printed), which froze every WebFuse start (its transcode reaper
                                // thread sleeps 30 s at import). Let the kernel handle nanosleep
                                // for threads like any task; the shim is kept for reference only.
                                const LOT_THREAD_SLEEP_SHIM = false;
                                if (LOT_THREAD_SLEEP_SHIM && (nr === 101 || nr === 115) && isThreadCloneChild?.() && memory) {
                                    const reqPtr = (nr === 101) ? arg0 : arg2;
                                    const i32t = new Int32Array(memory.buffer);
                                    const sec = i32t[reqPtr >> 2];
                                    const nsec = i32t[(reqPtr >> 2) + 1];
                                    if (nsec < 0 || nsec >= 1000000000) return -22; // EINVAL
                                    let waitNs = BigInt(sec) * 1000000000n + BigInt(nsec);
                                    const abstime = (nr === 115) && (arg1 & 1) !== 0;
                                    if (abstime) {
                                        waitNs -= guestClockNs(arg0);
                                    }
                                    if (waitNs > 0n) {
                                        const ms = Number(waitNs / 1000000n);
                                        const scratch = new Int32Array(new SharedArrayBuffer(4));
                                        Atomics.wait(scratch, 0, 0, Math.min(ms, 0x7fffffff));
                                    }
                                    return 0;
                                }
                                // Track userspace clock-setting so the published clock origins stay
                                // valid. rcS sets the wall clock at boot (date -s @lot_epoch); the
                                // kernel's wasm_clock_origins[1] (raw - CLOCK_REALTIME) was computed
                                // at device_initcall time with the 1970 wall clock, so recompute it
                                // here in pure JS from the timespec userspace passed. Kernel-side
                                // settimeofday-at-initcall is NOT an option: it breaks inbound TCP
                                // (injected connections stall in SYN-RECV).
                                //   nr 112 = clock_settime(clkid, old_timespec32*)  — musl uses this
                                //            when the seconds fit in 32 bits (i.e. always, until 2038)
                                //   nr 404 = clock_settime64(clkid, timespec64*)
                                if ((nr === 112 || nr === 404) && arg0 === 0 && arg1 && memory) {
                                    const retSet = kernel_instance.exports.syscall(nr, arg0, arg1, arg2, arg3, arg4, arg5);
                                    if (!clockOriginsAddr && typeof kernel_instance.exports.get_clock_origins === 'function') {
                                        clockOriginsAddr = kernel_instance.exports.get_clock_origins();
                                    }
                                    if (retSet === 0 && clockOriginsAddr) {
                                        const udv = new DataView(memory.buffer);
                                        const wallNs = (nr === 112)
                                            ? BigInt(udv.getInt32(arg1, true)) * 1000000000n + BigInt(udv.getInt32(arg1 + 4, true))
                                            : udv.getBigInt64(arg1, true) * 1000000000n + udv.getBigInt64(arg1 + 8, true);
                                        // Signed write to match the signed read above — the origin is
                                        // negative whenever the wall clock is set ahead of raw.
                                        new DataView(kernel_memory.buffer).setBigInt64(clockOriginsAddr + 8, rawNowNs() - wallNs, true);
                                        workerLog('clock_settime: origins[1] resynced, wall=' + wallNs);
                                    }
                                    return retSet;
                                }
                                // epoll (nr 19/20/21/22/441) is handled by the kernel: CONFIG_EPOLL=y.
                                // The former JS epoll shim (fake fds, all-fds-always-ready) is gone —
                                // it made non-blocking accept/read loops spin on EAGAIN, starving the
                                // cooperative kernel, and never honored epoll_pwait timeouts.
                                // Track ftruncate(fd, size) — the last one before a renameat is
                                // the output file being prepared by LLD's OnDiskBuffer.
                                if (nr === 46 && arg0 >= 3 && arg1 >= 8) {
                                    pendingWasmOutput = { fd: arg0, size: arg1 };
                                    workerLog('wasm-fix: tracking ftruncate fd=' + arg0 + ' size=' + arg1);
                                }
                                // At renameat time: LLD's OnDiskBuffer has written WASM content
                                // into a linear-memory buffer (via musl's MAP_PRIVATE mmap) but
                                // NOT to the file. Scan linear memory for the valid WASM module
                                // and pwrite64 it to the fd before the rename completes.
                                if (nr === 38 && pendingWasmOutput && memory) {
                                    const { fd: outFd, size: outSize } = pendingWasmOutput;
                                    pendingWasmOutput = null;
                                    const u8 = new Uint8Array(memory.buffer);
                                    // Start scan from __heap_base (skip static data section).
                                    const heapBase = instance?.exports?.__heap_base?.value ?? 0;
                                    const foundAddr = findValidWasm(u8, outSize, heapBase);
                                    if (foundAddr >= 0) {
                                        // pwrite64(fd, buf_addr, count, offset=0): write at file start
                                        const pret = kernel_instance.exports.syscall(68, outFd, foundAddr, outSize, 0, 0, 0);
                                        workerLog('wasm-fix: pwrite64 fd=' + outFd + ' addr=0x' + foundAddr.toString(16) + ' size=' + outSize + ' ret=' + pret);
                                    } else {
                                        workerLog('wasm-fix: WASM magic not found, heapBase=0x' + heapBase.toString(16) + ' memSize=' + u8.length + ' outSize=' + outSize);
                                    }
                                }
                                const original_instance = instance;
                                const ret = kernel_instance.exports.syscall(nr, arg0, arg1, arg2, arg3, arg4, arg5);
                                syscallLog(nr, 'sc nr=' + nr + ' ret=' + ret);
                                if (instance !== original_instance) {
                                    // if the instance changed, then this was the exec syscall,
                                    // so call into the new instance:
                                    call_entry = call_start;
                                    // and we never want to return to the caller of the syscall, so
                                    // skip straight to the catch block of the parent's call_entry
                                    throw HALT_USER;
                                }
                                return ret;
                            },
                            get_thread_area: kernel_instance.exports.get_thread_area,
                            get_args_length: kernel_instance.exports.get_args_length,
                            get_args: kernel_instance.exports.get_args,
                        },
                    });
                    if ("memory" in instance.exports) {
                        assert(instance.exports.memory instanceof WebAssembly.Memory);
                        // Always use the actual exported memory for syscall read/write.
                        // If it's non-shared, get_user_memory() returns null so spawn_worker
                        // won't try to postMessage a non-transferable ArrayBuffer.
                        memory = instance.exports.memory;
                    }
                }
                catch (error) {
                    console.log("error instantiating user module:", String(error));
                }
            },
            call() {
                workerLog('call() starting');
                for (;;) {
                    try {
                        call_entry();
                    }
                    catch (error) {
                        if (error === HALT_USER)
                            continue;
                        if (error === HALT_KERNEL)
                            throw error;
                        // Asyncify fork unwind is expected control flow: recover parent and spawn child.
                        const asyncState = instance?.exports?.asyncify_get_state?.() ?? -1;
                        if (pendingFork !== null && asyncState === 1) {
                            const fork = pendingFork;
                            pendingFork = null;
                            instance.exports.asyncify_stop_unwind();
                            // Copy user memory for the child (both fork and vfork copy for safety).
                            // maximum MUST be 4096 (256MB), matching the initial-process memory
                            // above — NOT `pages` (the parent's current size). With
                            // initial==maximum, memory.grow always returns -1, so a forked child
                            // that needs to extend its heap (e.g. `Xvfb &` execs a 7MB binary that
                            // allocates a framebuffer + font caches) traps on the first grow,
                            // silently killing the worker while it still holds the 1-CPU token —
                            // which froze the whole guest (parent shell included). Small children
                            // (vnc-server, sleep) fit under the parent's size so never hit it.
                            const pages = memory.buffer.byteLength >>> 16;
                            const childMem = new WebAssembly.Memory({ initial: pages, maximum: 4096, shared: true });
                            new Uint8Array(childMem.buffer).set(new Uint8Array(memory.buffer));
                            // Override get_user_memory so the kernel's spawn_worker passes childMem
                            const SYS_CLONE = 220, SIGCHLD = 17;
                            let childPid;
                            try {
                                if (fork.vfork && fork.nommuFn != null && fork.nommuFnArg !== 0) {
                                    // NOMMU exec-type child: fn_arg≠0 points to exec-setup struct.
                                    // Child runs nommuFn(nommuFnArg) natively — nommuFn calls execve internally.
                                    // Use null fork params so child takes the fn≠0 native path (not asyncify rewind).
                                    // Child memory is a copy of parent at fork time (correct CLONE_VM semantics).
                                    setForkOverride(childMem, null);
                                    childPid = get_kernel_instance().exports.syscall(SYS_CLONE, fork.nommuFn, fork.nommuFnArg, SIGCHLD, 0, 0, 0);
                                } else {
                                    // Regular fork OR NOMMU subshell-type child (fn_arg=0):
                                    // Use asyncify rewind so clone() returns 0 in the child and hush
                                    // continues executing the subshell command (e.g. $(...) substitution).
                                    setForkOverride(childMem, { bufPtr: fork.bufPtr, retPtr: fork.retPtr });
                                    childPid = get_kernel_instance().exports.syscall(SYS_CLONE, 0, 0, SIGCHLD, 0, 0, 0);
                                }
                            }
                            finally {
                                clearForkOverride();
                            }
                            workerLog('fork: kernel sys_clone → childPid=' + childPid + (fork.vfork ? ' nommuFn=' + fork.nommuFn : ''));
                            // Rewind parent: fork() returns childPid (or negative errno on failure)
                            new Int32Array(memory.buffer)[fork.retPtr >> 2] = childPid;
                            instance.exports.asyncify_start_rewind(fork.bufPtr);
                            continue;
                        }
                        // Diagnostic: log non-HALT throws that were not handled as unwind flow.
                        const _hasPending = pendingFork !== null;
                        console.log('[FORK_DIAG:' + (self.name||'?') + '] err=' + String(error).slice(0,80) + ' pendingFork=' + _hasPending + ' asyncState=' + asyncState);
                        workerLog('fork_diag pendingFork=' + _hasPending + ' asyncState=' + asyncState + ' err=' + String(error).slice(0,80));
                        workerLog('call() error: ' + String(error));
                        workerLog('call() stack: ' + (error?.stack ?? 'no stack'));
                        // Always emit the stack (wasm frame names included) to the console,
                        // not just behind ?debuglog: user-process crashes that surface as
                        // "Segmentation fault" in the guest (e.g. pip's sporadic install-time
                        // crash) are unreproducible-on-demand, so the one time they DO fire
                        // must capture where. Truncated to keep the console readable.
                        console.log('[WORKER:' + (self.name||'?') + '] error running user module:', String(error), '| pendingFork='+!!pendingFork+' asyncify_state='+(instance?.exports?.asyncify_get_state?.() ?? 'N/A'), '\nstack:', String(error?.stack ?? 'no stack').slice(0, 2000));
                        return;
                    }
                }
            },
            switch_entry(fn, arg) {
                // Dump fn_arg memory to help debug pipe fd setup
                if (parent_memory && arg > 0 && arg < parent_memory.buffer.byteLength - 64) {
                    const mem = new Int32Array(parent_memory.buffer);
                    const base = arg >> 2;
                    const sub = mem[base] >> 2; // fn_arg[0] is a pointer, load the sub-struct
                    let dump = 'switch_entry fn=' + fn + ' arg=' + arg;
                    dump += ' fnarg=[';
                    for (let i = 0; i < 8; i++) dump += mem[base + i] + ',';
                    dump += ']';
                    if (sub > 0 && sub < parent_memory.buffer.byteLength/4 - 12) {
                        dump += ' sub=[';
                        for (let i = 0; i < 12; i++) dump += mem[sub + i] + ',';
                        dump += ']';
                    }
                    workerLog(dump);
                } else {
                    workerLog('switch_entry fn=' + fn + ' arg=' + arg);
                }
                // This is called if this thread was created by a clone call,
                // and therefore we our entrypoint is a user-specified function.
                // Our custom variant of the clone syscall spawns a worker that calls
                // switch_entry, then immediately calls instantiate.
                assert(parent_module);
                assert(parent_memory);
                module = parent_module;
                memory = parent_memory;
                // Fork child: bypass the thread entry function entirely and instead
                // do an asyncify rewind back to the fork() syscall return point.
                // forkRewindState was set from the fork_bufPtr/fork_retPtr in the worker message.
                if (forkRewindState !== null) {
                    const rs = forkRewindState;
                    forkRewindState = null;
                    // Child's rewind re-enters the clone intercept at state===2, which
                    // reads the buffer/retval addresses from activeForkBuf (they are
                    // parent-scratch addresses, valid in this child's memory copy but
                    // NOT recomputable from byteLength).
                    activeForkBuf = { bufPtr: rs.bufPtr, retPtr: rs.retPtr, size: 0 };
                    workerLog('switch_entry: fork child rewind bufPtr=0x' + rs.bufPtr.toString(16) + ' retPtr=0x' + rs.retPtr.toString(16));
                    call_entry = () => {
                        call_entry = call_start; // reset for subsequent iterations
                        assert(instance);
                        // Child: fork() must return 0
                        new Int32Array(memory.buffer)[rs.retPtr >> 2] = 0;
                        // Rewind the WASM stack back into fork()'s syscall return path.
                        // The syscall handler (state=Rewinding) will call asyncify_stop_rewind()
                        // and return m32[retPtr>>2] = 0.
                        instance.exports.asyncify_start_rewind(rs.bufPtr);
                        call_start();
                    };
                    return;
                }
                call_entry = () => {
                    // Reset call_entry to call_start so the next for(;;) iteration
                    // runs the real userspace program (_start). For NOMMU clone, fn
                    // points to a lightweight hook (e.g. func[882]) that just returns 0;
                    // the child's actual program runs on the subsequent call_start() call.
                    call_entry = call_start;
                    assert(instance);
                    const { __indirect_function_table } = instance.exports;
                    assert(__indirect_function_table instanceof WebAssembly.Table, "Invalid function table");
                    const f = __indirect_function_table.get(fn);
                    assert(typeof f === "function" && f.length === 1, "Invalid function signature");
                    workerLog('call_entry calling fn=' + fn);
                    f(arg);
                    // f(arg) returned normally — for NOMMU clone this is expected (the hook
                    // just returns 0). The for(;;) loop will now call call_start() which
                    // runs the child's _start(). For any other fn, returning without exit
                    // is a bug, but do_exit(SIGSEGV) will fire after wasm_user_call() returns.
                    workerLog('call_entry fn=' + fn + ' returned normally, proceeding to call_start');
                };
            },
            // signal handling:
            call_signal_handler(fn, sig) {
                assert(instance);
                const { __indirect_function_table } = instance.exports;
                assert(__indirect_function_table instanceof WebAssembly.Table, "Invalid function table");
                const f = __indirect_function_table.get(fn);
                assert(typeof f === "function" && f.length === 1, "Invalid function signature");
                f(sig); // TODO: the siginfo overload
            },
            // memory:
            // uaccess between the kernel wasm memory and the shared USER memory.
            //
            // Coherency note: user memory is a SharedArrayBuffer that userspace
            // (musl) mutates with wasm ATOMIC ops (i32.atomic.*). The wasm/JS
            // shared-memory model does NOT guarantee that a plain, non-atomic
            // access observes the latest value an atomic store in another agent
            // wrote. The kernel's futex machinery depends on exactly that: its
            // value-check (futex_get_value_locked) reads the 4-byte futex word,
            // and futex correctness requires it to be coherent with userspace's
            // atomic store to that word. A plain Uint8Array copy could read a
            // STALE word — e.g. musl cond_signal's a_swap(barrier,0) not yet seen
            // — so the kernel enqueues a waiter for a wake that already landed:
            // a lost wakeup that deadlocked every pthread cond / threading.Event
            // handoff once two threads blocked concurrently (see local/sched-debug).
            // So: aligned word-sized transfers go through Atomics (seq-cst),
            // keeping the kernel's view of futex/tid words coherent with musl.
            // Bulk copies (the common case: I/O buffers) are unaffected.
            read(to, from, n) {
                assert(memory);
                if (n === 4 && (from & 3) === 0 && (to & 3) === 0) {
                    Atomics.store(new Int32Array(kernel_memory.buffer), to >> 2,
                        Atomics.load(new Int32Array(memory.buffer), from >> 2));
                    return 0;
                }
                const slice = new Uint8Array(memory.buffer, from, n);
                kernel_memory_buffer.set(slice, to);
                return n - slice.length;
            },
            write(to, from, n) {
                assert(memory);
                const slice = kernel_memory_buffer.subarray(from, from + n);
                new Uint8Array(memory.buffer, to, n).set(slice);
                return n - slice.length;
            },
            write_zeroes(to, n) {
                assert(memory);
                const slice = new Uint8Array(memory.buffer, to, n);
                slice.fill(0);
                return n - slice.length;
            },
        },
    };
}
self.onmessage = (event) => {
    const { fn, arg, vmlinux, memory, parent_user_module, parent_user_memory, fork_bufPtr = null, fork_retPtr = null, thread_entry_fn = null, thread_entry_arg = null, debuglog = false } = event.data;
    // debuglog is either false, true (trace everything), or a list of syscall
    // numbers to restrict the trace to.
    LOG_ENABLED = !!debuglog;
    LOG_SYSCALL_FILTER = Array.isArray(debuglog) && debuglog.length
        ? new Set(debuglog)
        : null;
    console.log('[WORKER_EARLY] start name=' + self.name + ' fn=' + fn + ' has_parent_user=' + (parent_user_module != null) + ' fork=' + (fork_bufPtr != null));
    workerLog('start fn=' + fn + ' has_parent_user=' + (parent_user_module != null) + ' fork=' + (fork_bufPtr != null));
    // Shared state between user_imports' call() and the kernel spawn_worker callback.
    // During a fork(), call() sets these before calling kernel sys_clone so that
    // get_user_memory() returns the child's memory copy to the kernel's spawn_worker.
    let forkChildMemory = null;
    let forkSpawnParams = null;
    let pendingThreadClone = null;
    let suppressNextFutexWait = false;
    let threadCloneChildActive = thread_entry_fn != null;
    workerLog('start: creating user imports');
    const user = user_imports({
        kernel_memory: memory,
        get_kernel_instance: () => instance,
        parent_user_module,
        parent_user_memory,
        fork_bufPtr,
        fork_retPtr,
        setForkOverride(childMem, params) {
            forkChildMemory = childMem;
            forkSpawnParams = params;
        },
        clearForkOverride() {
            forkChildMemory = null;
            forkSpawnParams = null;
        },
        setThreadCloneOverride(params) {
            pendingThreadClone = params;
        },
        clearThreadCloneOverride() {
            pendingThreadClone = null;
        },
        setSuppressNextFutexWait() {
            suppressNextFutexWait = true;
        },
        consumeSuppressNextFutexWait() {
            const v = suppressNextFutexWait;
            suppressNextFutexWait = false;
            return v;
        },
        isThreadCloneChild() {
            return threadCloneChildActive;
        },
    });
    workerLog('start: user imports ready');
    workerLog('start: creating kernel imports');
    const imports = {
        env: { memory },
        boot: {
            get_devicetree: unavailable,
            get_initramfs: unavailable,
        },
        user: user.imports,
        kernel: kernel_imports({
            is_worker: true,
            memory,
            spawn_worker(fn, arg, name, user_module, user_memory) {
                const mem_shared = user_memory ? (user_memory.buffer instanceof SharedArrayBuffer) : null;
                workerLog('spawn_worker name=' + name + ' fn=' + fn + ' has_user_mem=' + (user_memory != null) + ' shared=' + mem_shared + ' fork=' + (forkSpawnParams != null));
                // pthread-style clones now go through the NORMAL kernel path: the
                // worker runs task_entry (fn=62), waits for a CPU token, runs
                // schedule_tail, and the kernel's wasm_call_clone_fn drives
                // user.switch_entry(entryFn, entryArg) with a real task context.
                // The old JS hijack (thread_entry_fn handoff, running user code
                // directly) left a phantom runnable kernel task that could be
                // handed a CPU token nobody would ever yield back — after which
                // the parent's next blocking syscall wedged the whole guest.
                if (pendingThreadClone && fn === 62) pendingThreadClone = null;
                postMessage({
                    type: "spawn_worker",
                    fn,
                    arg,
                    name,
                    user_module,
                    user_memory,
                    // Include fork params so child worker knows to do asyncify rewind
                    fork_bufPtr: forkSpawnParams?.bufPtr ?? null,
                    fork_retPtr: forkSpawnParams?.retPtr ?? null,
                    thread_entry_fn: null,
                    thread_entry_arg: null,
                });
            },
            boot_console_write(message) {
                postMessage({ type: "boot_console_write", message });
            },
            boot_console_close() {
                postMessage({ type: "boot_console_close" });
            },
            run_on_main(fn, arg) {
                postMessage({ type: "run_on_main", fn, arg });
            },
            get_user_module() {
                return user.module;
            },
            get_user_memory() {
                // During a fork(), return the child's memory copy instead of parent's.
                if (forkChildMemory) return forkChildMemory;
                // Only return memory if it's a SharedArrayBuffer; non-shared
                // memory cannot be transferred via postMessage (DataCloneError).
                const m = user.memory;
                if (!m || !(m.buffer instanceof SharedArrayBuffer)) return null;
                return m;
            },
        }),
        virtio: {
            set_features: unavailable,
            setup: unavailable,
            enable_vring: unavailable,
            disable_vring: unavailable,
            notify: unavailable,
        },
    };
    workerLog('start: imports ready, instantiating vmlinux');
    const instance = new WebAssembly.Instance(vmlinux, imports);
    if (thread_entry_fn != null) {
        workerLog('start: thread clone direct switch_entry fn=' + thread_entry_fn + ' arg=' + thread_entry_arg);
        try {
            user.imports.switch_entry(thread_entry_fn, thread_entry_arg ?? 0);
            user.imports.instantiate();
            user.imports.call();
        }
        catch (error) {
            if (error === HALT_KERNEL)
                return;
            console.error('[WORKER_FATAL] name=' + self.name + ' thread_fn=' + thread_entry_fn + ' err=' + error);
            if (error?.stack) console.error('[WORKER_FATAL_STACK] ' + error.stack);
            return;
        }
        threadCloneChildActive = false;
        return;
    }
    workerLog('start: vmlinux instantiated, invoking fn=' + fn);
    try {
        instance.exports.__indirect_function_table.get(fn)(arg);
        workerLog('start: initial fn=' + fn + ' returned');
    }
    catch (error) {
        if (error === HALT_KERNEL) {
            workerLog('start: initial fn=' + fn + ' threw HALT_KERNEL');
            return;
        }
        // Don't re-throw — would propagate as unhandled Worker error and crash the renderer.
        // Log it and exit cleanly instead.
        console.error('[WORKER_FATAL] name=' + self.name + ' fn=' + fn + ' err=' + error);
        if (error?.stack) console.error('[WORKER_FATAL_STACK] ' + error.stack);
        return;
    }
};
