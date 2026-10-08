// SPDX-License-Identifier: MIT

import { listen_endpoint, post_endpoint } from "./endpoint.ts";
import { platform } from "./platform.ts";
import { assert } from "./util.ts";
import { export_stack_pointer, read_wasm_memories } from "./wasm_binary.ts";
// LinuxOnTab: WALI (Rust) host imports — see src/lot/wali-bridge.js.
// @ts-ignore plain JS module
import { makeWaliImports } from "../lot/wali-bridge.js";
import {
  allocate_shared_memory,
  HALT_KERNEL,
  is_worker_halted,
  uncatchable_halt,
  type Imports,
  type Instance,
  kernel_imports,
  type MachineTerminationReason,
  memory_bytes,
  user_module_imports_supported,
  type UserContext,
} from "./wasm.ts";

export interface InitMessage {
  type: "init";
  fn: number;
  arg: number;
  vmlinux: WebAssembly.Module;
  memory: WebAssembly.Memory;
  user: UserContext | null;
  /**
   * LinuxOnTab asyncify fork: the child rewinds into the parent's fork() call
   * instead of running a clone entry function (see fork handling below).
   */
  fork?: ForkRewind | null;
  /** One-shot user-memory copy result: 0 pending, 1 complete, negative errno. */
  user_copy_status: Int32Array<SharedArrayBuffer> | null;
}
export interface ForwardedInitMessage {
  type: "forwarded_init";
  port: MessagePort;
}
export type WorkerMessage =
  | {
      type: "spawn_worker";
      name: string;
      port: MessagePort;
    }
  | { type: "boot_console_write"; message: ArrayBuffer }
  | { type: "boot_console_close" }
  | { type: "terminate_machine"; reason: MachineTerminationReason }
  | { type: "run_on_main"; fn: number; arg: number }
  | { type: "worker_exit" };

const unavailable = () => {
  throw new Error("not available on worker thread");
};

const endpoint = platform.worker_endpoint();
const postMessage = (message: WorkerMessage, transfer?: Transferable[]) =>
  post_endpoint(endpoint, message, transfer);

// LinuxOnTab asyncify fork()/vfork() — see sysroot/wasm_fork.c for the
// userspace half. fork() cannot exist natively in wasm (a call stack cannot
// be duplicated), so binaries are transformed with wasm-opt --asyncify and
// fork() is a sentinel syscall carrying an asyncify buffer:
//   parent: sentinel (state 0) → asyncify_start_unwind → _start() returns →
//           call() sees state 1 → real clone (kernel copies user memory,
//           spawns the child worker with ForkRewind) → retval=pid, rewind →
//           the sentinel is re-entered at state 2 → returns retval.
//   child:  switch_entry() sees ForkRewind → retval=0, rewind from the same
//           buffer (it lives in the copied heap) → fork() returns 0.
const USER_MEMORY_DEFAULT_MAX_PAGES = 4096; // 256 MiB
const USER_MEMORY_DEFAULT_MIN_PAGES = 2048; // 128 MiB
const NR_WASM_FORK = 9999;
const NR_WASM_VFORK = 10000;
const WASM_FORK_MAGIC = 0x464f524b; // 'FORK': arg0 is a caller-sized buffer
const NR_CLONE = 220;
const SIGCHLD = 17;
const CLONE_VFORK = 0x4000;
const CLONE_VM = 0x100;
const FORK_SCRATCH_BYTES = 4 * 1024 * 1024; // legacy binaries without their own buffer

// LinuxOnTab runtime code loading (#14): syscall(NR_LOT_WASM_LOAD, ptr, len)
// hands the runtime a wasm module from the caller's memory. The worker
// compiles it, instantiates it against the process's memory and function
// table, and appends its exported functions, in export order, to THIS
// thread's __indirect_function_table. Returns the first slot or -errno; the
// caller then calls them through ordinary function pointers. On a runtime
// without it the kernel answers -ENOSYS, which is the feature test.
//   imports allowed: env.memory (declare it shared, min 0, max 65536) and
//     env.__indirect_function_table (funcref) — nothing else;
//   the program must be linked with --growable-table (else -ENOSPC);
//   tables are per thread (each thread is its own instance): load in the
//     thread that calls, and keep slot maps per thread;
//   loaded code is not asyncify-instrumented, so it must not be on the stack
//     across fork(), and a fork child starts without it (fresh instance).
const NR_LOT_WASM_LOAD = 10001;
const LOT_WASM_LOAD_MAX = 64 * 1024 * 1024;

// Pre-7.1 SA_SIGINFO compat. 7.1's musl installs its __siginfo_trampoline as
// sa_restorer, and the kernel delivers SA_SIGINFO signals by calling
// trampoline(fn, sig), which fetches the siginfo through linux.copy_siginfo.
// The old LinuxOnTab sysroot (every shipped package) predates that ABI: it
// never imports copy_siginfo and its sa_restorer is 0 or __restore_rt, so the
// delivery was rejected and the process died on e.g. its first SIGCHLD. For
// those modules the host plays the trampoline itself: it pushes a frame onto
// the interrupted thread's shadow stack, copies the siginfo there and calls
// the three-argument handler from JS (a call_indirect through a mismatched
// type would trap; a JS call binds the real (i32, i32, i32) signature).
const COMPAT_SP_EXPORT = "__lot_compat_stack_pointer";
const SIGINFO_BYTES = 128;
const UCONTEXT_BYTES = 176; // old sysroot sizeof(ucontext_t) = 168, 16-byte rounded
const has_siginfo_trampoline_abi = (module: WebAssembly.Module) =>
  WebAssembly.Module.imports(module).some((i) => i.module === "linux" && i.name === "copy_siginfo");

