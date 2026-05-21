import { assert } from "./util.js";
import { HALT_KERNEL, kernel_imports, } from "./wasm.js";
const unavailable = () => {
    throw new Error("not available on worker thread");
};
const postMessage = self.postMessage;
const workerLog = (msg) => { postMessage({ type: "log", msg: "[W:" + (self.name || '?') + "] " + msg }); };
function user_imports({ kernel_memory, get_kernel_instance, parent_user_module: parent_module, parent_user_memory: parent_memory, fork_bufPtr = null, fork_retPtr = null, setForkOverride, clearForkOverride, }) {
    const HALT_USER = Symbol("halt user");
    const kernel_memory_buffer = new Uint8Array(kernel_memory.buffer);
    let module = null;
    let instance = null;
    let memory = null;
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
                if (fresh_memory || !memory) {
                    const size = 2048 + Math.floor(Math.random() * 1000);
                    // TODO: read the real initial size from the module.
                    // TOOD: enforce rlimit via maximum.
                    memory = new WebAssembly.Memory({
                        initial: size,
                        maximum: size,
                        shared: true,
                    });
                }
                const kernel_instance = get_kernel_instance();
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
                            const tp = instance.exports.__get_tp ? instance.exports.__get_tp() : 0;
                            const m32 = new Int32Array(memory.buffer);
                            m32[(tp + 0) >> 2] = buf; // __THREW__
                            m32[(tp + 4) >> 2] = val; // __threwValue
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
                    instance = new WebAssembly.Instance(module, {
                        env: { memory, ...env_sjlj },
                        linux: {
                            syscall: (nr, arg0, arg1, arg2, arg3, arg4, arg5) => {
                                workerLog('sc nr=' + nr + ' a0=' + arg0 + ' a1=' + arg1 + ' a2=' + arg2);
                                // Intercept WASM-fork syscalls (9999=fork, 10000=vfork) before kernel.
                                if (nr === 9999 || nr === 10000) {
                                    if (!instance?.exports?.asyncify_get_state) {
                                        workerLog('sc nr=' + nr + ': not asyncify-transformed, ENOSYS');
                                        return -38; // ENOSYS
                                    }
                                    const state = instance.exports.asyncify_get_state();
                                    if (state === 0) {
                                        // Phase 1 (Normal): initiate asyncify unwind
                                        pendingFork = { bufPtr: arg0, retPtr: arg1, vfork: nr === 10000 };
                                        instance.exports.asyncify_start_unwind(arg0);
                                        return 0;
                                    } else if (state === 2) {
                                        // Phase 3 (Rewinding): stop rewind, return fork result
                                        instance.exports.asyncify_stop_rewind();
                                        return new Int32Array(memory.buffer)[arg1 >> 2];
                                    }
                                    return -38; // ENOSYS (unexpected asyncify state)
                                }
                                const original_instance = instance;
                                const ret = kernel_instance.exports.syscall(nr, arg0, arg1, arg2, arg3, arg4, arg5);
                                workerLog('sc nr=' + nr + ' ret=' + ret);
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
                        // Check if this is an asyncify fork unwind (pendingFork set by syscall handler)
                        if (pendingFork !== null && instance?.exports?.asyncify_get_state?.() === 1) {
                            const fork = pendingFork;
                            pendingFork = null;
                            instance.exports.asyncify_stop_unwind();
                            // Copy user memory for the child (both fork and vfork copy for safety)
                            const pages = memory.buffer.byteLength >>> 16;
                            const childMem = new WebAssembly.Memory({ initial: pages, maximum: pages, shared: true });
                            new Uint8Array(childMem.buffer).set(new Uint8Array(memory.buffer));
                            // Override get_user_memory so the kernel's spawn_worker passes childMem
                            setForkOverride(childMem, { bufPtr: fork.bufPtr, retPtr: fork.retPtr });
                            // Have the kernel create the child task (proper PID, fd/cred inheritance)
                            const SYS_CLONE = 220, SIGCHLD = 17;
                            const childPid = get_kernel_instance().exports.syscall(SYS_CLONE, 0, 0, SIGCHLD, 0, 0, 0);
                            clearForkOverride();
                            workerLog('fork: kernel sys_clone → childPid=' + childPid);
                            // Rewind parent: fork() returns childPid (or negative errno on failure)
                            new Int32Array(memory.buffer)[fork.retPtr >> 2] = childPid;
                            instance.exports.asyncify_start_rewind(fork.bufPtr);
                            continue;
                        }
                        workerLog('call() error: ' + String(error));
                        console.log("error running user module:", String(error));
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
                    assert(instance);
                    const { __indirect_function_table } = instance.exports;
                    assert(__indirect_function_table instanceof WebAssembly.Table, "Invalid function table");
                    const f = __indirect_function_table.get(fn);
                    assert(typeof f === "function" && f.length === 1, "Invalid function signature");
                    workerLog('call_entry calling fn=' + fn);
                    f(arg);
                    workerLog('call_entry fn=' + fn + ' returned (no exit!)');
                    console.warn("thread entrypoint reached the end without exiting");
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
            read(to, from, n) {
                assert(memory);
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
    const { fn, arg, vmlinux, memory, parent_user_module, parent_user_memory, fork_bufPtr = null, fork_retPtr = null } = event.data;
    workerLog('start fn=' + fn + ' has_parent_user=' + (parent_user_module != null) + ' fork=' + (fork_bufPtr != null));
    // Shared state between user_imports' call() and the kernel spawn_worker callback.
    // During a fork(), call() sets these before calling kernel sys_clone so that
    // get_user_memory() returns the child's memory copy to the kernel's spawn_worker.
    let forkChildMemory = null;
    let forkSpawnParams = null;
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
    });
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
    const instance = new WebAssembly.Instance(vmlinux, imports);
    try {
        instance.exports.__indirect_function_table.get(fn)(arg);
    }
    catch (error) {
        if (error === HALT_KERNEL)
            return;
        throw error;
    }
};
