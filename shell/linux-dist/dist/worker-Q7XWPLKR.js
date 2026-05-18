import {
  HALT_KERNEL,
  assert,
  kernel_imports
} from "./chunk-QXRZASYZ.js";

// src/worker.ts
var unavailable = () => {
  throw new Error("not available on worker thread");
};
var postMessage = self.postMessage;
function user_imports({
  kernel_memory,
  get_kernel_instance,
  parent_user_module: parent_module,
  parent_user_memory: parent_memory
}) {
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
        const bytes = new Uint8Array(
          kernel_memory_buffer.slice(buf, buf + size)
        );
        try {
          module = new WebAssembly.Module(bytes);
          return 0;
        } catch {
          return -8;
        }
      },
      instantiate(fresh_memory) {
        assert(module);
        if (fresh_memory || !memory) {
          const size = 2048 + Math.floor(Math.random() * 1e3);
          memory = new WebAssembly.Memory({
            initial: size,
            maximum: size,
            shared: true
          });
        }
        const kernel_instance = get_kernel_instance();
        try {
          instance = new WebAssembly.Instance(module, {
            env: { memory },
            linux: {
              syscall: (nr, arg0, arg1, arg2, arg3, arg4, arg5) => {
                const original_instance = instance;
                const ret = kernel_instance.exports.syscall(
                  nr,
                  arg0,
                  arg1,
                  arg2,
                  arg3,
                  arg4,
                  arg5
                );
                if (instance !== original_instance) {
                  call_entry = call_start;
                  throw HALT_USER;
                }
                return ret;
              },
              get_thread_area: kernel_instance.exports.get_thread_area,
              get_args_length: kernel_instance.exports.get_args_length,
              get_args: kernel_instance.exports.get_args
            }
          });
          if ("memory" in instance.exports) {
            assert(instance.exports.memory instanceof WebAssembly.Memory);
            memory = instance.exports.memory;
          }
        } catch (error) {
          console.log("error instantiating user module:", String(error));
        }
      },
      call() {
        for (; ; ) {
          try {
            call_entry();
          } catch (error) {
            if (error === HALT_USER) continue;
            if (error === HALT_KERNEL) throw error;
            console.log("error running user module:", String(error));
            return;
          }
        }
      },
      switch_entry(fn, arg) {
        assert(parent_module);
        assert(parent_memory);
        module = parent_module;
        memory = parent_memory;
        call_entry = () => {
          assert(instance);
          const { __indirect_function_table } = instance.exports;
          assert(
            __indirect_function_table instanceof WebAssembly.Table,
            "Invalid function table"
          );
          const f = __indirect_function_table.get(fn);
          assert(
            typeof f === "function" && f.length === 1,
            "Invalid function signature"
          );
          f(arg);
          console.warn("thread entrypoint reached the end without exiting");
        };
      },
      // signal handling:
      call_signal_handler(fn, sig) {
        assert(instance);
        const { __indirect_function_table } = instance.exports;
        assert(
          __indirect_function_table instanceof WebAssembly.Table,
          "Invalid function table"
        );
        const f = __indirect_function_table.get(fn);
        assert(
          typeof f === "function" && f.length === 1,
          "Invalid function signature"
        );
        f(sig);
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
      }
    }
  };
}
self.onmessage = (event) => {
  const { fn, arg, vmlinux, memory, parent_user_module, parent_user_memory } = event.data;
  const user = user_imports({
    kernel_memory: memory,
    get_kernel_instance: () => instance,
    parent_user_module,
    parent_user_memory
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
      spawn_worker(fn2, arg2, name, user_module, user_memory) {
        postMessage({
          type: "spawn_worker",
          fn: fn2,
          arg: arg2,
          name,
          user_module,
          user_memory
        });
      },
      boot_console_write(message) {
        postMessage({ type: "boot_console_write", message });
      },
      boot_console_close() {
        postMessage({ type: "boot_console_close" });
      },
      run_on_main(fn2, arg2) {
        postMessage({ type: "run_on_main", fn: fn2, arg: arg2 });
      },
      get_user_module() {
        return user.module;
      },
      get_user_memory() {
        return user.memory;
      }
    }),
    virtio: {
      set_features: unavailable,
      setup: unavailable,
      enable_vring: unavailable,
      disable_vring: unavailable,
      notify: unavailable
    }
  };
  const instance = new WebAssembly.Instance(vmlinux, imports);
  try {
    instance.exports.__indirect_function_table.get(fn)(arg);
  } catch (error) {
    if (error === HALT_KERNEL) return;
    throw error;
  }
};
//# sourceMappingURL=worker-Q7XWPLKR.js.map
