// src/kernel/endpoint.ts
var as_error = (value, fallback) => value instanceof Error ? value : new Error(fallback);
function listen_endpoint(endpoint2, handlers) {
  if ("addEventListener" in endpoint2) {
    const on_message2 = (event) => handlers.message(event.data);
    const on_message_error2 = (_event) => handlers.error?.(new Error("could not deserialize endpoint message"));
    const on_error2 = (event) => {
      event.preventDefault();
      handlers.error?.(as_error(event.error, event.message || "worker failed"));
    };
    endpoint2.addEventListener("message", on_message2);
    if (handlers.error) {
      endpoint2.addEventListener("messageerror", on_message_error2);
      endpoint2.addEventListener("error", on_error2);
    }
    return () => {
      endpoint2.removeEventListener("message", on_message2);
      if (handlers.error) {
        endpoint2.removeEventListener("messageerror", on_message_error2);
        endpoint2.removeEventListener("error", on_error2);
      }
    };
  }
  const on_message = (message) => handlers.message(message);
  const on_message_error = (error) => handlers.error?.(as_error(error, "could not deserialize endpoint message"));
  const on_error = (error) => handlers.error?.(as_error(error, "worker failed"));
  endpoint2.on("message", on_message);
  if (handlers.error) {
    endpoint2.on("messageerror", on_message_error);
    endpoint2.on("error", on_error);
  }
  return () => {
    endpoint2.off("message", on_message);
    if (handlers.error) {
      endpoint2.off("messageerror", on_message_error);
      endpoint2.off("error", on_error);
    }
  };
}
function post_endpoint(endpoint2, message, transfer) {
  endpoint2.postMessage(message, transfer);
}

// src/kernel/util.ts
function assert(cond, message = "Assertation failed") {
  if (!cond) throw new Error(message);
}

// src/kernel/platform.ts
function worker_handle(endpoint2, terminate, handlers) {
  const stop_listening = listen_endpoint(endpoint2, {
    message: handlers.on_message,
    error: handlers.on_error
  });
  return {
    post: (message, transfer) => post_endpoint(endpoint2, message, transfer),
    terminate: async () => {
      stop_listening();
      await terminate();
    }
  };
}
var web = {
  async load_wasm(url) {
    const response = await fetch(url);
    const module = await WebAssembly.compileStreaming(response.clone());
    const bytes = new Uint8Array(await response.arrayBuffer());
    return { bytes, module };
  },
  spawn_worker(name, handlers) {
    const worker = new Worker(new URL("./worker.js", import.meta.url), {
      type: "module",
      name
    });
    return worker_handle(worker, () => worker.terminate(), handlers);
  },
  worker_endpoint() {
    return self;
  },
  quit() {
    self.close();
  }
};
function node(getBuiltinModule2, process2) {
  const { readFile } = getBuiltinModule2("node:fs/promises");
  const { Worker: Worker2, parentPort } = getBuiltinModule2("node:worker_threads");
  return {
    async load_wasm(url) {
      const bytes = await readFile(url);
      return { bytes, module: await WebAssembly.compile(bytes) };
    },
    spawn_worker(name, handlers) {
      const worker = new Worker2(new URL("./worker.js", import.meta.url), {
        name
      });
      return worker_handle(worker, () => worker.terminate(), handlers);
    },
    worker_endpoint() {
      assert(parentPort, "not in a worker");
      return parentPort;
    },
    quit() {
      process2.exit(0);
    }
  };
}
var process = globalThis.process;
var getBuiltinModule = process?.getBuiltinModule;
var platform = getBuiltinModule && process ? node(getBuiltinModule, process) : web;