// LinuxOnTab: modules post-processed with binaryen's --fpcast-emu export
// __lot_fpcast. GTK 2 code calls functions through pointers of other types
// all the time (one-argument class_init functions called with two, signal
// handlers with fewer parameters than the marshaller passes); on wasm such a
// call_indirect traps. fpcast-emu routes every indirect call through a thunk
// taking max-func-params i64 values and returning i64, so the table entries
// the host calls from JS (thread entry, signal handlers, the siginfo
// trampoline) take BigInts, padded to the thunk's arity.
const is_fpcast = (module: WebAssembly.Module) =>
  WebAssembly.Module.exports(module).some((e) => e.name === "__lot_fpcast");
type TableFn = (...args: number[]) => unknown;
function table_call_adapter(f: Function, fpcast: boolean): { call: TableFn; arity: number } {
  if (!fpcast) return { call: f as TableFn, arity: f.length };
  const n = f.length;
  return {
    arity: -1,
    call: (...args: number[]) => {
      const a = new Array<bigint>(n).fill(0n);
      args.forEach((v, i) => { if (i < n) a[i] = BigInt(v | 0); });
      const r = (f as (...b: bigint[]) => unknown)(...a);
      return typeof r === "bigint" ? Number(BigInt.asIntN(32, r)) : r;
    },
  };
}

export interface ForkRewind {
  bufPtr: number;
  retPtr: number;
  /**
   * The parent's __stack_pointer at the fork. Asyncify skips non-call code
   * (function prologues included) while rewinding, so a fresh instance
   * would resume inside fork() with SP still at the stack top, and every
   * later callee frame would be carved out over the copied outer frames.
   * Restoring SP before the rewind keeps the child's stack coherent.
   */
  sp: number;
  /** WALI thread entry the forking worker runs (rewind re-enters it, not _start). */
  entry?: { fn: number; arg: number } | null;
}

interface AsyncifyExports {
  asyncify_get_state?: () => number;
  asyncify_start_unwind?: (buf: number) => void;
  asyncify_stop_unwind?: () => void;
  asyncify_start_rewind?: (buf: number) => void;
  asyncify_stop_rewind?: () => void;
}

