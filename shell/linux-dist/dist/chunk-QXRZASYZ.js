var __toBinary = /* @__PURE__ */ (() => {
  var table = new Uint8Array(128);
  for (var i = 0; i < 64; i++) table[i < 26 ? i + 65 : i < 52 ? i + 71 : i < 62 ? i - 4 : i * 4 - 205] = i;
  return (base64) => {
    var n = base64.length, bytes = new Uint8Array((n - (base64[n - 1] == "=") - (base64[n - 2] == "=")) * 3 / 4 | 0);
    for (var i2 = 0, j = 0; i2 < n; ) {
      var c0 = table[base64.charCodeAt(i2++)], c1 = table[base64.charCodeAt(i2++)];
      var c2 = table[base64.charCodeAt(i2++)], c3 = table[base64.charCodeAt(i2++)];
      bytes[j++] = c0 << 2 | c1 >> 4;
      bytes[j++] = c1 << 4 | c2 >> 2;
      bytes[j++] = c2 << 6 | c3;
    }
    return bytes;
  };
})();

// src/util.ts
function assert(cond, message = "Assertation failed") {
  if (!cond) throw new Error(message);
}
function unreachable(_, message = "Unreachable reached") {
  throw new Error(message);
}
function get_script_path(fn, import_meta) {
  const match = fn.toString().match(/import\("(.*)"\)/)?.[1];
  assert(match, "Could not find imported path");
  return new URL(match, import_meta.url);
}
var EventEmitter = class {
  #subscribers = {};
  on(event, handler) {
    (this.#subscribers[event] ??= /* @__PURE__ */ new Set()).add(handler);
  }
  off(event, handler) {
    this.#subscribers[event]?.delete(handler);
  }
  emit(event, data) {
    this.#subscribers[event]?.forEach((handler) => handler(data));
  }
};

// src/wasm.ts
var HALT_KERNEL = Symbol("halt kernel");
function kernel_imports({
  is_worker,
  memory,
  spawn_worker,
  boot_console_write,
  boot_console_close,
  run_on_main,
  get_user_module,
  get_user_memory
}) {
  const mem = new Uint8Array(memory.buffer);
  return {
    breakpoint: () => {
      debugger;
    },
    halt_worker: () => {
      if (!is_worker) throw new Error("Halt called in main thread");
      self.close();
      throw HALT_KERNEL;
    },
    boot_console_write: (msg, len) => {
      boot_console_write(memory.buffer.slice(msg, msg + len));
    },
    boot_console_close,
    return_address: (_level) => {
      return 0;
    },
    get_now_nsec: () => {
      return BigInt(
        Math.round((performance.now() + performance.timeOrigin) * 200)
      ) * 5000n;
    },
    get_stacktrace: (buf, size) => {
      const trace = new TextEncoder().encode(
        new Error().stack?.split("\n").slice(5).join("\n")
      );
      if (trace.byteLength > size) {
        trace[size - 1] = 46;
        trace[size - 2] = 46;
        trace[size - 3] = 46;
      }
      mem.set(trace.slice(0, size), buf);
    },
    spawn_worker: (fn, arg, comm, comm_len, share_user_memory) => {
      const name = new TextDecoder().decode(
        mem.slice(comm, comm + comm_len)
      );
      spawn_worker(
        fn,
        arg,
        name,
        share_user_memory ? get_user_module() : null,
        share_user_memory ? get_user_memory() : null
      );
    },
    run_on_main
  };
}

export {
  __toBinary,
  assert,
  unreachable,
  get_script_path,
  EventEmitter,
  HALT_KERNEL,
  kernel_imports
};
//# sourceMappingURL=chunk-QXRZASYZ.js.map