// src/kernel/wasm_binary.ts
var WasmParseError = class extends Error {
  constructor(message, offset) {
    super(`${message} at byte ${offset}`);
    this.name = "WasmParseError";
  }
};
var text_decoder = new TextDecoder("utf-8", { fatal: true });
var Cursor = class _Cursor {
  #bytes;
  #end;
  #offset;
  constructor(bytes, offset = 0, end = bytes.length) {
    this.#bytes = bytes;
    this.#offset = offset;
    this.#end = end;
  }
  get done() {
    return this.#offset === this.#end;
  }
  get offset() {
    return this.#offset;
  }
  byte() {
    if (this.#offset === this.#end) this.fail("unexpected end of module");
    return this.#bytes[this.#offset++];
  }
  u32() {
    return Number(this.#unsigned(32));
  }
  u64() {
    return this.#unsigned(64);
  }
  #unsigned(bits) {
    let value = 0n;
    const bytes = Math.ceil(bits / 7);
    for (let i = 0; i < bytes; i++) {
      const byte = this.byte();
      const payload = byte & 127;
      const remaining = bits - i * 7;
      if (remaining < 7 && payload >= 1 << remaining) {
        this.fail(`u${bits} LEB128 overflows`);
      }
      value |= BigInt(payload) << BigInt(i * 7);
      if (!(byte & 128)) return value;
    }
    this.fail(`u${bits} LEB128 is too long`);
  }
  // Heap types can be type indices encoded as s33. Their value is immaterial
  // here, but consuming the complete, bounded encoding lets us skip table and
  // global imports without parsing unrelated type sections.
  signed33(first) {
    let byte = first;
    for (let i = 0; i < 5; i++) {
      const payload = byte & 127;
      const remaining = 33 - i * 7;
      if (!(byte & 128)) {
        if (remaining < 7) {
          const used = (1 << remaining) - 1;
          const unused = 127 ^ used;
          const sign = 1 << remaining - 1;
          const extension = payload & sign ? unused : 0;
          if ((payload & unused) !== extension) {
            this.fail("s33 LEB128 overflows");
          }
        }
        return;
      }
      if (i === 4) this.fail("s33 LEB128 is too long");
      byte = this.byte();
    }
  }
  span() {
    const length = this.u32();
    const start2 = this.#offset;
    const end = start2 + length;
    if (end > this.#end) this.fail("span extends past its section");
    this.#offset = end;
    return new _Cursor(this.#bytes, start2, end);
  }
  text() {
    try {
      return text_decoder.decode(this.view());
    } catch {
      return this.fail("name is not valid UTF-8");
    }
  }
  view() {
    return this.#bytes.subarray(this.#offset, this.#end);
  }
  expect_done(what) {
    if (!this.done) this.fail(`trailing bytes in ${what}`);
  }
  fail(message) {
    throw new WasmParseError(message, this.#offset);
  }
};
function read_memory_type(bytes) {
  const flags = bytes.byte();
  if (flags & ~7) bytes.fail("unknown memory limits flags");
  const has_maximum = !!(flags & 1);
  const shared = !!(flags & 2);
  const address = flags & 4 ? "i64" : "i32";
  const read_limit = address === "i64" ? () => bytes.u64() : () => BigInt(bytes.u32());
  const minimum = read_limit();
  const maximum = has_maximum ? read_limit() : void 0;
  return { address, minimum, maximum, shared };
}
function skip_reference_type(bytes) {
  const type = bytes.byte();
  if (type === 99 || type === 100) {
    bytes.signed33(bytes.byte());
  } else if (type < 105 || type > 116) {
    bytes.fail("invalid reference type");
  }
}
function skip_value_type(bytes) {
  const type = bytes.byte();
  if (type >= 123 && type <= 127) return;
  if (type === 99 || type === 100) {
    bytes.signed33(bytes.byte());
  } else if (type < 105 || type > 116) {
    bytes.fail("invalid value type");
  }
}
function skip_limits(bytes) {
  const flags = bytes.byte();
  if (flags & ~5) bytes.fail("unknown limits flags");
  const read_limit = flags & 4 ? () => bytes.u64() : () => bytes.u32();
  read_limit();
  if (flags & 1) read_limit();
}
function read_imports(bytes, imports) {
  const count = bytes.u32();
  for (let i = 0; i < count; i++) {
    const module = bytes.span();
    const name = bytes.span();
    switch (bytes.byte()) {
      case 0:
        bytes.u32();
        break;
      case 1:
        skip_reference_type(bytes);
        skip_limits(bytes);
        break;
      case 2:
        imports.push({
          module: module.text(),
          name: name.text(),
          type: read_memory_type(bytes)
        });
        break;
      case 3:
        skip_value_type(bytes);
        if (bytes.byte() > 1) bytes.fail("invalid global mutability");
        break;
      case 4:
        if (bytes.byte() !== 0) bytes.fail("unknown tag attribute");
        bytes.u32();
        break;
      default:
        bytes.fail("unknown import type");
    }
  }
  bytes.expect_done("import section");
}
function read_definitions(bytes, definitions) {
  const count = bytes.u32();
  for (let i = 0; i < count; i++) definitions.push(read_memory_type(bytes));
  bytes.expect_done("memory section");
}
function read_wasm_memories(module) {
  const bytes = new Cursor(module);
  const header = [0, 97, 115, 109, 1, 0, 0, 0];
  for (const expected of header) {
    if (bytes.byte() !== expected) bytes.fail("invalid WebAssembly header");
  }
  const memories = { imports: [], definitions: [] };
  let saw_imports = false;
  let saw_definitions = false;
  while (!bytes.done) {
    const id = bytes.byte();
    const section = bytes.span();
    if (id === 2) {
      if (saw_imports) bytes.fail("duplicate import section");
      saw_imports = true;
      read_imports(section, memories.imports);
    } else if (id === 5) {
      if (saw_definitions) bytes.fail("duplicate memory section");
      saw_definitions = true;
      read_definitions(section, memories.definitions);
    }
  }
  return memories;
}

// src/kernel/wasm.ts
var supported_user_module_imports = /* @__PURE__ */ new Set([
  "env\0memory\0memory",
  "linux\0syscall\0function",
  "linux\0get_thread_area\0function",
  "linux\0copy_siginfo\0function",
  // LinuxOnTab: binaries built against the pre-7.1 ABI (all shipped packages)
  // fetch their argv/envp through these two host imports; see the compat
  // shims in worker.ts.
  "linux\0get_args_length\0function",
  "linux\0get_args\0function"
]);
function user_module_imports_supported(module) {
  return WebAssembly.Module.imports(module).every(
    ({ module: module2, name, kind }) => supported_user_module_imports.has(`${module2}\0${name}\0${kind}`)
  );
}
function allocate_shared_memory(initial_pages, preferred_maximum_pages, allocate = (descriptor) => new WebAssembly.Memory(descriptor)) {
  let maximum_pages = preferred_maximum_pages;
  for (; ; ) {
    try {
      return {
        memory: allocate({
          initial: initial_pages,
          maximum: maximum_pages,
          shared: true
        }),
        maximum_pages
      };
    } catch (error) {
      const smaller_maximum = Math.max(initial_pages, Math.floor(maximum_pages / 2));
      if (!(error instanceof RangeError) || smaller_maximum >= maximum_pages) {
        throw error;
      }
      maximum_pages = smaller_maximum;
    }
  }
}
function memory_bytes(memory, address, length) {
  try {
    const buffer = memory.buffer;
    const view_length = length ?? buffer.byteLength - address;
    if (!Number.isSafeInteger(address) || !Number.isSafeInteger(view_length) || address < 0 || view_length < 0 || view_length > buffer.byteLength || address > buffer.byteLength - view_length) {
      return null;
    }
    return new Uint8Array(buffer, address, view_length);
  } catch {
    return null;
  }
}
var WASM_USER_MEMORY_NONE = 0;
var WASM_USER_MEMORY_SHARE = 1;
var WASM_USER_MEMORY_COPY = 2;
var HALT_KERNEL = Symbol("halt kernel");
function kernel_imports({
  is_worker,
  memory,
  spawn_worker,
  boot_console_write,
  boot_console_close,
  terminate_machine,
  run_on_main,
  get_user_context,
  worker_exit
}) {
  return {
    breakpoint: () => {
      debugger;
    },
    halt_worker: () => {
      if (!is_worker) throw new Error("Halt called in main thread");
      worker_exit();
      platform.quit();
      throw HALT_KERNEL;
    },
    terminate_machine: (reason) => {
      if (!is_worker) {
        throw new Error("Machine termination called in main thread");
      }
      terminate_machine(reason);
      throw HALT_KERNEL;
    },
    boot_console_write: (msg, len) => {
      const address = msg >>> 0;
      const length = len >>> 0;
      boot_console_write(new Uint8Array(memory.buffer, address, length).slice().buffer);
    },
    boot_console_close,
    return_address: (_level) => {
      return 0;
    },
    get_now_nsec: () => {
      return BigInt(Math.round((performance.now() + performance.timeOrigin) * 200)) * 5000n;
    },
    get_stacktrace: (buf, size) => {
      const address = buf >>> 0;
      const capacity = size >>> 0;
      const trace = new TextEncoder().encode(new Error().stack?.split("\n").slice(5).join("\n"));
      if (trace.byteLength > capacity && capacity >= 3) {
        trace[capacity - 1] = 46;
        trace[capacity - 2] = 46;
        trace[capacity - 3] = 46;
      }
      new Uint8Array(memory.buffer).set(trace.subarray(0, capacity), address);
    },
    spawn_worker: (fn, arg, comm, comm_len, user_memory) => {
      const comm_address = comm >>> 0;
      const comm_length = comm_len >>> 0;
      const name = new TextDecoder().decode(
        new Uint8Array(memory.buffer, comm_address, comm_length).slice()
        // copy to transfer to non-shared backing
      );
      let user = null;
      let copy_user_memory = false;
      if (user_memory !== WASM_USER_MEMORY_NONE) {
        const context = get_user_context();
        if (!context) return -22;
        switch (user_memory) {
          case WASM_USER_MEMORY_SHARE:
            user = context;
            break;
          case WASM_USER_MEMORY_COPY:
            user = context;
            copy_user_memory = true;
            break;
          default:
            return -22;
        }
      }
      return spawn_worker(fn, arg, name, user, copy_user_memory);
    },
    run_on_main
  };
}

// src/kernel/worker.ts
var unavailable = () => {
  throw new Error("not available on worker thread");
};
var endpoint = platform.worker_endpoint();
var postMessage = (message, transfer) => post_endpoint(endpoint, message, transfer);
function user_imports({
  kernel_memory,
  get_kernel_instance,
  parent_user: parent
}) {
  const HALT_USER = Symbol("halt user");
  const NR_WASM_GET_ARGS = 245;
  let context = parent;
  let instance = null;
  let pending_module_bytes = null;
  let pending = null;
  const siginfo_copy_results = [];
  function copy_bytes(destination_memory, destination, source_memory, source, length) {
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
  function user_atomic_word(uaddr) {
    const address = uaddr >>> 0;
    if (!context || (address & 3) !== 0) return null;
    const bytes = memory_bytes(context.memory, address, Int32Array.BYTES_PER_ELEMENT);
    return bytes ? new Int32Array(bytes.buffer, bytes.byteOffset, 1) : null;
  }
  function write_kernel_u32(addr, value) {
    const bytes = memory_bytes(kernel_memory, addr >>> 0, Uint32Array.BYTES_PER_ELEMENT);
    if (!bytes) return false;
    new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).setUint32(0, value, true);
    return true;
  }
  function call_start() {
    assert(instance);
    const { _start } = instance.exports;
    assert(typeof _start === "function", "_start not found");
    _start();
    throw new Error("_start reached the end without exiting");
  }
  let call_entry = call_start;
  function create_instance(context2) {
    const kernel_instance = get_kernel_instance();
    return new WebAssembly.Instance(context2.module, {
      env: { memory: context2.memory },
      linux: {
        syscall: (nr, arg0, arg1, arg2, arg3, arg4, arg5) => {
          const original_instance = instance;
          const ret = kernel_instance.exports.syscall(nr, arg0, arg1, arg2, arg3, arg4, arg5);
          if (instance !== original_instance) {
            call_entry = call_start;
            throw HALT_USER;
          }
          return ret;
        },
        get_thread_area: kernel_instance.exports.get_thread_area,
        // LinuxOnTab compat for pre-7.1 binaries (every shipped package): their
        // crt1 calls get_args_length() (size only) and then get_args(buf) to
        // receive {len, envc, argc, argv, envp, data[]} relocated to buf — the
        // exact block 7.1's wasm_get_args syscall writes. The size comes from
        // a small kernel export (the syscall has no size query); the copy is
        // the syscall itself, which consumes exec_args like the old export did.
        get_args_length: () => kernel_instance.exports.get_args_length(),
        get_args: (buf) => kernel_instance.exports.syscall(NR_WASM_GET_ARGS, buf >>> 0, 262144, 0, 0, 0, 0),
        copy_siginfo: (to) => {
          const result = kernel_instance.exports.copy_siginfo(to);
          const current = siginfo_copy_results.length - 1;
          if (current >= 0) siginfo_copy_results[current] = result;
          return result;
        }
      }
    });
  }
  function instantiate(fresh_memory) {
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
          return -12;
        }
      },
      compile_write(buf, offset, size) {
        const source = buf >>> 0;
        const destination = offset >>> 0;
        const length = size >>> 0;
        const kernel_buffer = kernel_memory.buffer;
        if (!pending_module_bytes || source > kernel_buffer.byteLength - length || destination > pending_module_bytes.length - length) {
          return -22;
        }
        pending_module_bytes.set(new Uint8Array(kernel_buffer, source, length), destination);
        return 0;
      },
      compile_end(maximum_memory_pages) {
        const bytes = pending_module_bytes;
        pending_module_bytes = null;
        if (!bytes) return -22;
        const rlimit_pages = maximum_memory_pages >>> 0;
        let module;
        let minimum;
        let maximum;
        try {
          const memories = read_wasm_memories(bytes);
          const memory_import = memories.imports[0];
          if (memories.definitions.length !== 0 || memories.imports.length !== 1 || !memory_import || memory_import.module !== "env" || memory_import.name !== "memory" || memory_import.type.address !== "i32" || !memory_import.type.shared || memory_import.type.maximum === void 0) {
            return -8;
          }
          module = new WebAssembly.Module(bytes);
          if (!user_module_imports_supported(module)) {
            return -8;
          }
          minimum = Number(memory_import.type.minimum);
          maximum = Math.min(Number(memory_import.type.maximum), rlimit_pages);
        } catch {
          return -8;
        }
        if (maximum < minimum) return -12;
        let allocated;
        try {
          allocated = allocate_shared_memory(minimum, maximum);
        } catch {
          return -12;
        }
        const next_context = { module, ...allocated };
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
        for (; ; ) {
          try {
            call_entry();
          } catch (error) {
            if (error === HALT_USER) continue;
            if (error === HALT_KERNEL) throw error;
            console.error("error running user module:", error);
            return;
          }
        }
      },
      switch_entry(fn, arg) {
        assert(parent);
        call_entry = () => {
          assert(instance);
          const { __indirect_function_table } = instance.exports;
          assert(__indirect_function_table instanceof WebAssembly.Table, "Invalid function table");
          const f = __indirect_function_table.get(fn >>> 0);
          assert(typeof f === "function" && f.length === 1, "Invalid function signature");
          f(arg);
          console.warn("thread entrypoint reached the end without exiting");
        };
      },
      // signal handling:
      call_signal_handler(fn, sig) {
        assert(instance);
        const { __indirect_function_table } = instance.exports;
        assert(__indirect_function_table instanceof WebAssembly.Table, "Invalid function table");
        const f = __indirect_function_table.get(fn >>> 0);
        assert(typeof f === "function" && f.length === 1, "Invalid function signature");
        f(sig);
      },
      call_siginfo_handler(trampoline, fn, sig) {
        assert(instance);
        const { __indirect_function_table } = instance.exports;
        assert(__indirect_function_table instanceof WebAssembly.Table, "Invalid function table");
        const f = __indirect_function_table.get(trampoline >>> 0);
        assert(typeof f === "function" && f.length === 2, "Invalid siginfo trampoline");
        siginfo_copy_results.push(null);
        try {
          f(fn, sig);
          return siginfo_copy_results.at(-1) ?? -22;
        } finally {
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
        if (!word) return -14;
        let old;
        switch (op) {
          case 0:
            old = Atomics.exchange(word, 0, oparg);
            break;
          case 1:
            old = Atomics.add(word, 0, oparg);
            break;
          case 2:
            old = Atomics.or(word, 0, oparg);
            break;
          case 3:
            old = Atomics.and(word, 0, ~oparg);
            break;
          case 4:
            old = Atomics.xor(word, 0, oparg);
            break;
          default:
            return -38;
        }
        return write_kernel_u32(oldval, old) ? 0 : -14;
      },
      futex_atomic_cmpxchg(oldval, uaddr, expected, replacement) {
        const word = user_atomic_word(uaddr);
        if (!word) return -14;
        const old = Atomics.compareExchange(word, 0, expected, replacement);
        return write_kernel_u32(oldval, old) ? 0 : -14;
      }
    }
  };
}
function start({
  fn,
  arg,
  vmlinux,
  memory,
  user: initial_user_context,
  user_copy_status
}) {
  memory.grow(0);
  initial_user_context?.memory.grow(0);
  let user_context = initial_user_context;
  if (user_copy_status) {
    assert(user_context);
    try {
      const source = memory_bytes(user_context.memory, 0);
      if (!source) throw new RangeError("invalid source memory");
      const copied = allocate_shared_memory(
        source.byteLength / 65536,
        user_context.maximum_pages
      );
      const destination = memory_bytes(copied.memory, 0, source.byteLength);
      if (!destination) throw new RangeError("invalid destination memory");
      destination.set(source);
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
  const user = user_imports({
    kernel_memory: memory,
    get_kernel_instance: () => instance,
    parent_user: user_context
  });
  const imports = {
    env: { memory },
    boot: {
      get_devicetree: unavailable,
      get_initramfs: unavailable
    },
    user: user.imports,
    kernel: kernel_imports({
      is_worker: true,
      memory,
      spawn_worker(fn2, arg2, name, user2, copy_user_memory) {
        const direct = new MessageChannel();
        postMessage(
          {
            type: "spawn_worker",
            name,
            port: direct.port1
          },
          [direct.port1]
        );
        const user_copy_status2 = copy_user_memory ? new Int32Array(new SharedArrayBuffer(4)) : null;
        direct.port2.postMessage({
          type: "init",
          fn: fn2,
          arg: arg2,
          vmlinux,
          memory,
          user: user2,
          user_copy_status: user_copy_status2
        });
        if (!user_copy_status2) return 0;
        Atomics.wait(user_copy_status2, 0, 0);
        const result = Atomics.load(user_copy_status2, 0);
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
      run_on_main(fn2, arg2) {
        postMessage({ type: "run_on_main", fn: fn2, arg: arg2 });
      },
      get_user_context() {
        return user.context;
      },
      worker_exit() {
        postMessage({ type: "worker_exit" });
      }
    }),
    virtio: {
      set_features: unavailable,
      setup: unavailable,
      reset: unavailable,
      enable_vring: unavailable,
      disable_vring: unavailable,
      notify: unavailable
    }
  };
  const instance = new WebAssembly.Instance(vmlinux, imports);
  user.prepare();
  try {
    instance.exports.__indirect_function_table.get(fn >>> 0)(arg);
  } catch (error) {
    if (error === HALT_KERNEL) return;
    throw error;
  }
}
listen_endpoint(endpoint, {
  message(raw) {
    const message = raw;
    if (message.type === "forwarded_init") {
      message.port.onmessage = ({ data }) => {
        message.port.close();
        start(data);
      };
      message.port.start();
      return;
    }
    start(message);
  }
});