function user_imports({
  kernel_memory,
  get_kernel_instance,
  parent_user: parent,
  fork_rewind = null,
  set_pending_child_fork,
}: {
  kernel_memory: WebAssembly.Memory;
  get_kernel_instance: () => Instance;
  parent_user: UserContext | null;
  fork_rewind?: ForkRewind | null;
  /** Hands the next spawned child its ForkRewind (parent side of a fork). */
  set_pending_child_fork: (fork: ForkRewind | null) => void;
}): {
  context: UserContext | null;
  prepare(): void;
  imports: Imports["user"];
} {
  const HALT_USER = uncatchable_halt("halt user");
// __NR_arch_specific_syscall (244) + 1: arch/wasm/include/uapi/asm/unistd.h
const NR_WASM_GET_ARGS = 245;

  let context: UserContext | null = parent;
  let instance: WebAssembly.Instance | null = null;
  let pending_module_bytes: Uint8Array<ArrayBuffer> | null = null;
  let pending: UserContext | null = null;
  // One slot per nested SA_SIGINFO callback; null means its trampoline has
  // not requested the active signal payload yet.
  const siginfo_copy_results: (number | null)[] = [];

  function copy_bytes(
    destination_memory: WebAssembly.Memory,
    destination: number,
    source_memory: WebAssembly.Memory,
    source: number,
    length: number,
  ): number {
    const to = memory_bytes(destination_memory, destination, length);
    const from = memory_bytes(source_memory, source, length);
    if (!to || !from) return length;

    try {
      to.set(from);
      return 0;
    } catch {
      return length;
    }
  }

  function user_atomic_word(uaddr: number): Int32Array | null {
    const address = uaddr >>> 0;
    if (!context || (address & 3) !== 0) return null;

    const bytes = memory_bytes(context.memory, address, Int32Array.BYTES_PER_ELEMENT);
    return bytes ? new Int32Array(bytes.buffer, bytes.byteOffset, 1) : null;
  }

  function write_kernel_u32(addr: number, value: number): boolean {
    const bytes = memory_bytes(kernel_memory, addr >>> 0, Uint32Array.BYTES_PER_ELEMENT);
    if (!bytes) return false;

    new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).setUint32(0, value, true);
    return true;
  }

  function call_start(): void {
    assert(instance);
    const { _start } = instance.exports;
    assert(typeof _start === "function", "_start not found");
    _start();
    throw new Error("_start reached the end without exiting");
  }
  let call_entry = call_start;

  // LinuxOnTab fork state. pendingFork: set by the sentinel syscall while the
  // parent unwinds; forkRewind: this worker is a fork child that must rewind.
  let pendingFork: (ForkRewind & { vfork: boolean }) | null = null;
  const spGlobal = () => { const g = (instance?.exports as any)?.__stack_pointer; return g instanceof WebAssembly.Global ? g : null; };
  let forkRewind: ForkRewind | null = fork_rewind;
  // WALI (Rust std) thread entry this worker runs, if any: __wasm_thread_start_libc(tid, args).
  let waliThreadEntry: { fn: number; arg: number } | null = fork_rewind?.entry ?? null;
  const is_wali = (m: WebAssembly.Module) => WebAssembly.Module.imports(m).some((i) => i.module === "wali");
  function waliThreadRun() {
    assert(instance && waliThreadEntry);
    const f = instance.exports.__indirect_function_table.get(waliThreadEntry.fn) as (a: number, b: number) => void;
    assert(typeof f === "function", "invalid WALI thread entry");
    const tid = get_kernel_instance().exports.syscall(178, 0, 0, 0, 0, 0, 0); // gettid
    f(tid, waliThreadEntry.arg);
    // An asyncify fork unwind returns here normally: let call()'s catch see it.
    if (asyncify()?.asyncify_get_state?.() === 1) throw new Error("wali thread: asyncify unwind");
    console.warn("WALI thread entry returned");
  }
  let forkScratch: { memory: WebAssembly.Memory; bufPtr: number; retPtr: number; size: number } | null = null;
  // Return slot of an in-flight old-ABI fork (raw clone(SIGCHLD, 0), see
  // raw_clone_fork): the parent sets it at unwind, a fork child in switch_entry.
  let rawForkRetPtr: number | null = null;
  const asyncify = () => (instance ? (instance.exports as unknown as AsyncifyExports) : null);
  const sp = () => { const g = (instance?.exports as any)?.__stack_pointer; return g instanceof WebAssembly.Global ? "0x" + (g.value >>> 0).toString(16) : "n/a"; };
  // Per-worker scratch for binaries that do not bring their own buffer:
  // memory.grow'n pages the guest allocator can never hand out.
  function acquireForkScratch(memory: WebAssembly.Memory) {
    if (forkScratch && forkScratch.memory === memory) return forkScratch;
    const base = memory.grow(FORK_SCRATCH_BYTES >> 16) * 65536;
    forkScratch = { memory, retPtr: base, bufPtr: base + 16, size: FORK_SCRATCH_BYTES - 16 };
    return forkScratch;
  }
  function fork_sentinel(nr: number, arg0: number, arg1: number, arg2: number): number {
    const a = asyncify();
    assert(context);
    if (!a?.asyncify_get_state || !a.asyncify_start_unwind || !a.asyncify_stop_rewind) return -38; // ENOSYS: not asyncify-transformed
    const state = a.asyncify_get_state();
    if (state === 0) {
      let bufPtr: number, retPtr: number;
      if (arg2 === WASM_FORK_MAGIC) {
        bufPtr = arg0 >>> 0; retPtr = arg1 >>> 0; // header + size already written by wasm_fork.c
      } else {
        // Legacy thunk: the binary still supplies its own retval slot (arg1);
        // only the asyncify buffer is replaced by the per-worker scratch.
        const sc = acquireForkScratch(context.memory);
        bufPtr = sc.bufPtr; retPtr = arg1 >>> 0;
        const h = new Int32Array(context.memory.buffer);
        h[bufPtr >> 2] = bufPtr + 8;
        h[(bufPtr >> 2) + 1] = bufPtr + sc.size;
      }
      pendingFork = { bufPtr, retPtr, sp: (spGlobal()?.value ?? 0) >>> 0, vfork: nr === NR_WASM_VFORK };
      console.debug("[fork] " + (self.name || "?") + " unwind buf=0x" + bufPtr.toString(16) + " ret=0x" + retPtr.toString(16) + (arg2 === WASM_FORK_MAGIC ? " dyn" : " legacy") + " sp=" + sp());
      a.asyncify_start_unwind(bufPtr);
      return 0;
    }
    if (state === 2) {
      a.asyncify_stop_rewind();
      const rv = new Int32Array(context.memory.buffer)[(arg1 >>> 0) >> 2];
      console.debug("[fork] " + (self.name || "?") + " rewound, fork() returns " + rv + " sp=" + sp());
      return rv;
    }
    return -38;
  }

  // fork() in binaries built against the pre-7.1 sysroot (e.g. sshd-session):
  // musl calls syscall(SYS_clone, SIGCHLD, 0), with the flags in the FIRST
  // argument. The 7.1 wasm clone takes (fn, arg, flags, ...), so the kernel
  // read fn=17, flags=0 and started the child at table entry 17 — "Invalid
  // function signature", SIGSEGV, and a parent waiting forever for a command
  // that never ran (ssh sessions hung right after login). The 6.1 host
  // intercepted this call and forked by asyncify; do the same here, with the
  // per-worker scratch (these binaries bring no buffer or return slot).
  function raw_clone_fork(): number {
    const a = asyncify();
    assert(context);
    if (!a?.asyncify_get_state || !a.asyncify_start_unwind || !a.asyncify_stop_rewind) return -38;
    const state = a.asyncify_get_state();
    if (state === 0) {
      const sc = acquireForkScratch(context.memory);
      const h = new Int32Array(context.memory.buffer);
      h[sc.bufPtr >> 2] = sc.bufPtr + 8;
      h[(sc.bufPtr >> 2) + 1] = sc.bufPtr + sc.size;
      rawForkRetPtr = sc.retPtr;
      pendingFork = { bufPtr: sc.bufPtr, retPtr: sc.retPtr, sp: (spGlobal()?.value ?? 0) >>> 0, vfork: false };
      console.debug("[fork] " + (self.name || "?") + " old-ABI clone(SIGCHLD) unwind buf=0x" + sc.bufPtr.toString(16) + " sp=" + sp());
      a.asyncify_start_unwind(sc.bufPtr);
      return 0;
    }
    if (state === 2 && rawForkRetPtr !== null) {
      const retPtr = rawForkRetPtr;
      rawForkRetPtr = null;
      a.asyncify_stop_rewind();
      const rv = new Int32Array(context.memory.buffer)[retPtr >> 2];
      console.debug("[fork] " + (self.name || "?") + " old-ABI rewound, fork() returns " + rv);
      return rv;
    }
    return -38;
  }

  // See NR_LOT_WASM_LOAD.
  function lot_wasm_load(ptr: number, len: number): number {
    const EFAULT = 14, ENOEXEC = 8, EINVAL = 22, ENOSPC = 28, ENOSYS = 38;
    if (!context || !instance) return -ENOSYS;
    const table = (instance.exports as any).__indirect_function_table;
    if (!(table instanceof WebAssembly.Table)) return -ENOSYS;
    if (len === 0 || len > LOT_WASM_LOAD_MAX) return -EINVAL;
    if (ptr + len > context.memory.buffer.byteLength) return -EFAULT;
    const bytes = new Uint8Array(context.memory.buffer, ptr, len).slice();
    let module: WebAssembly.Module;
    try { module = new WebAssembly.Module(bytes); } catch (_) { return -ENOEXEC; }
    for (const imp of WebAssembly.Module.imports(module)) {
      const ok = imp.module === "env" &&
        ((imp.name === "memory" && imp.kind === "memory") ||
         (imp.name === "__indirect_function_table" && imp.kind === "table"));
      if (!ok) return -ENOEXEC;
    }
    let loaded: WebAssembly.Instance;
    try {
      loaded = new WebAssembly.Instance(module, {
        env: { memory: context.memory, __indirect_function_table: table },
      });
    } catch (_) { return -ENOEXEC; }   // LinkError: memory/table type mismatch
    const fns = WebAssembly.Module.exports(module)
      .filter((e) => e.kind === "function")
      .map((e) => loaded.exports[e.name] as Function);
    if (!fns.length) return -EINVAL;
    let base: number;
    try { base = table.grow(fns.length); } catch (_) { return -ENOSPC; }
    fns.forEach((f, i) => table.set(base + i, f));
    return base;
  }

  function create_instance(context: UserContext): WebAssembly.Instance {
    const kernel_instance = get_kernel_instance();
    const linux_syscall = (
      nr: number,
      arg0: number,
      arg1: number,
      arg2: number,
      arg3: number,
      arg4: number,
      arg5: number,
    ) => {
      // This thread already exited in the kernel; user code that caught the
      // HALT_KERNEL unwind (catch (...), destructors) must not re-enter it.
      if (is_worker_halted()) throw HALT_KERNEL;
      if (nr === NR_WASM_FORK || nr === NR_WASM_VFORK) return fork_sentinel(nr, arg0, arg1, arg2);
      if (nr === NR_LOT_WASM_LOAD) return lot_wasm_load(arg0 >>> 0, arg1 >>> 0);
      // Old-ABI fork: clone(SIGCHLD, 0). A real 7.1 clone always has its flags
      // in arg2, so (17, 0, 0) can't be one.
      if (nr === NR_CLONE && arg0 === SIGCHLD && arg1 === 0 && arg2 === 0 && asyncify()?.asyncify_get_state) return raw_clone_fork();
      // NOMMU vfork from our asyncify-built C binaries (busybox hush runs every
      // external command as clone(fn, CLONE_VM|CLONE_VFORK|SIGCHLD)). With a
      // shared memory the child starts at the module's default __stack_pointer
      // — the top of the SUSPENDED parent's shadow stack — and clobbers the
      // parent's outermost frames on its way to execve; the parent then faults
      // when it unwinds into them (apk exited 139 right after "installed", so
      // /etc/rc skipped starting ?image= services). These binaries export no
      // __stack_pointer to relocate the child, so give it its own copy of the
      // memory, as the 6.1 host did: drop CLONE_VM, keep the vfork wait.
      // Binaries whose __clone moves the child onto its own stack export
      // __lot_clone_sets_sp and keep the real shared-memory vfork (the kernel
      // refuses a copying clone while other threads share the mm).
      if (nr === NR_CLONE && (arg2 & CLONE_VFORK) && (arg2 & CLONE_VM) && asyncify()?.asyncify_get_state && !(instance?.exports as any)?.__lot_clone_sets_sp) {
        arg2 &= ~CLONE_VM;
      }
      const original_instance = instance;
      const ret = kernel_instance.exports.syscall(nr, arg0, arg1, arg2, arg3, arg4, arg5);
      if (instance !== original_instance) {
        call_entry = call_start;
        throw HALT_USER;
      }
      return ret;
    };
    // WALI modules (Rust std on wali-musl) import wali.SYS_* and a few env.*
    // hooks; the bridge translates them onto linux.syscall + the args exports.
    let wali_env: Record<string, unknown> = {};
    let wali_imports: Record<string, unknown> | undefined;
    if (is_wali(context.module)) {
      const w = makeWaliImports({
        memory: context.memory,
        kernel: { exports: {
          get_args_length: () => kernel_instance.exports.get_args_length(),
          get_args: (buf: number) => kernel_instance.exports.syscall(NR_WASM_GET_ARGS, buf >>> 0, 262144, 0, 0, 0, 0),
        } },
        syscall: (...a: number[]) => linux_syscall(a[0]!, a[1]!, a[2]!, a[3]!, a[4]!, a[5]!, a[6]!),
        log: (m: string) => console.debug("[wali] " + m),
      });
      wali_env = w.envExtra ?? {};
      wali_imports = w.wali;
    }
    return new WebAssembly.Instance(context.module, {
      env: { memory: context.memory, ...wali_env },
      ...(wali_imports ? { wali: wali_imports } : {}),
      linux: {
        syscall: linux_syscall,
        get_thread_area: kernel_instance.exports.get_thread_area,
        // LinuxOnTab compat for pre-7.1 binaries (every shipped package): their
        // crt1 calls get_args_length() (size only) and then get_args(buf) to
        // receive {len, envc, argc, argv, envp, data[]} relocated to buf — the
        // exact block 7.1's wasm_get_args syscall writes. The size comes from
        // a small kernel export (the syscall has no size query); the copy is
        // the syscall itself, which consumes exec_args like the old export did.
        get_args_length: () => kernel_instance.exports.get_args_length(),
        get_args: (buf: number) =>
          kernel_instance.exports.syscall(NR_WASM_GET_ARGS, buf >>> 0, 262144, 0, 0, 0, 0),
        copy_siginfo: (to: number) => {
          const result = kernel_instance.exports.copy_siginfo(to);
          const current = siginfo_copy_results.length - 1;
          if (current >= 0) siginfo_copy_results[current] = result;
          return result;
        },
      },
    });
  }

  function instantiate(fresh_memory: boolean): void {
    if (fresh_memory) {
      assert(pending);
      context = pending;
      pending = null;
    }

    assert(context);
    instance = create_instance(context);
  }

  return {
    get context() {
      return context;
    },
    prepare() {
      if (parent) instantiate(false);
    },
    imports: {
      // program management:
      compile_begin(size) {
        pending_module_bytes = null;
        pending = null;
        try {
          pending_module_bytes = new Uint8Array(size >>> 0);
          return 0;
        } catch {
          return -12; // out of memory
        }
      },
      compile_write(buf, offset, size) {
        const source = buf >>> 0;
        const destination = offset >>> 0;
        const length = size >>> 0;
        const kernel_buffer = kernel_memory.buffer;
        if (
          !pending_module_bytes ||
          source > kernel_buffer.byteLength - length ||
          destination > pending_module_bytes.length - length
        ) {
          return -22; // invalid argument
        }
        pending_module_bytes.set(new Uint8Array(kernel_buffer, source, length), destination);
        return 0;
      },
      compile_end(maximum_memory_pages) {
        const bytes = pending_module_bytes;
        pending_module_bytes = null;
        if (!bytes) return -22; // invalid argument

        const rlimit_pages = maximum_memory_pages >>> 0;
        let module: WebAssembly.Module;
        let minimum: number;
        let maximum: number;
        let declared_max = 0;
        try {
          const memories = read_wasm_memories(bytes);
          const memory_import = memories.imports[0];
          if (
            memories.definitions.length !== 0 ||
            memories.imports.length !== 1 ||
            !memory_import ||
            memory_import.module !== "env" ||
            memory_import.name !== "memory" ||
            memory_import.type.address !== "i32" ||
            !memory_import.type.shared ||
            memory_import.type.maximum === undefined
          ) {
            return -8; // exec format error
          }

          module = new WebAssembly.Module(bytes);
          if (!user_module_imports_supported(module)) {
            return -8; // exec format error
          }
          // Pre-7.1 binaries have no siginfo trampoline; expose their stack
          // pointer so call_siginfo_handler can build the siginfo frame.
          if (!has_siginfo_trampoline_abi(module)) {
            let patched: Uint8Array | null = null;
            try {
              patched = export_stack_pointer(bytes, COMPAT_SP_EXPORT);
            } catch {}
            if (patched) module = new WebAssembly.Module(patched);
          }

          minimum = Number(memory_import.type.minimum);
          declared_max = Number(memory_import.type.maximum);
          maximum = Math.min(declared_max, rlimit_pages);
          // LinuxOnTab: C binaries all declare a 4 GiB maximum, and reserving
          // that much address space per process makes the browser refuse (or
          // allocate_shared_memory degrade the maximum toward the initial
          // size) once a few dozen processes exist — after which malloc's
          // memory.grow fails and musl traps. Cap them at 256 MiB like the
          // 6.1 host did; only WALI (Rust) modules keep their declared limit.
          const wali_module = WebAssembly.Module.imports(module).some((i) => i.module === "wali");
          // Opt-in for the few programs that need more: a module exporting
          // __lot_big_memory keeps its declared maximum. The x86 emulator
          // (spikes/x86-blink) declares 1 GiB: Node under Blink holds the
          // 42 MB node binary, its libraries, V8's heap and Blink's page
          // tables, and ran out of 256 MiB mid-run (random guest SIGSEGVs).
          const big_memory = WebAssembly.Module.exports(module).some((e) => e.name === "__lot_big_memory");
          if (!wali_module && !big_memory) maximum = Math.min(maximum, USER_MEMORY_DEFAULT_MAX_PAGES);
          // Start C processes at 128 MiB like the 6.1 host did (its random
          // 2048-3048 pages). This is not just headroom: a process whose heap
          // had to grow through memory.grow before it forked corrupts mallocng
          // metadata in BOTH parent and child on the second fork (free() of
          // the fork buffer trips get_meta's checks; forktest [2]-[5], ash/zsh
          // subshells), while the same binaries are fine when their heap never
          // needs to grow. Root cause not yet found — see kernel-7-1-port notes.
          if (!wali_module) minimum = Math.max(minimum, Math.min(USER_MEMORY_DEFAULT_MIN_PAGES, maximum));
        } catch {
          return -8; // exec format error
        }

        if (maximum < minimum) return -12; // out of memory

        let allocated: ReturnType<typeof allocate_shared_memory>;
        try {
          allocated = allocate_shared_memory(minimum, maximum);
        } catch {
          return -12; // out of memory
        }

        const next_context = { module, ...allocated };
        console.debug("[user-memory] " + (self.name || "?") + " declared min=" + minimum + " max=" + declared_max +
          " rlimit=" + rlimit_pages + " requested max=" + maximum + " granted max=" + allocated.maximum_pages + " pages");
        pending = next_context;
        return 0;
      },
      compile_abort() {
        pending_module_bytes = null;
        pending = null;
      },
      instantiate(fresh_memory) {
        instantiate(Boolean(fresh_memory));
      },
      call() {
        for (;;) {
          try {
            call_entry();
          } catch (error) {
            if (error === HALT_USER) continue;
            if (error === HALT_KERNEL) throw error;
            // Asyncify fork: _start() returned because the stack was unwound.
            const a = asyncify();
            if (pendingFork && a?.asyncify_get_state?.() === 1) {
              const fork = pendingFork;
              pendingFork = null;
              assert(context);
              a.asyncify_stop_unwind!();
              {
                // Asyncify buffer header: [cursor, end]; the data starts at +8.
                const h = new Int32Array(context.memory.buffer);
                const cursor = h[fork.bufPtr >> 2], end = h[(fork.bufPtr >> 2) + 1];
                console.debug("[fork] " + (self.name || "?") + " unwound: asyncify used=" + (cursor - (fork.bufPtr + 8)) +
                  " capacity=" + (end - (fork.bufPtr + 8)) + " bytes, mem pages=" + (context.memory.buffer.byteLength >> 16));
              }
              // Real clone without CLONE_VM: the kernel copies the user memory
              // (spawn_worker COPY) and the new worker gets ForkRewind, so it
              // rewinds into fork() instead of calling a clone entry.
              set_pending_child_fork({ bufPtr: fork.bufPtr, retPtr: fork.retPtr, sp: fork.sp, entry: waliThreadEntry });
              let pid: number;
              try {
                pid = get_kernel_instance().exports.syscall(
                  NR_CLONE, 0, 0, SIGCHLD | (fork.vfork ? CLONE_VFORK : 0), 0, 0, 0);
              } finally {
                set_pending_child_fork(null);
              }
              new Int32Array(context.memory.buffer)[fork.retPtr >> 2] = pid;
              console.debug("[fork] " + (self.name || "?") + " clone -> " + pid + ", rewinding parent sp=" + sp());
              a.asyncify_start_rewind!(fork.bufPtr);
              call_entry = waliThreadEntry ? waliThreadRun : call_start; // re-enter the same chain to rewind
              continue;
            }
            console.error("error running user module in " + (self.name || "?") + ":", error,
              "\n" + String((error as Error)?.stack ?? "").slice(0, 3000),
              "| asyncify_state=" + (asyncify()?.asyncify_get_state?.() ?? "n/a") + " pendingFork=" + !!pendingFork + " forkRewind=" + !!forkRewind);
            return;
          }
        }
      },
      switch_entry(fn, arg) {
        // This is called if this thread was created by a clone call,
        // so its entrypoint is a user-specified function.
        // The worker prepares an instance sharing the parent's user context
        // before the kernel enters this callback.

        assert(parent);

        // LinuxOnTab fork child: rewind into the parent's fork() call.
        if (forkRewind) {
          const rw = forkRewind;
          forkRewind = null;
          rawForkRetPtr = rw.retPtr;
          call_entry = () => {
            call_entry = call_start;
            assert(instance && context);
            const a = asyncify();
            assert(a?.asyncify_start_rewind, "fork child without asyncify exports");
            new Int32Array(context.memory.buffer)[rw.retPtr >> 2] = 0; // fork() returns 0 in the child
            const g = spGlobal();
            if (g && rw.sp) g.value = rw.sp;
            console.debug("[fork] " + (self.name || "?") + " child rewinding buf=0x" + rw.bufPtr.toString(16) + " sp=" + sp() + (g ? " (restored)" : " (no __stack_pointer export!)"));
            a.asyncify_start_rewind(rw.bufPtr);
            if (waliThreadEntry) { call_entry = waliThreadRun; waliThreadRun(); return; }
            call_start();
          };
          return;
        }

        // WALI thread / posix_spawn child: wali-musl's __wasm_thread_spawn(fn, args)
        // arrives as clone(fn, args) with a 2-arg entry (tid, args); its vfork
        // child from posix_spawn has a 1-arg entry that runs natively and execs.
        if (context && is_wali(context.module)) {
          call_entry = () => {
            assert(instance);
            const f = instance.exports.__indirect_function_table.get(fn >>> 0) as Function;
            assert(typeof f === "function", "invalid WALI clone entry");
            if (f.length === 1) {
              call_entry = call_start;
              f(arg);
              return;
            }
            waliThreadEntry = { fn: fn >>> 0, arg: arg >>> 0 };
            call_entry = waliThreadRun;
            waliThreadRun();
          };
          return;
        }

        call_entry = () => {
          assert(instance);

          const { __indirect_function_table } = instance.exports;
          assert(__indirect_function_table instanceof WebAssembly.Table, "Invalid function table");

          const raw = __indirect_function_table.get(fn >>> 0);
          assert(typeof raw === "function", "Invalid function signature");
          const f = table_call_adapter(raw, !!context && is_fpcast(context.module));
          assert(f.arity === 1 || f.arity === -1, "Invalid function signature");

          f.call(arg);

          // throw new Error("thread entrypoint reached the end without exiting");
          console.warn("thread entrypoint reached the end without exiting");
        };
      },

      // signal handling:
      call_signal_handler(fn, sig) {
        assert(instance);

        const { __indirect_function_table } = instance.exports;
        assert(__indirect_function_table instanceof WebAssembly.Table, "Invalid function table");

        const raw = __indirect_function_table.get(fn >>> 0);
        assert(typeof raw === "function", "Invalid function signature");
        const f = table_call_adapter(raw, !!context && is_fpcast(context.module));
        assert(f.arity === 1 || f.arity === -1, "Invalid function signature");

        f.call(sig);
      },
      call_siginfo_handler(trampoline, fn, sig) {
        assert(instance && context);

        const { __indirect_function_table } = instance.exports;
        assert(__indirect_function_table instanceof WebAssembly.Table, "Invalid function table");

        if (!has_siginfo_trampoline_abi(context.module)) {
          const raw_handler = __indirect_function_table.get(fn >>> 0);
          assert(typeof raw_handler === "function", "Invalid siginfo handler");
          const adapted = table_call_adapter(raw_handler, is_fpcast(context.module));
          assert(adapted.arity === 3 || adapted.arity === -1, "Invalid siginfo handler");
          const handler = adapted.call;
          const kernel = get_kernel_instance().exports;
          const stack_pointer = (instance.exports as Record<string, unknown>)[COMPAT_SP_EXPORT];
          if (!(stack_pointer instanceof WebAssembly.Global)) {
            // Not a wasm-ld layout we recognise: no frame to build, so the
            // handler gets what the 6.1 host would have given it.
            try {
              handler(sig, 0, 0);
            } finally {
              kernel.clear_siginfo();
            }
            return 0;
          }
          const saved = stack_pointer.value >>> 0;
          if (saved < SIGINFO_BYTES + UCONTEXT_BYTES + 16) return -14; // EFAULT
          const frame = (saved - SIGINFO_BYTES - UCONTEXT_BYTES) & ~15;
          const info = frame;
          const ucontext = frame + SIGINFO_BYTES;
          const zero = memory_bytes(context.memory, ucontext, UCONTEXT_BYTES);
          if (!zero) return -14; // EFAULT
          zero.fill(0);
          stack_pointer.value = frame;
          try {
            const result = kernel.copy_siginfo(info);
            if (result !== 0) return result;
            handler(sig, info, ucontext);
            return 0;
          } finally {
            // Also on a non-local exit: the frame that catches it restores
            // its own SP, and every frame above the interrupted one is gone.
            stack_pointer.value = saved;
            kernel.clear_siginfo();
          }
        }

        const raw_trampoline = __indirect_function_table.get(trampoline >>> 0);
        assert(typeof raw_trampoline === "function", "Invalid siginfo trampoline");
        const adapted_trampoline = table_call_adapter(raw_trampoline, is_fpcast(context.module));
        assert(adapted_trampoline.arity === 2 || adapted_trampoline.arity === -1, "Invalid siginfo trampoline");
        const f = adapted_trampoline.call;

        siginfo_copy_results.push(null);
        try {
          f(fn, sig);
          return siginfo_copy_results.at(-1) ?? -22;
        } finally {
          // Non-local exits can unwind the kernel callback before its C cleanup.
          try {
            get_kernel_instance().exports.clear_siginfo();
          } finally {
            siginfo_copy_results.pop();
          }
        }
      },

      // memory:
      read(to, from, n) {
        const length = n >>> 0;
        if (!context) return length;
        return copy_bytes(kernel_memory, to >>> 0, context.memory, from >>> 0, length);
      },
      write(to, from, n) {
        const length = n >>> 0;
        if (!context) return length;
        return copy_bytes(context.memory, to >>> 0, kernel_memory, from >>> 0, length);
      },
      write_zeroes(to, n) {
        const length = n >>> 0;
        if (!context) return length;
        const destination = memory_bytes(context.memory, to >>> 0, length);
        if (!destination) return length;

        try {
          destination.fill(0);
          return 0;
        } catch {
          return length;
        }
      },
      futex_atomic_op(oldval, uaddr, op, oparg) {
        const word = user_atomic_word(uaddr);
        if (!word) return -14; // bad address

        let old: number;
        switch (op) {
          case 0: // FUTEX_OP_SET
            old = Atomics.exchange(word, 0, oparg);
            break;
          case 1: // FUTEX_OP_ADD
            old = Atomics.add(word, 0, oparg);
            break;
          case 2: // FUTEX_OP_OR
            old = Atomics.or(word, 0, oparg);
            break;
          case 3: // FUTEX_OP_ANDN
            old = Atomics.and(word, 0, ~oparg);
            break;
          case 4: // FUTEX_OP_XOR
            old = Atomics.xor(word, 0, oparg);
            break;
          default:
            return -38; // function not implemented
        }

        return write_kernel_u32(oldval, old) ? 0 : -14; // bad address
      },
      futex_atomic_cmpxchg(oldval, uaddr, expected, replacement) {
        const word = user_atomic_word(uaddr);
        if (!word) return -14; // bad address

        const old = Atomics.compareExchange(word, 0, expected, replacement);
        return write_kernel_u32(oldval, old) ? 0 : -14; // bad address
      },
    },
  };
}

function start({
  fn,
  arg,
  vmlinux,
  memory,
  user: initial_user_context,
  user_copy_status,
  fork,
}: InitMessage) {
  // Refresh every WebAssembly.Memory received across a worker boundary
  // immediately, including any future additions to InitMessage. Chromium can
  // retain the fixed-length buffer wrapper captured before another isolate
  // grows it; grow(0) refreshes the wrapper before constructing any views.
  memory.grow(0);
  initial_user_context?.memory.grow(0);

  let user_context = initial_user_context;
  if (user_copy_status) {
    assert(user_context);
    // fork.c permits COPY only for a single-user mm, and the caller blocks
    // until publication below, so the source is stable. Allocate here so the
    // private backing store is owned by the destination isolate, not the
    // long-lived parent.
    try {
      const source = memory_bytes(user_context.memory, 0);
      if (!source) throw new RangeError("invalid source memory");
      const copied = allocate_shared_memory(
        source.byteLength / 0x10000,
        user_context.maximum_pages,
      );
      const destination = memory_bytes(copied.memory, 0, source.byteLength);
      if (!destination) throw new RangeError("invalid destination memory");
      destination.set(source);
      console.debug("[user-memory] " + (self.name || "?") + " fork copy pages=" + source.byteLength / 0x10000 +
        " parent max=" + user_context.maximum_pages + " granted max=" + copied.maximum_pages);
      user_context = { module: user_context.module, ...copied };
      Atomics.store(user_copy_status, 0, 1);
    } catch {
      Atomics.store(user_copy_status, 0, -12);
    }
    Atomics.notify(user_copy_status, 0);
    if (Atomics.load(user_copy_status, 0) < 0) {
      postMessage({ type: "worker_exit" });
      platform.quit();
      return;
    }
  }

  let pending_child_fork: ForkRewind | null = null;
  const user = user_imports({
    kernel_memory: memory,
    get_kernel_instance: () => instance,
    parent_user: user_context,
    fork_rewind: fork ?? null,
    set_pending_child_fork: (f) => { pending_child_fork = f; },
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
      spawn_worker(fn, arg, name, user, copy_user_memory) {
        const direct = new MessageChannel();
        postMessage(
          {
            type: "spawn_worker",
            name,
            port: direct.port1,
          },
          [direct.port1],
        );
        const user_copy_status = copy_user_memory ? new Int32Array(new SharedArrayBuffer(4)) : null;
        direct.port2.postMessage({
          type: "init",
          fn,
          arg,
          vmlinux,
          memory,
          user,
          user_copy_status,
          fork: pending_child_fork,
        } satisfies InitMessage);
        if (!user_copy_status) return 0;
        // If publication wins the race, wait returns "not-equal"; no wakeup
        // is lost.
        Atomics.wait(user_copy_status, 0, 0);
        const result = Atomics.load(user_copy_status, 0);
        assert(result === 1 || result < 0, "copy wait completed without a result");
        return result === 1 ? 0 : result;
      },
      boot_console_write(message) {
        postMessage({ type: "boot_console_write", message });
      },
      boot_console_close() {
        postMessage({ type: "boot_console_close" });
      },
      terminate_machine(reason) {
        postMessage({ type: "terminate_machine", reason });
      },
      run_on_main(fn, arg) {
        postMessage({ type: "run_on_main", fn, arg });
      },
      get_user_context() {
        return user.context;
      },
      worker_exit() {
        postMessage({ type: "worker_exit" });
      },
    }),
    virtio: {
      set_features: unavailable,
      setup: unavailable,
      reset: unavailable,
      enable_vring: unavailable,
      disable_vring: unavailable,
      notify: unavailable,
    },
  } satisfies Imports;

  const instance = new WebAssembly.Instance(vmlinux, imports) as Instance;
  user.prepare();
  try {
    instance.exports.__indirect_function_table.get(fn >>> 0)!(arg);
  } catch (error) {
    if (error === HALT_KERNEL) return;
    throw error;
  }
}

listen_endpoint(endpoint, {
  message(raw) {
    const message = raw as InitMessage | ForwardedInitMessage;

    // Initial workers receive InitMessage directly from the page. Workers
    // spawned by another worker receive their InitMessage over this port, which
    // works around a WebKit bug reclaiming shared Wasm memory across JS VMs.
    if (message.type === "forwarded_init") {
      message.port.onmessage = ({ data }) => {
        message.port.close();
        start(data as InitMessage);
      };
      message.port.start();
      return;
    }

    start(message);
  },
});
