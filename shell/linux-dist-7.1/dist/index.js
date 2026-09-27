// src/bytes/index.ts
function assert(condition) {
  if (!condition) throw new Error("Assertion failed");
}
var utf8 = new TextDecoder("utf-8", { fatal: true });
function Struct(layout) {
  let size = 0;
  return class {
    #dv;
    constructor(view) {
      this.#dv = new DataView(view.buffer, view.byteOffset, view.byteLength);
    }
    static {
      for (const [key, type] of Object.entries(layout)) {
        const offset = size;
        Object.defineProperty(this.prototype, key, {
          get() {
            return type.get(this.#dv, offset);
          },
          set(value) {
            type.set(this.#dv, offset, value);
          }
        });
        size += type.size;
      }
    }
    static get(dv, offset) {
      if (offset !== 0) dv = new DataView(dv.buffer, dv.byteOffset + offset);
      return new this(dv);
    }
    static set(dv, offset, value) {
      if (offset !== 0) dv = new DataView(dv.buffer, dv.byteOffset + offset);
      Object.assign(new this(dv), value);
    }
    static size = size;
    toJSON() {
      const obj = {};
      for (const key in layout) {
        obj[key] = this[key];
      }
      return obj;
    }
  };
}
function FixedArray(type, length) {
  assert(Number.isInteger(length) && length > 0);
  return {
    get(dv, offset) {
      const arr = Array(length);
      for (let i = 0; i < length; i++) {
        const element_offset = offset + type.size * i;
        let value = type.get(dv, element_offset);
        Object.defineProperty(arr, i, {
          enumerable: true,
          get: () => value,
          set: (next) => {
            type.set(dv, element_offset, next);
            value = type.get(dv, element_offset);
          }
        });
      }
      Object.freeze(arr);
      return arr;
    },
    set(dv, offset, value) {
      for (let i = 0; i < length; i++) {
        type.set(dv, offset + type.size * i, value[i]);
      }
    },
    size: type.size * length
  };
}
var U8 = {
  get(dv, offset) {
    return dv.getUint8(offset);
  },
  set(dv, offset, value) {
    dv.setUint8(offset, value);
  },
  size: 1
};
var U16LE = {
  get(dv, offset) {
    return dv.getUint16(offset, true);
  },
  set(dv, offset, value) {
    dv.setUint16(offset, value, true);
  },
  size: 2
};
var U32LE = {
  get(dv, offset) {
    return dv.getUint32(offset, true);
  },
  set(dv, offset, value) {
    dv.setUint32(offset, value, true);
  },
  size: 4
};
var I32LE = {
  get(dv, offset) {
    return dv.getInt32(offset, true);
  },
  set(dv, offset, value) {
    dv.setInt32(offset, value, true);
  },
  size: 4
};
var U64LE = {
  get(dv, offset) {
    return dv.getBigUint64(offset, true);
  },
  set(dv, offset, value) {
    dv.setBigUint64(offset, value, true);
  },
  size: 8
};
var U16BE = {
  get(dv, offset) {
    return dv.getUint16(offset, false);
  },
  set(dv, offset, value) {
    dv.setUint16(offset, value, false);
  },
  size: 2
};
var U32BE = {
  get(dv, offset) {
    return dv.getUint32(offset, false);
  },
  set(dv, offset, value) {
    dv.setUint32(offset, value, false);
  },
  size: 4
};
var U64BE = {
  get(dv, offset) {
    return dv.getBigUint64(offset, false);
  },
  set(dv, offset, value) {
    dv.setBigUint64(offset, value, false);
  },
  size: 8
};
var Reader = class {
  #array;
  #dv;
  /** The number of bytes consumed so far. */
  offset = 0;
  constructor(array) {
    this.#array = array;
    this.#dv = new DataView(array.buffer, array.byteOffset, array.byteLength);
  }
  #take(length) {
    if (length < 0 || this.offset + length > this.#array.byteLength) {
      throw new RangeError("read past the end of the buffer");
    }
    const offset = this.offset;
    this.offset += length;
    return offset;
  }
  u8() {
    return this.#dv.getUint8(this.#take(1));
  }
  u16() {
    return this.#dv.getUint16(this.#take(2), true);
  }
  u32() {
    return this.#dv.getUint32(this.#take(4), true);
  }
  i32() {
    return this.#dv.getInt32(this.#take(4), true);
  }
  u64() {
    return this.#dv.getBigUint64(this.#take(8), true);
  }
  i64() {
    return this.#dv.getBigInt64(this.#take(8), true);
  }
  skip(length) {
    this.#take(length);
  }
  bytes(length) {
    const offset = this.#take(length);
    return this.#array.subarray(offset, offset + length);
  }
  /** Reads a `Type` at the current position and advances past it. */
  struct(type) {
    return type.get(this.#dv, this.#take(type.size));
  }
  /** Reads a NUL-terminated UTF-8 string, consuming the terminator. */
  cstring() {
    const end = this.#array.indexOf(0, this.offset);
    if (end < 0) throw new RangeError("unterminated string");
    const bytes = this.bytes(end - this.offset);
    this.skip(1);
    try {
      return utf8.decode(bytes);
    } catch {
      throw new RangeError("string is not valid UTF-8");
    }
  }
};
var Bytes = class {
  #array;
  length = 0;
  get capacity() {
    return this.#array.length;
  }
  get array() {
    return this.#array.slice(0, this.length);
  }
  constructor(capacity = 32) {
    this.#array = new Uint8Array(capacity);
  }
  #ensure_capacity(capacity) {
    if (this.#array.length < capacity) {
      let length = this.#array.length;
      while (length < capacity) length *= 2;
      const next = new Uint8Array(length);
      next.set(this.#array);
      this.#array = next;
      this.#dv = void 0;
    }
  }
  bump(length) {
    const offset = this.length;
    this.#ensure_capacity(this.length + length);
    this.length += length;
    return offset;
  }
  append(bytes) {
    const offset = this.bump(bytes.length);
    this.#array.set(bytes, offset);
  }
  #dv;
  get dv() {
    return this.#dv ??= new DataView(this.#array.buffer);
  }
  alloc(type) {
    const offset = this.bump(type.size);
    const self2 = this;
    return {
      get value() {
        return type.get(self2.dv, offset);
      },
      set value(value) {
        type.set(self2.dv, offset, value);
      }
    };
  }
};

// src/kernel/util.ts
function assert2(cond, message = "Assertation failed") {
  if (!cond) throw new Error(message);
}
function unreachable(_, message = "Unreachable reached") {
  throw new Error(message);
}

// src/kernel/devicetree.ts
var FDT_MAGIC = 3490578157;
var FDT_BEGIN_NODE = 1;
var FDT_END_NODE = 2;
var FDT_PROP = 3;
var FDT_END = 9;
var NODE_NAME_MAX_LEN = 31;
var PROPERTY_NAME_MAX_LEN = 31;
var FdtHeader = Struct({
  magic: U32BE,
  totalsize: U32BE,
  off_dt_struct: U32BE,
  off_dt_strings: U32BE,
  off_mem_rsvmap: U32BE,
  version: U32BE,
  last_comp_version: U32BE,
  boot_cpuid_phys: U32BE,
  size_dt_strings: U32BE,
  size_dt_struct: U32BE
});
var FdtReserveEntry = Struct({
  address: U64BE,
  size: U64BE
});
var Property = Struct({
  len: U32BE,
  nameoff: U32BE
});
function align(bytes, alignment) {
  const offset = bytes.length % alignment;
  if (offset !== 0) {
    for (let j = 0; j < alignment - offset; j++) bytes.alloc(U8);
  }
}
function generate_devicetree(tree, {
  memory_reservations = [],
  boot_cpu_id = 0
} = {}) {
  const bytes = new Bytes(1024);
  const strings = {};
  const header = bytes.alloc(FdtHeader);
  function walk_tree(node2, name) {
    align(bytes, 4);
    bytes.alloc(U32BE).value = FDT_BEGIN_NODE;
    const encodedName = new TextEncoder().encode(name);
    assert2(encodedName.byteLength <= NODE_NAME_MAX_LEN, `property name too long: ${name}`);
    bytes.append(encodedName);
    bytes.alloc(U8).value = 0;
    align(bytes, 4);
    const children = Object.entries(node2).filter(
      ([, value]) => typeof value === "object" && value?.constructor === Object
    );
    const properties = Object.entries(node2).filter(
      ([, value]) => !(typeof value === "object" && value?.constructor === Object)
    );
    for (const [name2, prop] of properties) {
      align(bytes, 4);
      bytes.alloc(U32BE).value = FDT_PROP;
      const property = bytes.alloc(Property);
      assert2(
        new TextEncoder().encode(name2).byteLength <= PROPERTY_NAME_MAX_LEN,
        `property name too long: ${name2}`
      );
      (strings[name2] ??= []).push(property);
      let value;
      switch (typeof prop) {
        case "number":
          value = new Uint32Array(1).buffer;
          new DataView(value).setUint32(0, prop);
          break;
        case "bigint":
          value = new BigUint64Array(1).buffer;
          new DataView(value).setBigUint64(0, prop);
          break;
        case "string":
          value = new TextEncoder().encode(`${prop}\0`).buffer;
          break;
        case "object":
          if (prop instanceof Uint8Array || prop instanceof Uint16Array || prop instanceof Uint32Array || prop instanceof BigUint64Array) {
            value = prop.buffer;
          } else if (prop instanceof ArrayBuffer) {
            value = prop;
          } else {
            value = new Uint32Array(prop.length).buffer;
            const dv = new DataView(value);
            for (const [i, n] of prop.entries()) {
              dv.setUint32(i * 4, n);
            }
          }
          break;
        case "undefined":
          value = new Uint8Array().buffer;
          break;
        default:
          unreachable(prop, `unsupported prop type: ${typeof prop}`);
      }
      property.value.len = value.byteLength;
      bytes.append(new Uint8Array(value));
      align(bytes, 4);
    }
    for (const [name2, child] of children) walk_tree(child, name2);
    align(bytes, 4);
    bytes.alloc(U32BE).value = FDT_END_NODE;
  }
  Object.assign(header.value, {
    magic: FDT_MAGIC,
    version: 17,
    last_comp_version: 16,
    boot_cpuid_phys: boot_cpu_id
  });
  align(bytes, 8);
  header.value.off_mem_rsvmap = bytes.length;
  for (const { address, size } of memory_reservations) {
    bytes.alloc(FdtReserveEntry).value = {
      address: BigInt(address),
      size: BigInt(size)
    };
  }
  bytes.alloc(FdtReserveEntry).value = { address: 0n, size: 0n };
  const begin_dt_struct = bytes.length;
  header.value.off_dt_struct = begin_dt_struct;
  walk_tree(tree, "");
  bytes.alloc(U32BE).value = FDT_END;
  header.value.size_dt_struct = bytes.length - begin_dt_struct;
  const begin_dt_strings = bytes.length;
  header.value.off_dt_strings = begin_dt_strings;
  for (const [str, refs] of Object.entries(strings)) {
    const offset = bytes.length;
    bytes.append(new TextEncoder().encode(str));
    bytes.alloc(U8).value = 0;
    for (const ref of refs) ref.value.nameoff = offset - begin_dt_strings;
  }
  header.value.size_dt_strings = bytes.length - begin_dt_strings;
  header.value.totalsize = bytes.length;
  return bytes.array;
}

// src/kernel/endpoint.ts
var as_error = (value, fallback) => value instanceof Error ? value : new Error(fallback);
function listen_endpoint(endpoint, handlers) {
  if ("addEventListener" in endpoint) {
    const on_message2 = (event) => handlers.message(event.data);
    const on_message_error2 = (_event) => handlers.error?.(new Error("could not deserialize endpoint message"));
    const on_error2 = (event) => {
      event.preventDefault();
      handlers.error?.(as_error(event.error, event.message || "worker failed"));
    };
    endpoint.addEventListener("message", on_message2);
    if (handlers.error) {
      endpoint.addEventListener("messageerror", on_message_error2);
      endpoint.addEventListener("error", on_error2);
    }
    return () => {
      endpoint.removeEventListener("message", on_message2);
      if (handlers.error) {
        endpoint.removeEventListener("messageerror", on_message_error2);
        endpoint.removeEventListener("error", on_error2);
      }
    };
  }
  const on_message = (message) => handlers.message(message);
  const on_message_error = (error) => handlers.error?.(as_error(error, "could not deserialize endpoint message"));
  const on_error = (error) => handlers.error?.(as_error(error, "worker failed"));
  endpoint.on("message", on_message);
  if (handlers.error) {
    endpoint.on("messageerror", on_message_error);
    endpoint.on("error", on_error);
  }
  return () => {
    endpoint.off("message", on_message);
    if (handlers.error) {
      endpoint.off("messageerror", on_message_error);
      endpoint.off("error", on_error);
    }
  };
}
function post_endpoint(endpoint, message, transfer) {
  endpoint.postMessage(message, transfer);
}

// src/kernel/platform.ts
function worker_handle(endpoint, terminate, handlers) {
  const stop_listening = listen_endpoint(endpoint, {
    message: handlers.on_message,
    error: handlers.on_error
  });
  return {
    post: (message, transfer) => post_endpoint(endpoint, message, transfer),
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
      assert2(parentPort, "not in a worker");
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

// src/kernel/plugin.ts
var getMachinePlugin = Symbol("getMachinePlugin");

// src/kernel/virtio/core.ts
var TransportFeatures = {
  VERSION_1: 1n << 32n,
  RING_PACKED: 1n << 34n,
  INDIRECT_DESC: 1n << 28n
};
var DescriptorFlags = {
  NEXT: 1 << 0,
  WRITE: 1 << 1,
  INDIRECT: 1 << 2,
  AVAIL: 1 << 7,
  USED: 1 << 15
};
var VirtqDescriptor = class extends Struct({
  addr: U64LE,
  len: U32LE,
  id: U16LE,
  flags: U16LE
}) {
};
var Chain = class {
  #buffers;
  #release;
  constructor(memory, desc, release) {
    this.#buffers = desc.map((descriptor) => {
      const address = Number(descriptor.addr);
      const target = new Uint8Array(memory.buffer, address, descriptor.len);
      const writable = (descriptor.flags & DescriptorFlags.WRITE) !== 0;
      return writable ? { array: target.slice(), writable, address } : { array: target.slice(), writable };
    });
    this.#release = release;
  }
  release(written) {
    this.#release(
      written,
      this.#buffers.flatMap(
        ({ address, array }) => address === void 0 ? [] : [{ address, data: array }]
      )
    );
  }
  *[Symbol.iterator]() {
    yield* this.#buffers;
  }
};
function publish_virtqueue_completion(memory, completion) {
  for (const { address, data } of completion.outputs) {
    new Uint8Array(memory.buffer, address, data.byteLength).set(data);
  }
  const descriptor = VirtqDescriptor.get(
    new DataView(memory.buffer),
    completion.descriptor_address
  );
  descriptor.id = completion.id;
  descriptor.len = completion.written;
  descriptor.flags = completion.flags;
}
var PackedVirtqueue = class {
  #memory;
  #size;
  #desc_addr;
  #publish;
  #is_current;
  #avail_wrap = true;
  #used_wrap = true;
  #used_idx = 0;
  #avail_idx = 0;
  #valid = true;
  constructor(memory, size, desc_addr, publish, is_current = () => true) {
    assert2(size !== 0);
    this.#memory = memory;
    this.#size = size;
    this.#desc_addr = desc_addr;
    this.#publish = publish;
    this.#is_current = is_current;
  }
  invalidate() {
    this.#valid = false;
  }
  #descriptor(index) {
    const desc = VirtqDescriptor.get(
      new DataView(this.#memory.buffer),
      this.#desc_addr + VirtqDescriptor.size * index
    );
    return {
      addr: desc.addr,
      len: desc.len,
      id: desc.id,
      flags: desc.flags
    };
  }
  #indirect_descriptors(address, count) {
    const descriptors = [];
    for (let i = 0; i < count; i++) {
      const desc = VirtqDescriptor.get(
        new DataView(this.#memory.buffer),
        address + VirtqDescriptor.size * i
      );
      descriptors.push({
        addr: desc.addr,
        len: desc.len,
        id: desc.id,
        flags: desc.flags
      });
    }
    return descriptors;
  }
  #pop() {
    let i = this.#advance();
    if (i === null) return null;
    let desc = this.#descriptor(i);
    const id = desc.id;
    let skip = 1;
    let chain_desc = [desc];
    if (desc.flags & DescriptorFlags.NEXT) {
      do {
        i = this.#advance();
        if (i === null) throw new Error("no next descriptor is available");
        desc = this.#descriptor(i);
        chain_desc.push(desc);
        skip += 1;
      } while (desc.flags & DescriptorFlags.NEXT);
    } else if (desc.flags & DescriptorFlags.INDIRECT) {
      if (desc.len % VirtqDescriptor.size !== 0) {
        throw new Error("malformed indirect buffer");
      }
      chain_desc = this.#indirect_descriptors(Number(desc.addr), desc.len / VirtqDescriptor.size);
    }
    const chain = new Chain(
      this.#memory,
      chain_desc,
      (written, outputs) => this.#release(id, skip, written, outputs)
    );
    return this.#is_current() ? chain : null;
  }
  *[Symbol.iterator]() {
    let chain;
    while (this.#valid && this.#is_current() && (chain = this.#pop())) yield chain;
  }
  #advance() {
    const desc = this.#descriptor(this.#avail_idx);
    const avail = (desc.flags & DescriptorFlags.AVAIL) !== 0;
    const used = (desc.flags & DescriptorFlags.USED) !== 0;
    if (avail === used || avail !== this.#avail_wrap) return null;
    const index = this.#avail_idx;
    this.#avail_idx += 1;
    if (this.#avail_idx >= this.#size) {
      this.#avail_idx = 0;
      this.#avail_wrap = !this.#avail_wrap;
    }
    return index;
  }
  #release(id, skip, written, outputs) {
    if (!this.#valid || !this.#is_current()) return;
    const desc = VirtqDescriptor.get(
      new DataView(this.#memory.buffer),
      this.#desc_addr + VirtqDescriptor.size * this.#used_idx
    );
    const avail = (desc.flags & DescriptorFlags.AVAIL) !== 0;
    const used = (desc.flags & DescriptorFlags.USED) !== 0;
    if (avail === used || avail !== this.#used_wrap) {
      throw new Error("ring full");
    }
    let flags = 0;
    if (this.#used_wrap) flags |= DescriptorFlags.AVAIL | DescriptorFlags.USED;
    if (written > 0) flags |= DescriptorFlags.WRITE;
    const completion = {
      descriptor_address: this.#desc_addr + VirtqDescriptor.size * this.#used_idx,
      id,
      written,
      flags,
      outputs
    };
    this.#used_idx += skip;
    if (this.#used_idx >= this.#size) {
      this.#used_idx -= this.#size;
      this.#used_wrap = !this.#used_wrap;
    }
    this.#publish(completion);
  }
};
var transport_device = Symbol("virtio transport device");
function create_virtio_device(endpoint) {
  const device = {};
  const plugin = {
    configure(setup) {
      setup.devices.add(device);
    }
  };
  Object.defineProperty(device, transport_device, { value: endpoint });
  Object.defineProperty(device, getMachinePlugin, { value: () => plugin });
  Object.defineProperty(device, "closed", { value: endpoint.closed, enumerable: true });
  return device;
}
var VirtioController = class {
  /** The attachable device. */
  device;
  /** Pushes a new configuration to the guest and raises a config-change interrupt. */
  updateConfig;
  /** Idempotently starts closing the device. */
  close;
  /** Merges extra methods into the public device object; callable once. */
  expose;
  /** Creates a virtio device backed by `driver`. */
  constructor(options, driver) {
    const config = options.config?.slice() ?? new Uint8Array();
    let get_guest_config;
    let raise_config;
    let config_pending = false;
    let closed = false;
    const close_completion = Promise.withResolvers();
    void close_completion.promise.catch(() => {
    });
    let close_started = false;
    const active = /* @__PURE__ */ new Set();
    let exposed = false;
    const start_close = () => {
      if (close_started) return close_completion.promise;
      close_started = true;
      closed = true;
      void (async () => {
        let failure;
        try {
          driver.stop?.();
        } catch (reason) {
          failure = { status: "rejected", reason };
        }
        const results = await Promise.allSettled(active);
        failure ??= results.find((result) => result.status === "rejected");
        try {
          await driver.close?.(this);
        } catch (reason) {
          failure ??= { status: "rejected", reason };
        }
        if (failure) throw failure.reason;
      })().then(close_completion.resolve, close_completion.reject);
      return close_completion.promise;
    };
    const features = TransportFeatures.VERSION_1 | TransportFeatures.RING_PACKED | TransportFeatures.INDIRECT_DESC | (options.features ?? 0n);
    const endpoint = {
      device_id: options.deviceId,
      features,
      config,
      queues: driver.queues.length,
      closed: close_completion.promise,
      connect: (context) => connect_local_virtio_device(context, {
        features,
        config,
        attach: (next_get_config, next_raise_config) => {
          assert2(!closed, "cannot attach a closed virtio device");
          assert2(!get_guest_config, "virtio device is already attached");
          next_get_config().set(config);
          get_guest_config = next_get_config;
          raise_config = next_raise_config;
          if (config_pending) {
            config_pending = false;
            raise_config();
          }
        },
        notify: (vq, queue) => {
          if (closed) return;
          const handler = driver.queues[vq];
          assert2(handler, `virtio device has no queue ${vq}`);
          const completion = Promise.withResolvers();
          active.add(completion.promise);
          try {
            Promise.resolve(handler(queue, this)).then(completion.resolve, completion.reject);
          } catch (error) {
            completion.reject(error);
          }
          void completion.promise.finally(() => active.delete(completion.promise)).catch(() => {
          });
          return completion.promise;
        },
        reset: () => {
          if (!closed) driver.reset?.();
        }
      }),
      close: start_close
    };
    this.device = create_virtio_device(endpoint);
    this.updateConfig = (next_config) => {
      assert2(next_config.byteLength === config.byteLength, "virtio config size cannot change");
      config.set(next_config);
      get_guest_config?.().set(config);
      if (closed) return;
      if (raise_config) raise_config();
      else config_pending = true;
    };
    this.close = () => void start_close();
    this.expose = (api) => {
      assert2(!exposed, "virtio device API is already exposed");
      exposed = true;
      Object.defineProperties(this.device, Object.getOwnPropertyDescriptors(api));
      return this.device;
    };
  }
};
function connect_local_virtio_device(context, device) {
  const queues = [];
  const queue_state = (vq) => queues[vq] ??= { queue: void 0, pending: false, notifying: false };
  const drain_notifications = async (vq) => {
    const state = queue_state(vq);
    if (state.notifying || !state.queue) return;
    state.notifying = true;
    try {
      do {
        state.pending = false;
        await device.notify(vq, state.queue);
      } while (state.pending && state.queue);
    } catch (error) {
      context.on_error(error);
    } finally {
      state.notifying = false;
    }
  };
  return {
    set_features(features) {
      assert2(
        device.features === features,
        "the kernel should accept every feature we offer, and no more"
      );
    },
    setup(config_irq, _config_address, config_length) {
      assert2(config_length >= device.config.byteLength, "config space too small");
      const config = context.config_target ? context.config_target(config_length) : new Uint8Array(context.memory.buffer, _config_address, config_length);
      device.attach(
        () => config,
        () => {
          if (context.publish_config) context.publish_config(config_irq, config.slice(), true);
          else context.trigger_irq(config_irq);
        }
      );
      context.publish_config?.(config_irq, config.slice(), false);
    },
    enable_queue(vq, size, descriptor_address, irq) {
      const state = queue_state(vq);
      state.queue?.invalidate();
      let armed = false;
      const queue = new PackedVirtqueue(
        context.memory,
        size,
        descriptor_address,
        (completion) => {
          if (context.publish_completion) {
            context.publish_completion(vq, irq, completion);
            return;
          }
          publish_virtqueue_completion(context.memory, completion);
          if (armed) return;
          armed = true;
          queueMicrotask(() => {
            armed = false;
            if (state.queue === queue) context.trigger_irq(irq);
          });
        },
        () => state.queue === queue && (context.queue_is_current?.(vq) ?? true)
      );
      state.queue = queue;
      if (state.pending) void drain_notifications(vq);
    },
    disable_queue(vq) {
      const state = queues[vq];
      state?.queue?.invalidate();
      if (!state) return;
      state.queue = void 0;
      state.pending = false;
    },
    notify(vq) {
      queue_state(vq).pending = true;
      void drain_notifications(vq);
    },
    reset() {
      for (const state of queues) {
        if (!state) continue;
        state.queue?.invalidate();
        state.queue = void 0;
        state.pending = false;
      }
      device.reset();
    }
  };
}
function virtio_device_description(device) {
  const transport = device[transport_device];
  return {
    device_id: transport.device_id,
    features: transport.features,
    config: transport.config,
    queues: transport.queues
  };
}
function connect_virtio_device(device, context) {
  return device[transport_device].connect(context);
}
function close_virtio_device(device) {
  return device[transport_device].close();
}
function virtio_imports({
  memory,
  devices,
  trigger_irq,
  on_error
}) {
  const connected = devices.map(
    (device) => device[transport_device].connect({ memory, trigger_irq, on_error })
  );
  return {
    set_features(dev, features) {
      const device = connected[dev];
      assert2(device);
      device.set_features(features);
    },
    enable_vring(dev, vq, size, desc_addr, irq) {
      const device = connected[dev];
      assert2(device);
      device.enable_queue(vq, size, desc_addr >>> 0, irq);
    },
    disable_vring(dev, vq) {
      const device = connected[dev];
      assert2(device);
      device.disable_queue(vq);
    },
    reset(dev) {
      const device = connected[dev];
      assert2(device);
      device.reset();
    },
    setup(dev, config_irq, config_addr, config_len) {
      const address = config_addr >>> 0;
      const length = config_len >>> 0;
      const device = connected[dev];
      assert2(device);
      device.setup(config_irq, address, length);
    },
    notify(dev, vq) {
      const device = connected[dev];
      assert2(device);
      device.notify(vq);
    }
  };
}

// src/kernel/plugin-internal.ts
function is_device_tree_node(value) {
  return typeof value === "object" && value?.constructor === Object;
}
function merge_device_tree(target, source) {
  for (const [name, value] of Object.entries(source)) {
    const current = target[name];
    if (is_device_tree_node(current) && is_device_tree_node(value)) {
      merge_device_tree(current, value);
    } else {
      target[name] = value;
    }
  }
}
function machine_plugin(input) {
  return getMachinePlugin in input ? input[getMachinePlugin]() : input;
}
async function configure_machine(args, inputs) {
  const configured_args = [...args];
  const devices = [];
  const device_tree = {};
  const setup = {
    args: {
      add(...next) {
        configured_args.push(...next);
      }
    },
    devices: {
      add(...next) {
        devices.push(...next);
      }
    },
    deviceTree: {
      merge(fragment) {
        merge_device_tree(device_tree, fragment);
      }
    }
  };
  const plugins = [];
  try {
    for (const input of inputs) {
      const plugin = machine_plugin(input);
      plugins.push(plugin);
      await plugin.configure(setup);
    }
  } catch (error) {
    await Promise.allSettled(devices.map((device) => close_virtio_device(device)));
    throw error;
  }
  return {
    args: configured_args,
    devices,
    deviceTree: device_tree,
    plugins
  };
}
async function run_machine_booted(plugins, machine) {
  for (const plugin of plugins) await plugin.booted?.(machine);
}

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
    const start = this.#offset;
    const end = start + length;
    if (end > this.#end) this.fail("span extends past its section");
    this.#offset = end;
    return new _Cursor(this.#bytes, start, end);
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
var WASM_USER_MEMORY_NONE = 0;
var WASM_USER_MEMORY_SHARE = 1;
var WASM_USER_MEMORY_COPY = 2;
var MachineTerminationReason = {
  Clean: 0,
  Panic: 1
};
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

// src/kernel/virtio/block.ts
var BlockDeviceFeatures = {
  RO: 1n << 5n,
  FLUSH: 1n << 9n
};
var BlockDeviceConfig = class extends Struct({ capacity: U64LE }) {
};
var BlockDeviceRequest = class extends Struct({
  type: U32LE,
  reserved: U32LE,
  sector: U64LE
}) {
};
var BlockDeviceRequestType = {
  IN: 0,
  OUT: 1,
  FLUSH: 4,
  GET_ID: 8
};
var BlockDeviceStatus = {
  OK: 0,
  IOERR: 1,
  UNSUPP: 2
};
function blockDevice(storage) {
  const config = new Uint8Array(BlockDeviceConfig.size);
  new BlockDeviceConfig(config).capacity = BigInt(storage.capacity / 512);
  let features = 0n;
  if (storage.flush) features |= BlockDeviceFeatures.FLUSH;
  if (!storage.write) features |= BlockDeviceFeatures.RO;
  async function notify(queue) {
    for (const chain of queue) {
      let set_status = function(value) {
        status_desc.array[0] = value;
      };
      const descs = [...chain];
      const header = descs[0];
      const status = descs[descs.length - 1];
      const data = descs.slice(1, -1);
      assert2(header && !header.writable, "header must be readonly");
      assert2(
        header.array.byteLength === BlockDeviceRequest.size,
        `header size is ${header.array.byteLength}`
      );
      assert2(status && status.writable, "status must be writable");
      assert2(status.array.byteLength === 1, `status size is ${status.array.byteLength}`);
      const status_desc = status;
      const request = new BlockDeviceRequest(header.array);
      let n = 0;
      let offset = Number(request.sector) * 512;
      switch (request.type) {
        case BlockDeviceRequestType.IN: {
          let ok = true;
          for (const desc of data) {
            assert2(desc.writable, "data must be writable when IN");
            const read = await storage.read(offset, desc.array);
            if (read !== desc.array.byteLength) {
              ok = false;
              break;
            }
            n += read;
            offset += read;
          }
          set_status(ok ? BlockDeviceStatus.OK : BlockDeviceStatus.IOERR);
          break;
        }
        case BlockDeviceRequestType.OUT: {
          if (!storage.write) {
            set_status(BlockDeviceStatus.UNSUPP);
            break;
          }
          let ok = true;
          for (const desc of data) {
            assert2(!desc.writable, "data must be readonly when OUT");
            const written = await storage.write(offset, desc.array);
            if (written !== desc.array.byteLength) {
              ok = false;
              break;
            }
            n += written;
            offset += written;
          }
          set_status(ok ? BlockDeviceStatus.OK : BlockDeviceStatus.IOERR);
          break;
        }
        case BlockDeviceRequestType.FLUSH: {
          if (!storage.flush) {
            set_status(BlockDeviceStatus.UNSUPP);
            break;
          }
          await storage.flush();
          set_status(BlockDeviceStatus.OK);
          break;
        }
        case BlockDeviceRequestType.GET_ID: {
          console.log("GET_ID");
          set_status(BlockDeviceStatus.OK);
          break;
        }
        default:
          console.error("unknown request type", request.type);
          set_status(BlockDeviceStatus.UNSUPP);
      }
      chain.release(n);
    }
  }
  return new VirtioController(
    { deviceId: 2, features, config },
    { queues: [notify], close: () => storage.close?.() }
  ).device;
}

// src/kernel/virtio/remote.ts
var serialize_error = (error) => {
  const value = error instanceof Error ? error : new Error(String(error));
  return { name: value.name, message: value.message, stack: value.stack };
};
var deserialize_error = ({ name, message, stack }) => {
  const error = new Error(message);
  error.name = name;
  error.stack = stack;
  return error;
};
function workerDevice(endpoint) {
  endpoint.start?.();
  return new Promise((resolve, reject) => {
    let cleanup = () => {
    };
    const fail = (error) => {
      cleanup();
      reject(error);
    };
    cleanup = listen_endpoint(endpoint, {
      message(value) {
        const message = value;
        if (message?.type === "error") {
          fail(deserialize_error(message.error));
          return;
        }
        if (message?.type !== "ready") return;
        const device = create_remote_device(endpoint, message);
        cleanup();
        resolve(device);
      },
      error: fail
    });
  });
}
function create_remote_device(endpoint, ready) {
  const config = ready.config.slice();
  const close_completion = Promise.withResolvers();
  void close_completion.promise.catch(() => {
  });
  let connection;
  let terminal_error;
  let close_started = false;
  let cleanup = () => {
  };
  const fail = (error) => {
    terminal_error ??= error;
    connection?.fail(error);
    close_completion.reject(error);
  };
  const receive = (value) => {
    const message = value;
    if (message?.type === "closed") {
      cleanup();
      if (message.error) {
        const error = deserialize_error(message.error);
        connection?.fail(error);
        close_completion.reject(error);
      } else {
        close_completion.resolve();
      }
      return;
    }
    if (message?.type === "error" && !connection) {
      fail(deserialize_error(message.error));
      return;
    }
    connection?.receive(message);
  };
  const endpoint_failure = (error) => {
    cleanup();
    fail(error);
  };
  cleanup = listen_endpoint(endpoint, {
    message: receive,
    error: endpoint_failure
  });
  const transport = {
    device_id: ready.device_id,
    features: ready.features,
    config,
    queues: ready.queues,
    closed: close_completion.promise,
    connect(context) {
      assert2(!connection, "remote virtio device is already attached");
      if (terminal_error) throw terminal_error;
      connection = connect_remote_device(endpoint, transport, context);
      return connection.device;
    },
    close() {
      if (close_started) return close_completion.promise;
      close_started = true;
      connection?.revoke();
      post_endpoint(endpoint, { type: "close" });
      return close_completion.promise;
    }
  };
  return create_virtio_device(transport);
}
function connect_remote_device(endpoint, transport, context) {
  const control_buffer = new SharedArrayBuffer(
    Int32Array.BYTES_PER_ELEMENT * (1 + transport.queues)
  );
  const control = new Int32Array(control_buffer);
  const queue_epochs = new Int32Array(transport.queues);
  const enabled = new Uint8Array(transport.queues);
  let config_target;
  let failed = false;
  const fail = (error) => {
    if (failed) return;
    failed = true;
    Atomics.add(control, 0, 1);
    context.on_error(error);
  };
  const receive = (message) => {
    switch (message?.type) {
      case "complete": {
        if (!enabled[message.vq] || Atomics.load(control, 0) !== message.device_epoch || Atomics.load(control, 1 + message.vq) !== message.queue_epoch)
          return;
        publish_virtqueue_completion(context.memory, message.completion);
        context.trigger_irq(message.irq);
        return;
      }
      case "config":
        transport.config.set(message.config.subarray(0, transport.config.byteLength));
        config_target?.set(message.config);
        if (message.interrupt) context.trigger_irq(message.irq);
        return;
      case "error":
        fail(deserialize_error(message.error));
        return;
    }
  };
  post_endpoint(endpoint, {
    type: "bind",
    memory: context.memory,
    control: control_buffer
  });
  const device = {
    set_features(features) {
      assert2(features === transport.features);
      post_endpoint(endpoint, { type: "features", features });
    },
    setup(config_irq, config_address, config_length) {
      assert2(config_length >= transport.config.byteLength, "config space too small");
      config_target = new Uint8Array(context.memory.buffer, config_address, config_length);
      config_target.set(transport.config);
      post_endpoint(endpoint, { type: "setup", config_irq, config_length });
    },
    enable_queue(vq, size, descriptor_address, irq) {
      assert2(vq < transport.queues, `virtio device has no queue ${vq}`);
      Atomics.add(control, 1 + vq, 1);
      const queue_epoch = queue_epochs[vq] = Atomics.load(control, 1 + vq);
      const device_epoch = Atomics.load(control, 0);
      enabled[vq] = 1;
      post_endpoint(endpoint, {
        type: "enable",
        vq,
        size,
        descriptor_address,
        irq,
        device_epoch,
        queue_epoch
      });
    },
    disable_queue(vq) {
      assert2(vq < transport.queues, `virtio device has no queue ${vq}`);
      enabled[vq] = 0;
      Atomics.add(control, 1 + vq, 1);
      post_endpoint(endpoint, { type: "disable", vq });
    },
    notify(vq) {
      post_endpoint(endpoint, { type: "notify", vq });
    },
    reset() {
      Atomics.add(control, 0, 1);
      enabled.fill(0);
      post_endpoint(endpoint, { type: "reset" });
    }
  };
  return {
    device,
    receive,
    fail,
    revoke() {
      Atomics.add(control, 0, 1);
      enabled.fill(0);
    }
  };
}
function serveDevice(endpoint, device) {
  const description = virtio_device_description(device);
  let connected;
  let control;
  let device_epoch = 0;
  const queue_epochs = new Int32Array(description.queues);
  let closing = false;
  const send_error = (error) => post_endpoint(endpoint, {
    type: "error",
    error: serialize_error(error)
  });
  let stop_listening = () => {
  };
  const on_message = (value) => {
    const message = value;
    try {
      switch (message?.type) {
        case "bind":
          assert2(!connected, "virtio device is already bound");
          message.memory.grow(0);
          control = new Int32Array(message.control);
          connected = connect_virtio_device(device, {
            memory: message.memory,
            trigger_irq: () => assert2(false, "remote interrupts are published with state"),
            on_error: send_error,
            config_target: (length) => new Uint8Array(length),
            publish_config: (irq, value2, interrupt) => {
              const copy = value2.slice();
              post_endpoint(
                endpoint,
                { type: "config", irq, config: copy, interrupt },
                [copy.buffer]
              );
            },
            queue_is_current: (vq) => Atomics.load(control, 0) === device_epoch && Atomics.load(control, 1 + vq) === queue_epochs[vq],
            publish_completion: (vq, irq, completion) => {
              if (Atomics.load(control, 0) !== device_epoch || Atomics.load(control, 1 + vq) !== queue_epochs[vq])
                return;
              const transfer = completion.outputs.map(({ data }) => data.buffer);
              post_endpoint(
                endpoint,
                {
                  type: "complete",
                  vq,
                  irq,
                  device_epoch,
                  queue_epoch: queue_epochs[vq],
                  completion
                },
                transfer
              );
            }
          });
          return;
        case "features":
          connected?.set_features(message.features);
          return;
        case "setup":
          connected?.setup(message.config_irq, 0, message.config_length);
          return;
        case "enable":
          device_epoch = message.device_epoch;
          queue_epochs[message.vq] = message.queue_epoch;
          connected?.enable_queue(
            message.vq,
            message.size,
            message.descriptor_address,
            message.irq
          );
          return;
        case "disable":
          connected?.disable_queue(message.vq);
          return;
        case "notify":
          connected?.notify(message.vq);
          return;
        case "reset":
          device_epoch = Atomics.load(control, 0);
          connected?.reset();
          return;
        case "close":
          if (closing) return;
          closing = true;
          void close_virtio_device(device).then(
            () => {
              stop_listening();
              post_endpoint(endpoint, { type: "closed" });
            },
            (error) => {
              stop_listening();
              post_endpoint(endpoint, {
                type: "closed",
                error: serialize_error(error)
              });
            }
          );
          return;
      }
    } catch (error) {
      send_error(error);
    }
  };
  stop_listening = listen_endpoint(endpoint, { message: on_message });
  endpoint.start?.();
  const ready_config = description.config.slice();
  post_endpoint(
    endpoint,
    { type: "ready", ...description, config: ready_config },
    [ready_config.buffer]
  );
}

// src/kernel/virtio/console.ts
var Features = {
  SIZE: 1n << 0n
};
var ConsoleConfig = class extends Struct({
  columns: U16LE,
  rows: U16LE
}) {
};
function consoleDevice(input, output) {
  const reader = input?.getReader();
  const writer = output?.getWriter();
  const config_bytes = new Uint8Array(ConsoleConfig.size);
  const config = new ConsoleConfig(config_bytes);
  config.columns = 80;
  config.rows = 24;
  let pumping;
  let reader_cancellation;
  let writer_abortion;
  const receive_chains = [];
  const pending_input = [];
  let guest_ready = false;
  function reset() {
    receive_chains.length = 0;
    guest_ready = false;
  }
  function flush_input() {
    while (guest_ready && receive_chains.length > 0 && pending_input.length > 0) {
      const chain = receive_chains.shift();
      const chunk = pending_input[0];
      const [desc, trailing] = chain;
      assert2(desc && desc.writable, "receiver must be writable");
      assert2(!trailing, "too many descriptors");
      const n = Math.min(chunk.byteLength, desc.array.byteLength);
      desc.array.set(chunk.subarray(0, n));
      chain.release(n);
      if (n < chunk.byteLength) pending_input[0] = chunk.subarray(n);
      else pending_input.shift();
    }
  }
  async function pump_input() {
    assert2(reader);
    for (; ; ) {
      const { value, done } = await reader.read();
      if (done) break;
      pending_input.push(value);
      flush_input();
    }
  }
  function notify_input(queue) {
    for (const chain of queue) receive_chains.push(chain);
    flush_input();
    pumping ??= pump_input().catch(console.error);
  }
  async function notify_output(queue) {
    if (!guest_ready) {
      guest_ready = true;
      flush_input();
    }
    for (const chain of queue) {
      let n = 0;
      for (const { array, writable } of chain) {
        assert2(!writable, "transmitter must be readable");
        await writer?.write(array);
        n += array.byteLength;
      }
      chain.release(n);
    }
  }
  const controller = new VirtioController(
    { deviceId: 3, features: Features.SIZE, config: config_bytes },
    {
      queues: [reader ? notify_input : () => {
      }, notify_output],
      reset,
      stop() {
        reset();
        pending_input.length = 0;
        reader_cancellation ??= reader?.cancel();
        writer_abortion ??= writer?.abort();
      },
      async close() {
        const results = await Promise.allSettled([reader_cancellation, writer_abortion]);
        const failure = results.find((result) => result.status === "rejected");
        if (failure) throw failure.reason;
      }
    }
  );
  function resize(columns, rows) {
    assert2(
      Number.isInteger(columns) && columns > 0 && columns <= 65535,
      "console columns must be a positive 16-bit integer"
    );
    assert2(
      Number.isInteger(rows) && rows > 0 && rows <= 65535,
      "console rows must be a positive 16-bit integer"
    );
    if (config.columns === columns && config.rows === rows) return;
    config.columns = columns;
    config.rows = rows;
    controller.updateConfig(config_bytes);
  }
  return controller.expose({ resize });
}

// src/kernel/virtio/entropy.ts
function entropyDevice() {
  function notify(queue) {
    for (const chain of queue) {
      let n = 0;
      for (const { array, writable } of chain) {
        assert2(writable);
        const arr = new Uint8Array(array.length);
        crypto.getRandomValues(arr);
        array.set(arr);
        n += array.byteLength;
      }
      chain.release(n);
    }
  }
  return new VirtioController({ deviceId: 4 }, { queues: [notify] }).device;
}

// src/kernel/virtio/fs.ts
var utf8_encoder = new TextEncoder();
var FuseOpcode = {
  LOOKUP: 1,
  FORGET: 2,
  GETATTR: 3,
  SETATTR: 4,
  READLINK: 5,
  SYMLINK: 6,
  MKDIR: 9,
  UNLINK: 10,
  RMDIR: 11,
  RENAME: 12,
  OPEN: 14,
  READ: 15,
  WRITE: 16,
  STATFS: 17,
  RELEASE: 18,
  FSYNC: 20,
  FLUSH: 25,
  INIT: 26,
  OPENDIR: 27,
  READDIR: 28,
  RELEASEDIR: 29,
  FSYNCDIR: 30,
  ACCESS: 34,
  CREATE: 35,
  INTERRUPT: 36,
  DESTROY: 38,
  BATCH_FORGET: 42
};
var FuseInitFlags = {
  ASYNC_READ: 1 << 0,
  BIG_WRITES: 1 << 5,
  AUTO_INVAL_DATA: 1 << 12,
  MAX_PAGES: 1 << 22,
  INIT_EXT: 1 << 30
};
var FuseGetattrFlags = {
  FH: 1 << 0
};
var FuseSetattrFlags = {
  MODE: 1 << 0,
  UID: 1 << 1,
  GID: 1 << 2,
  SIZE: 1 << 3,
  ATIME: 1 << 4,
  MTIME: 1 << 5,
  FH: 1 << 6,
  ATIME_NOW: 1 << 7,
  MTIME_NOW: 1 << 8,
  CTIME: 1 << 10
};
var FileType = {
  fifo: 4096,
  character: 8192,
  directory: 16384,
  block: 24576,
  file: 32768,
  symlink: 40960,
  socket: 49152
};
var DirentType = {
  fifo: 1,
  character: 2,
  directory: 4,
  block: 6,
  file: 8,
  symlink: 10,
  socket: 12
};
var Errno = {
  EPERM: 1,
  ENOENT: 2,
  EIO: 5,
  EBADF: 9,
  EACCES: 13,
  EEXIST: 17,
  ENOTDIR: 20,
  EISDIR: 21,
  EINVAL: 22,
  ENOSPC: 28,
  EROFS: 30,
  EPROTO: 71,
  ENAMETOOLONG: 36,
  ENOSYS: 38,
  ENOTEMPTY: 39,
  ELOOP: 40,
  EOPNOTSUPP: 95
};
var FSError = class extends Error {
  errno;
  constructor(code, message = code) {
    super(message);
    this.name = "FSError";
    this.errno = Errno[code];
  }
};
var FuseInHeader = Struct({
  len: U32LE,
  opcode: U32LE,
  unique: U64LE,
  nodeid: U64LE,
  uid: U32LE,
  gid: U32LE,
  pid: U32LE,
  total_extlen: U16LE,
  padding: U16LE
});
var FuseOutHeader = Struct({
  len: U32LE,
  error: I32LE,
  unique: U64LE
});
var FuseAttr = Struct({
  ino: U64LE,
  size: U64LE,
  blocks: U64LE,
  atime: U64LE,
  mtime: U64LE,
  ctime: U64LE,
  atimensec: U32LE,
  mtimensec: U32LE,
  ctimensec: U32LE,
  mode: U32LE,
  nlink: U32LE,
  uid: U32LE,
  gid: U32LE,
  rdev: U32LE,
  blksize: U32LE,
  flags: U32LE
});
var FuseEntryOut = Struct({
  nodeid: U64LE,
  generation: U64LE,
  entry_valid: U64LE,
  attr_valid: U64LE,
  entry_valid_nsec: U32LE,
  attr_valid_nsec: U32LE,
  attr: FuseAttr
});
var FuseAttrOut = Struct({
  attr_valid: U64LE,
  attr_valid_nsec: U32LE,
  dummy: U32LE,
  attr: FuseAttr
});
var FuseOpenOut = Struct({
  fh: U64LE,
  open_flags: U32LE,
  backing_id: I32LE
});
var FuseInitOut = Struct({
  major: U32LE,
  minor: U32LE,
  max_readahead: U32LE,
  flags: U32LE,
  max_background: U16LE,
  congestion_threshold: U16LE,
  max_write: U32LE,
  time_gran: U32LE,
  max_pages: U16LE,
  map_alignment: U16LE,
  flags2: U32LE,
  max_stack_depth: U32LE,
  request_timeout: U16LE,
  unused: FixedArray(U16LE, 11)
});
var FuseWriteOut = Struct({
  size: U32LE,
  padding: U32LE
});
var FuseStatfsOut = Struct({
  blocks: U64LE,
  bfree: U64LE,
  bavail: U64LE,
  files: U64LE,
  ffree: U64LE,
  bsize: U32LE,
  namelen: U32LE,
  frsize: U32LE,
  padding: U32LE,
  spare: FixedArray(U32LE, 6)
});
var FuseInitIn = Struct({
  major: U32LE,
  minor: U32LE,
  max_readahead: U32LE,
  flags: U32LE
});
var FuseForgetIn = Struct({
  nlookup: U64LE
});
var FuseForgetOne = Struct({
  nodeid: U64LE,
  nlookup: U64LE
});
var FuseBatchForgetIn = Struct({
  count: U32LE,
  dummy: U32LE
});
var FuseGetattrIn = Struct({
  getattr_flags: U32LE,
  dummy: U32LE,
  fh: U64LE
});
var FuseMkdirIn = Struct({
  mode: U32LE,
  umask: U32LE
});
var FuseRenameIn = Struct({
  newdir: U64LE
});
var FuseSetattrIn = Struct({
  valid: U32LE,
  padding: U32LE,
  fh: U64LE,
  size: U64LE,
  lock_owner: U64LE,
  atime: U64LE,
  mtime: U64LE,
  ctime: U64LE,
  atimensec: U32LE,
  mtimensec: U32LE,
  ctimensec: U32LE,
  mode: U32LE,
  unused4: U32LE,
  uid: U32LE,
  gid: U32LE,
  unused5: U32LE
});
var FuseOpenIn = Struct({
  flags: U32LE,
  open_flags: U32LE
});
var FuseCreateIn = Struct({
  flags: U32LE,
  mode: U32LE,
  umask: U32LE,
  open_flags: U32LE
});
var FuseReadIn = Struct({
  fh: U64LE,
  offset: U64LE,
  size: U32LE,
  read_flags: U32LE,
  lock_owner: U64LE,
  flags: U32LE,
  padding: U32LE
});
var FuseWriteIn = Struct({
  fh: U64LE,
  offset: U64LE,
  size: U32LE,
  write_flags: U32LE,
  lock_owner: U64LE,
  flags: U32LE,
  padding: U32LE
});
var FuseFlushIn = Struct({
  fh: U64LE,
  unused: U32LE,
  padding: U32LE,
  lock_owner: U64LE
});
var FuseFsyncIn = Struct({
  fh: U64LE,
  fsync_flags: U32LE,
  padding: U32LE
});
var FuseReleaseIn = Struct({
  fh: U64LE,
  flags: U32LE,
  release_flags: U32LE,
  lock_owner: U64LE
});
var FuseAccessIn = Struct({
  mask: U32LE,
  padding: U32LE
});
var FuseDirent = Struct({
  ino: U64LE,
  off: U64LE,
  namelen: U32LE,
  type: U32LE
});
var UnsupportedOperation = class extends FSError {
  constructor() {
    super("ENOSYS");
  }
};
function mode_type(mode) {
  switch (mode & 61440) {
    case FileType.fifo:
      return "fifo";
    case FileType.character:
      return "character";
    case FileType.directory:
      return "directory";
    case FileType.block:
      return "block";
    case FileType.file:
      return "file";
    case FileType.symlink:
      return "symlink";
    case FileType.socket:
      return "socket";
    default:
      throw new FSError("EIO", "filesystem returned an invalid mode");
  }
}
function checked_number(value) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) {
    throw new FSError("EINVAL", "offset exceeds JavaScript's integer range");
  }
  return number;
}
function validate_name(name) {
  if (name.length === 0 || name === "." || name === ".." || name.includes("/") || name.includes("\0")) {
    throw new FSError("EINVAL", "invalid path component");
  }
  if (utf8_encoder.encode(name).byteLength > 255) {
    throw new FSError("ENAMETOOLONG");
  }
  return name;
}
function concatenate(buffers, writable) {
  const selected = buffers.filter((buffer) => buffer.writable === writable);
  const length = selected.reduce((total, buffer) => total + buffer.array.byteLength, 0);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const buffer of selected) {
    result.set(buffer.array, offset);
    offset += buffer.array.byteLength;
  }
  return result;
}
function scatter(buffers, data) {
  let offset = 0;
  for (const buffer of buffers) {
    if (!buffer.writable) continue;
    const length = Math.min(buffer.array.byteLength, data.byteLength - offset);
    if (length <= 0) break;
    buffer.array.set(data.subarray(offset, offset + length));
    offset += length;
  }
  if (offset !== data.byteLength) {
    throw new Error("guest response buffers are too small");
  }
}
function minimum_response_capacity(opcode) {
  switch (opcode) {
    case FuseOpcode.FORGET:
    case FuseOpcode.BATCH_FORGET:
    case FuseOpcode.INTERRUPT:
      return 0;
    case FuseOpcode.INIT:
      return FuseOutHeader.size + FuseInitOut.size;
    case FuseOpcode.LOOKUP:
    case FuseOpcode.SYMLINK:
    case FuseOpcode.MKDIR:
      return FuseOutHeader.size + FuseEntryOut.size;
    case FuseOpcode.GETATTR:
    case FuseOpcode.SETATTR:
      return FuseOutHeader.size + FuseAttrOut.size;
    case FuseOpcode.OPEN:
    case FuseOpcode.OPENDIR:
      return FuseOutHeader.size + FuseOpenOut.size;
    case FuseOpcode.CREATE:
      return FuseOutHeader.size + FuseEntryOut.size + FuseOpenOut.size;
    case FuseOpcode.WRITE:
      return FuseOutHeader.size + FuseWriteOut.size;
    case FuseOpcode.STATFS:
      return FuseOutHeader.size + FuseStatfsOut.size;
    default:
      return FuseOutHeader.size;
  }
}
function timestamp(value) {
  return [value?.seconds ?? 0n, value?.nanoseconds ?? 0];
}
function attr_fields(nodeid, attributes) {
  const [atime, atimensec] = timestamp(attributes.atime);
  const [mtime, mtimensec] = timestamp(attributes.mtime);
  const [ctime, ctimensec] = timestamp(attributes.ctime);
  return {
    ino: nodeid,
    size: attributes.size,
    blocks: attributes.blocks ?? (attributes.size + 511n) / 512n,
    atime,
    mtime,
    ctime,
    atimensec,
    mtimensec,
    ctimensec,
    mode: attributes.mode,
    nlink: attributes.nlink ?? (mode_type(attributes.mode) === "directory" ? 2 : 1),
    uid: attributes.uid ?? 0,
    gid: attributes.gid ?? 0,
    rdev: attributes.rdev ?? 0,
    blksize: attributes.blockSize ?? 4096,
    flags: 0
  };
}
function write_entry(payload, record, attributes, validity) {
  payload.alloc(FuseEntryOut).value = {
    nodeid: record.id,
    generation: 1n,
    entry_valid: validity,
    attr_valid: validity,
    entry_valid_nsec: 0,
    attr_valid_nsec: 0,
    attr: attr_fields(record.id, attributes)
  };
}
function write_attr_out(payload, validity, nodeid, attributes) {
  payload.alloc(FuseAttrOut).value = {
    attr_valid: validity,
    attr_valid_nsec: 0,
    dummy: 0,
    attr: attr_fields(nodeid, attributes)
  };
}
function create_context(header, mode, umask) {
  return {
    mode: mode & ~umask,
    uid: header.uid,
    gid: header.gid
  };
}
async function async_iterable(source) {
  const result = [];
  for await (const item of source) result.push(item);
  return result;
}
function fileSystemDevice(filesystem, options) {
  const { tag, cache = true } = options;
  const validity = cache ? 1n : 0n;
  const encoded_tag = utf8_encoder.encode(tag);
  if (encoded_tag.byteLength === 0 || encoded_tag.byteLength > 36) {
    throw new RangeError("virtio-fs tag must be between 1 and 36 UTF-8 bytes");
  }
  if (filesystem.write ?? filesystem.create) {
    if (!filesystem.flush || !filesystem.fsync) {
      throw new Error(
        "a writable filesystem must implement flush() and fsync(); no-op implementations are the explicit way to declare an already-durable or ephemeral backend"
      );
    }
  }
  const config = new Uint8Array(40);
  config.set(encoded_tag);
  new DataView(config.buffer).setUint32(36, 1, true);
  const records = /* @__PURE__ */ new Map();
  const by_node = /* @__PURE__ */ new WeakMap();
  let next_nodeid = 2n;
  const root = {
    id: 1n,
    node: filesystem.root,
    parent: void 0,
    lookups: 1n,
    handles: 0,
    children: 0
  };
  root.parent = root;
  records.set(root.id, root);
  by_node.set(filesystem.root, root);
  const handles = /* @__PURE__ */ new Map();
  let next_handle = 1n;
  let finalize_promise;
  function record_for_node(node2, parent) {
    let record = by_node.get(node2);
    if (!record) {
      record = {
        id: next_nodeid++,
        node: node2,
        parent,
        lookups: 0n,
        handles: 0,
        children: 0
      };
      records.set(record.id, record);
      by_node.set(node2, record);
      parent.children += 1;
    }
    return record;
  }
  function collect_record(record) {
    if (records.get(record.id) !== record) return;
    if (record !== root && record.lookups === 0n && record.handles === 0 && record.children === 0) {
      records.delete(record.id);
      by_node.delete(record.node);
      record.parent.children -= 1;
      collect_record(record.parent);
    }
  }
  function forget(record, count) {
    record.lookups = count >= record.lookups ? 0n : record.lookups - count;
    collect_record(record);
  }
  function node_record(nodeid) {
    const record = records.get(nodeid);
    if (!record) throw new FSError("ENOENT");
    return record;
  }
  function handle_record(fh, directory, node2) {
    const record = handles.get(fh);
    if (!record || directory !== void 0 && record.directory !== directory || node2 !== void 0 && record.node !== node2) {
      throw new FSError("EBADF");
    }
    return record;
  }
  function add_handle(node2, handle, directory) {
    const fh = next_handle++;
    handles.set(fh, { node: node2, handle, directory });
    node2.handles += 1;
    return fh;
  }
  function remove_handle(fh, handle) {
    handles.delete(fh);
    handle.node.handles -= 1;
    collect_record(handle.node);
  }
  function finalize() {
    if (finalize_promise) return finalize_promise;
    finalize_promise = (async () => {
      let failed = false;
      let first_error;
      for (const [fh, handle] of handles) {
        try {
          if (handle.directory) {
            await filesystem.releasedir?.(handle.node.node, handle.handle);
          } else {
            await filesystem.release?.(handle.node.node, handle.handle);
          }
        } catch (error) {
          if (!failed) {
            failed = true;
            first_error = error;
          }
        } finally {
          remove_handle(fh, handle);
        }
      }
      try {
        await filesystem.destroy?.();
      } catch (error) {
        if (!failed) {
          failed = true;
          first_error = error;
        }
      }
      if (failed) throw first_error;
    })();
    return finalize_promise;
  }
  async function lookup(parent, name) {
    const node2 = await filesystem.lookup(parent.node, validate_name(name));
    if (!node2) throw new FSError("ENOENT");
    const record = record_for_node(node2, parent);
    record.lookups += 1n;
    return record;
  }
  async function process2(header, body, capacity) {
    const payload = new Bytes(Math.max(0, capacity - FuseOutHeader.size));
    const node2 = header.nodeid === 0n ? void 0 : node_record(header.nodeid);
    switch (header.opcode) {
      case FuseOpcode.INIT: {
        const init = body.struct(FuseInitIn);
        if (init.major !== 7) {
          if (init.major < 7) throw new FSError("EPROTO");
          payload.alloc(U32LE).value = 7;
          payload.alloc(U32LE).value = 45;
          break;
        }
        const supported_flags = FuseInitFlags.ASYNC_READ | FuseInitFlags.BIG_WRITES | FuseInitFlags.AUTO_INVAL_DATA | FuseInitFlags.MAX_PAGES | FuseInitFlags.INIT_EXT;
        const flags = init.flags & supported_flags;
        payload.alloc(FuseInitOut).value = {
          major: 7,
          minor: Math.min(init.minor, 45),
          max_readahead: Math.min(init.max_readahead, 1024 * 1024),
          flags,
          max_background: 12,
          congestion_threshold: 9,
          max_write: 1024 * 1024,
          time_gran: 1,
          max_pages: (flags & FuseInitFlags.MAX_PAGES) === 0 ? 0 : 16,
          map_alignment: 0,
          flags2: 0,
          max_stack_depth: 0,
          request_timeout: 0,
          unused: Array(11).fill(0)
        };
        break;
      }
      case FuseOpcode.LOOKUP: {
        const record = await lookup(node2, body.cstring());
        write_entry(payload, record, await filesystem.getattr(record.node), validity);
        break;
      }
      case FuseOpcode.FORGET: {
        const request = body.struct(FuseForgetIn);
        forget(node2, request.nlookup);
        return void 0;
      }
      case FuseOpcode.BATCH_FORGET: {
        const request = body.struct(FuseBatchForgetIn);
        const forgotten = [];
        for (let index = 0; index < request.count; index++) {
          const one = body.struct(FuseForgetOne);
          const record = records.get(one.nodeid);
          if (record) forgotten.push({ record, count: one.nlookup });
        }
        for (const entry of forgotten) forget(entry.record, entry.count);
        return void 0;
      }
      case FuseOpcode.GETATTR: {
        const request = body.struct(FuseGetattrIn);
        const handle = request.getattr_flags & FuseGetattrFlags.FH ? handle_record(request.fh, void 0, node2).handle : void 0;
        write_attr_out(payload, validity, node2.id, await filesystem.getattr(node2.node, handle));
        break;
      }
      case FuseOpcode.SETATTR: {
        if (!filesystem.setattr) throw new UnsupportedOperation();
        const request = body.struct(FuseSetattrIn);
        const changes = {};
        if (request.valid & FuseSetattrFlags.MODE) changes.mode = request.mode;
        if (request.valid & FuseSetattrFlags.UID) changes.uid = request.uid;
        if (request.valid & FuseSetattrFlags.GID) changes.gid = request.gid;
        if (request.valid & FuseSetattrFlags.SIZE) changes.size = request.size;
        if (request.valid & FuseSetattrFlags.ATIME) {
          changes.atime = request.valid & FuseSetattrFlags.ATIME_NOW ? "now" : { seconds: request.atime, nanoseconds: request.atimensec };
        }
        if (request.valid & FuseSetattrFlags.MTIME) {
          changes.mtime = request.valid & FuseSetattrFlags.MTIME_NOW ? "now" : { seconds: request.mtime, nanoseconds: request.mtimensec };
        }
        if (request.valid & FuseSetattrFlags.CTIME) {
          changes.ctime = { seconds: request.ctime, nanoseconds: request.ctimensec };
        }
        const open = request.valid & FuseSetattrFlags.FH ? handle_record(request.fh, void 0, node2).handle : void 0;
        const attributes = await filesystem.setattr(node2.node, changes, open);
        write_attr_out(payload, validity, node2.id, attributes);
        break;
      }
      case FuseOpcode.READLINK: {
        if (!filesystem.readlink) throw new UnsupportedOperation();
        payload.append(utf8_encoder.encode(await filesystem.readlink(node2.node)));
        break;
      }
      case FuseOpcode.SYMLINK: {
        if (!filesystem.symlink) throw new UnsupportedOperation();
        const name = validate_name(body.cstring());
        const target = body.cstring();
        const linked = await filesystem.symlink(
          node2.node,
          name,
          target,
          create_context(header, FileType.symlink | 511, 0)
        );
        const record = record_for_node(linked, node2);
        record.lookups += 1n;
        write_entry(payload, record, await filesystem.getattr(linked), validity);
        break;
      }
      case FuseOpcode.MKDIR: {
        if (!filesystem.mkdir) throw new UnsupportedOperation();
        const request = body.struct(FuseMkdirIn);
        const made = await filesystem.mkdir(
          node2.node,
          validate_name(body.cstring()),
          create_context(header, FileType.directory | request.mode, request.umask)
        );
        const record = record_for_node(made, node2);
        record.lookups += 1n;
        write_entry(payload, record, await filesystem.getattr(made), validity);
        break;
      }
      case FuseOpcode.UNLINK:
      case FuseOpcode.RMDIR: {
        const method = header.opcode === FuseOpcode.UNLINK ? filesystem.unlink : filesystem.rmdir;
        if (!method) throw new UnsupportedOperation();
        await method.call(filesystem, node2.node, validate_name(body.cstring()));
        break;
      }
      case FuseOpcode.RENAME: {
        if (!filesystem.rename) throw new UnsupportedOperation();
        const request = body.struct(FuseRenameIn);
        const new_parent = node_record(request.newdir);
        const old_name = validate_name(body.cstring());
        const new_name = validate_name(body.cstring());
        const moved = node2 === new_parent ? void 0 : await filesystem.lookup(node2.node, old_name);
        const moved_record = moved && by_node.get(moved);
        await filesystem.rename(node2.node, old_name, new_parent.node, new_name);
        if (moved_record && records.get(moved_record.id) === moved_record && moved_record.parent !== new_parent) {
          const old_parent = moved_record.parent;
          old_parent.children -= 1;
          moved_record.parent = new_parent;
          new_parent.children += 1;
          collect_record(old_parent);
        }
        break;
      }
      case FuseOpcode.OPEN:
      case FuseOpcode.OPENDIR: {
        const directory = header.opcode === FuseOpcode.OPENDIR;
        const method = directory ? filesystem.opendir : filesystem.open;
        if (!method) throw new UnsupportedOperation();
        const request = body.struct(FuseOpenIn);
        const handle = await method.call(filesystem, node2.node, request.flags);
        payload.alloc(FuseOpenOut).value = {
          fh: add_handle(node2, handle, directory),
          // Keep open flags zero even when cache is false. Cache controls only
          // entry/attribute validity; FOPEN_DIRECT_IO would route private
          // owner-worker user buffers through unsupported page extraction.
          open_flags: 0,
          backing_id: -1
        };
        break;
      }
      case FuseOpcode.CREATE: {
        if (!filesystem.create) throw new UnsupportedOperation();
        const request = body.struct(FuseCreateIn);
        const created = await filesystem.create(
          node2.node,
          validate_name(body.cstring()),
          request.flags,
          create_context(header, FileType.file | request.mode, request.umask)
        );
        const record = record_for_node(created.node, node2);
        record.lookups += 1n;
        write_entry(payload, record, await filesystem.getattr(created.node), validity);
        payload.alloc(FuseOpenOut).value = {
          fh: add_handle(record, created.handle, false),
          // CREATE returns the same open flags as OPEN; direct I/O is
          // unsupported by this wasm transport even when metadata/name
          // validity is zero.
          open_flags: 0,
          backing_id: -1
        };
        break;
      }
      case FuseOpcode.READ: {
        if (!filesystem.read) throw new UnsupportedOperation();
        const request = body.struct(FuseReadIn);
        const handle = handle_record(request.fh, false, node2);
        const data = await filesystem.read(
          handle.node.node,
          handle.handle,
          request.offset,
          Math.min(request.size, capacity - FuseOutHeader.size)
        );
        if (data.byteLength > request.size || data.byteLength > capacity - FuseOutHeader.size) {
          throw new FSError("EIO", "filesystem returned too much data");
        }
        payload.append(data);
        break;
      }
      case FuseOpcode.WRITE: {
        if (!filesystem.write) throw new UnsupportedOperation();
        const request = body.struct(FuseWriteIn);
        const data = body.bytes(request.size);
        const handle = handle_record(request.fh, false, node2);
        const written = await filesystem.write(
          handle.node.node,
          handle.handle,
          request.offset,
          data
        );
        if (!Number.isInteger(written) || written < 0 || written > request.size) {
          throw new FSError("EIO", "filesystem returned an invalid write size");
        }
        payload.alloc(FuseWriteOut).value = { size: written, padding: 0 };
        break;
      }
      case FuseOpcode.FLUSH: {
        const request = body.struct(FuseFlushIn);
        const handle = handle_record(request.fh, false, node2);
        if (filesystem.flush) {
          await filesystem.flush(handle.node.node, handle.handle);
        }
        break;
      }
      case FuseOpcode.FSYNC:
      case FuseOpcode.FSYNCDIR: {
        const request = body.struct(FuseFsyncIn);
        const handle = handle_record(request.fh, header.opcode === FuseOpcode.FSYNCDIR, node2);
        if (filesystem.fsync) {
          await filesystem.fsync(handle.node.node, handle.handle, (request.fsync_flags & 1) !== 0);
        }
        break;
      }
      case FuseOpcode.RELEASE:
      case FuseOpcode.RELEASEDIR: {
        const directory = header.opcode === FuseOpcode.RELEASEDIR;
        const request = body.struct(FuseReleaseIn);
        const handle = handle_record(request.fh, directory, node2);
        if (directory) {
          await filesystem.releasedir?.(handle.node.node, handle.handle);
        } else {
          await filesystem.release?.(handle.node.node, handle.handle);
        }
        remove_handle(request.fh, handle);
        break;
      }
      case FuseOpcode.READDIR: {
        if (!filesystem.readdir) throw new UnsupportedOperation();
        const request = body.struct(FuseReadIn);
        const offset = checked_number(request.offset);
        const handle = handle_record(request.fh, true, node2);
        const entries = [
          { name: ".", record: handle.node },
          { name: "..", record: handle.node.parent }
        ];
        const directory_entries = await filesystem.readdir(handle.node.node, handle.handle);
        const transient = [];
        const limit = Math.min(request.size, capacity - FuseOutHeader.size);
        try {
          for (const entry of await async_iterable(directory_entries)) {
            const record = record_for_node(entry.node, handle.node);
            transient.push(record);
            entries.push({
              name: validate_name(entry.name),
              record
            });
          }
          for (let index = offset; index < entries.length; index++) {
            const entry = entries[index];
            const name = utf8_encoder.encode(entry.name);
            const record_length = 24 + name.byteLength + 7 & ~7;
            if (payload.length + record_length > limit) break;
            const attributes = await filesystem.getattr(entry.record.node);
            payload.alloc(FuseDirent).value = {
              ino: entry.record.id,
              off: BigInt(index + 1),
              namelen: name.byteLength,
              type: DirentType[mode_type(attributes.mode)]
            };
            payload.append(name);
            payload.bump(-payload.length & 7);
          }
        } finally {
          for (const record of transient) collect_record(record);
        }
        break;
      }
      case FuseOpcode.STATFS: {
        const stat = await filesystem.statfs?.(node2.node) ?? {};
        payload.alloc(FuseStatfsOut).value = {
          blocks: stat.blocks ?? 0n,
          bfree: stat.blocksFree ?? 0n,
          bavail: stat.blocksAvailable ?? 0n,
          files: stat.files ?? 0n,
          ffree: stat.filesFree ?? 0n,
          bsize: stat.blockSize ?? 4096,
          namelen: stat.nameLength ?? 255,
          frsize: stat.fragmentSize ?? stat.blockSize ?? 4096,
          padding: 0,
          spare: Array(6).fill(0)
        };
        break;
      }
      case FuseOpcode.ACCESS: {
        const request = body.struct(FuseAccessIn);
        if (filesystem.access) await filesystem.access(node2.node, request.mask);
        break;
      }
      case FuseOpcode.INTERRUPT:
        return void 0;
      case FuseOpcode.DESTROY:
        await finalize();
        break;
      default:
        throw new UnsupportedOperation();
    }
    if (payload.length > capacity - FuseOutHeader.size) {
      throw new FSError("EIO", "response exceeds the guest's response buffer");
    }
    return payload;
  }
  async function notify(queue) {
    for (const chain of queue) {
      const buffers = [...chain];
      const request = concatenate(buffers, false);
      const capacity = buffers.filter((buffer) => buffer.writable).reduce((total, buffer) => total + buffer.array.byteLength, 0);
      let unique = 0n;
      try {
        let saw_writable = false;
        for (const buffer of buffers) {
          if (!buffer.writable && saw_writable) {
            throw new FSError("EINVAL", "readable descriptor follows response");
          }
          saw_writable ||= buffer.writable;
        }
        const body = new Reader(request);
        const header = body.struct(FuseInHeader);
        unique = header.unique;
        if (header.len !== request.byteLength || header.len < FuseInHeader.size) {
          throw new FSError("EINVAL", "invalid FUSE request length");
        }
        if (capacity < minimum_response_capacity(header.opcode)) {
          throw new FSError("EINVAL", "FUSE response buffer is too small");
        }
        const payload = await process2(header, body, capacity);
        if (payload === void 0) {
          chain.release(0);
          continue;
        }
        const response = new Bytes(FuseOutHeader.size + payload.length);
        response.alloc(FuseOutHeader).value = {
          len: FuseOutHeader.size + payload.length,
          error: 0,
          unique
        };
        response.append(payload.array);
        scatter(buffers, response.array);
        chain.release(response.array.byteLength);
      } catch (error) {
        if (capacity < FuseOutHeader.size) {
          chain.release(0);
          continue;
        }
        const response = new Bytes(FuseOutHeader.size);
        const errno = error instanceof FSError ? error.errno : error instanceof RangeError ? Errno.EINVAL : Errno.EIO;
        response.alloc(FuseOutHeader).value = {
          len: FuseOutHeader.size,
          error: -errno,
          unique
        };
        scatter(buffers, response.array);
        chain.release(FuseOutHeader.size);
      }
    }
  }
  return new VirtioController(
    // 26 is the virtio-fs device ID.
    { deviceId: 26, config },
    { queues: [notify, notify], close: finalize }
  ).device;
}

// src/kernel/virtio/net.ts
var MAX_PENDING_FRAMES = 256;
var VirtioNetHeader = class extends Struct({
  flags: U8,
  gso_type: U8,
  header_length: U16LE,
  gso_size: U16LE,
  checksum_start: U16LE,
  checksum_offset: U16LE,
  buffer_count: U16LE
}) {
};
var Mac = FixedArray(U8, 6);
var EthernetHeader = class extends Struct({
  destination: Mac,
  source: Mac,
  type: U16BE
}) {
};
function mac_key(address) {
  return Array.from(address, (byte) => byte.toString(16).padStart(2, "0")).join(":");
}
function is_multicast(address) {
  return (address[0] & 1) !== 0;
}
function ethernetNetwork() {
  const ports = /* @__PURE__ */ new Set();
  const learned = /* @__PURE__ */ new Map();
  let closed = false;
  function addPort(receive) {
    assert2(!closed, "cannot add a port to a closed Ethernet network");
    const port = { receive, closed: false };
    ports.add(port);
    return {
      async send(frame) {
        if (closed) return;
        assert2(!port.closed, "cannot send from a closed Ethernet port");
        assert2(
          frame.byteLength >= EthernetHeader.size,
          "Ethernet frame is shorter than its header"
        );
        const header = new EthernetHeader(frame);
        learned.set(mac_key(header.source), port);
        const destination = learned.get(mac_key(header.destination));
        const recipients = destination && !is_multicast(header.destination) ? destination === port || destination.closed ? [] : [destination] : Array.from(
          ports,
          (candidate) => candidate !== port && !candidate.closed ? candidate : void 0
        ).filter((candidate) => !!candidate);
        await Promise.all(recipients.map((recipient) => recipient.receive(frame.slice())));
      },
      close() {
        if (port.closed) return;
        port.closed = true;
        ports.delete(port);
        for (const [mac, owner] of learned) {
          if (owner === port) learned.delete(mac);
        }
      }
    };
  }
  return {
    addPort,
    close() {
      if (closed) return;
      closed = true;
      for (const port of ports) port.closed = true;
      ports.clear();
      learned.clear();
    }
  };
}
function random_mac() {
  const address = crypto.getRandomValues(new Uint8Array(6));
  address[0] = (address[0] | 2) & 254;
  return Array.from(address);
}
function copy_packet(chain, packet) {
  let offset = 0;
  for (const descriptor of chain) {
    assert2(descriptor.writable, "virtio-net receive descriptor must be writable");
    const length = Math.min(packet.byteLength - offset, descriptor.array.byteLength);
    if (length > 0) descriptor.array.set(packet.subarray(offset, offset + length));
    offset += length;
  }
  assert2(offset === packet.byteLength, "virtio-net receive buffer is too small");
  chain.release(offset);
}
function ethernetDevice(network, { macAddress = random_mac() } = {}) {
  assert2(
    macAddress.length === 6 && macAddress.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255),
    "invalid MAC address"
  );
  const receive_buffers = [];
  const pending_frames = [];
  let controller;
  function flush_receive() {
    while (receive_buffers.length > 0 && pending_frames.length > 0) {
      const frame = pending_frames.shift();
      const packet = new Bytes(VirtioNetHeader.size + frame.byteLength);
      packet.alloc(VirtioNetHeader).value = {
        flags: 0,
        gso_type: 0,
        header_length: 0,
        gso_size: 0,
        checksum_start: 0,
        checksum_offset: 0,
        buffer_count: 1
      };
      packet.append(frame);
      copy_packet(receive_buffers.shift(), packet.array);
    }
  }
  const port = network.addPort((frame) => {
    if (pending_frames.length === MAX_PENDING_FRAMES) pending_frames.shift();
    pending_frames.push(frame.slice());
    flush_receive();
  });
  function receive(queue) {
    for (const chain of queue) receive_buffers.push(chain);
    flush_receive();
  }
  async function transmit(queue, _controller) {
    for (const chain of queue) {
      const chunks = [];
      let length = 0;
      for (const descriptor of chain) {
        assert2(!descriptor.writable, "virtio-net transmit descriptor must be readable");
        chunks.push(descriptor.array);
        length += descriptor.array.byteLength;
      }
      assert2(length >= VirtioNetHeader.size, "short virtio-net transmit header");
      const frame = new Bytes(length - VirtioNetHeader.size);
      let source_offset = VirtioNetHeader.size;
      for (const chunk of chunks) {
        if (source_offset >= chunk.byteLength) {
          source_offset -= chunk.byteLength;
          continue;
        }
        frame.append(chunk.subarray(source_offset));
        source_offset = 0;
      }
      assert2(frame.length === frame.capacity, "short virtio-net transmit frame");
      await port.send(frame.array);
      chain.release(0);
    }
  }
  const config = Uint8Array.from(macAddress);
  controller = new VirtioController(
    { deviceId: 1, features: 1n << 5n, config },
    {
      queues: [receive, transmit],
      reset() {
        receive_buffers.length = 0;
      },
      close() {
        port.close();
        receive_buffers.length = 0;
        pending_frames.length = 0;
      }
    }
  );
  return controller.expose({ macAddress });
}

// src/kernel/virtio/vsock.ts
var VsockConfig = class extends Struct({ guest_cid: U64LE }) {
};
var VsockHeader = class extends Struct({
  src_cid: U64LE,
  dst_cid: U64LE,
  src_port: U32LE,
  dst_port: U32LE,
  len: U32LE,
  type: U16LE,
  op: U16LE,
  flags: U32LE,
  buf_alloc: U32LE,
  fwd_cnt: U32LE
}) {
};
var VsockType = { STREAM: 1 };
var VsockOp = {
  REQUEST: 1,
  RESPONSE: 2,
  RST: 3,
  SHUTDOWN: 4,
  RW: 5,
  CREDIT_UPDATE: 6,
  CREDIT_REQUEST: 7
};
var VsockShutdown = {
  RCV: 1,
  SEND: 2
};
var HOST_CID = 2n;
var DEFAULT_VSOCK_BUF_ALLOC = 256 * 1024;
var MAX_VSOCK_PAYLOAD = 2048;
function concat_bytes(chunks) {
  const length = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}
function create_vsock_connection(ops, local_port, peer_port) {
  const read_buffer = [];
  const read_waiters = [];
  const credit_waiters = [];
  let closed = false;
  let bytes_read = 0;
  let bytes_written = 0;
  let last_credit_update = 0;
  let peer_buf_alloc = DEFAULT_VSOCK_BUF_ALLOC;
  let peer_fwd_cnt = 0;
  let write_tail = Promise.resolve();
  function wake_credit_waiters() {
    while (credit_waiters.length > 0) credit_waiters.shift()();
  }
  function close_from_peer() {
    if (closed) return;
    closed = true;
    while (read_waiters.length > 0) {
      read_waiters.shift()(new Uint8Array());
    }
    wake_credit_waiters();
  }
  async function read_chunk() {
    const chunk = read_buffer.shift();
    if (chunk) return chunk;
    if (closed) return new Uint8Array();
    return new Promise((resolve) => read_waiters.push(resolve));
  }
  function consume(length) {
    bytes_read = bytes_read + length >>> 0;
    const consumed = bytes_read - last_credit_update >>> 0;
    if (consumed >= DEFAULT_VSOCK_BUF_ALLOC / 4) {
      last_credit_update = bytes_read;
      ops.send(VsockOp.CREDIT_UPDATE, 0, new Uint8Array(), bytes_read);
    }
  }
  async function read() {
    const chunk = await read_chunk();
    consume(chunk.byteLength);
    return chunk;
  }
  async function readExactly(length) {
    const out = new Uint8Array(length);
    let offset = 0;
    while (offset < length) {
      const chunk = await read_chunk();
      if (chunk.byteLength === 0) break;
      const n = Math.min(chunk.byteLength, length - offset);
      out.set(chunk.subarray(0, n), offset);
      offset += n;
      consume(n);
      if (n < chunk.byteLength) {
        read_buffer.unshift(chunk.subarray(n).slice());
      }
    }
    return out.subarray(0, offset);
  }
  async function write_serialized(data) {
    let offset = 0;
    while (offset < data.byteLength) {
      if (closed) throw new Error("vsock connection is closed");
      const used = bytes_written - peer_fwd_cnt >>> 0;
      const available = Math.max(0, peer_buf_alloc - used);
      if (available === 0) {
        await new Promise((resolve) => credit_waiters.push(resolve));
        continue;
      }
      const n = Math.min(MAX_VSOCK_PAYLOAD, available, data.byteLength - offset);
      ops.send(VsockOp.RW, 0, data.subarray(offset, offset + n), bytes_read);
      offset += n;
      bytes_written = bytes_written + n >>> 0;
    }
  }
  function write(data) {
    const bytes = data.slice();
    const result = write_tail.then(() => write_serialized(bytes));
    write_tail = result.catch(() => {
    });
    return result;
  }
  const connection = {
    read,
    readExactly,
    write,
    close() {
      if (closed) return;
      ops.close();
      close_from_peer();
    }
  };
  return {
    connection,
    local_port,
    peer_port,
    get bytes_read() {
      return bytes_read;
    },
    update_credit(buf_alloc, fwd_cnt) {
      peer_buf_alloc = buf_alloc;
      peer_fwd_cnt = fwd_cnt;
      wake_credit_waiters();
    },
    enqueue(data) {
      if (closed || data.byteLength === 0) return;
      const waiter = read_waiters.shift();
      if (waiter) waiter(data);
      else read_buffer.push(data.slice());
    },
    close_from_peer
  };
}
function vsockDevice({ guestCid = 3n } = {}) {
  const config = new Uint8Array(VsockConfig.size);
  new VsockConfig(config).guest_cid = guestCid;
  const rx_buffers = [];
  const pending_packets = [];
  const connections = /* @__PURE__ */ new Map();
  let next_port = 49152;
  let closed = false;
  function allocate_port() {
    for (let attempts = 0; attempts < 65536 - 49152; attempts++) {
      const port = next_port;
      next_port = port === 65535 ? 49152 : port + 1;
      if (!connections.has(port)) return port;
    }
    throw new Error("no local vsock ports available");
  }
  function flush_rx(_controller) {
    while (pending_packets.length > 0 && rx_buffers.length > 0) {
      const packet = pending_packets.shift();
      const chain = rx_buffers.shift();
      const [desc, next_desc] = chain;
      assert2(desc && desc.writable, "vsock rx buffer must be writable");
      assert2(!next_desc, "vsock rx buffer should be a single descriptor");
      assert2(desc.array.byteLength >= packet.byteLength, "vsock rx buffer too small");
      desc.array.set(packet);
      chain.release(packet.byteLength);
    }
  }
  function send_packet(controller2, connection, op, flags, payload, fwd_cnt = connection.bytes_read) {
    const packet = new Uint8Array(VsockHeader.size + payload.byteLength);
    const hdr = new VsockHeader(packet);
    hdr.src_cid = HOST_CID;
    hdr.dst_cid = guestCid;
    hdr.src_port = connection.local_port;
    hdr.dst_port = connection.peer_port;
    hdr.len = payload.byteLength;
    hdr.type = VsockType.STREAM;
    hdr.op = op;
    hdr.flags = flags;
    hdr.buf_alloc = DEFAULT_VSOCK_BUF_ALLOC;
    hdr.fwd_cnt = fwd_cnt;
    packet.set(payload, VsockHeader.size);
    pending_packets.push(packet);
    flush_rx(controller2);
  }
  function read_tx_packet(chain) {
    const readable = Array.from(chain, (desc) => {
      assert2(!desc.writable, "vsock tx descriptor must be readable");
      return desc.array;
    });
    const header_bytes = concat_bytes(readable);
    assert2(header_bytes.byteLength >= VsockHeader.size, "short vsock header");
    const header = new VsockHeader(header_bytes);
    const payload = header_bytes.subarray(VsockHeader.size, VsockHeader.size + header.len);
    return { header, payload };
  }
  function handle_tx_packet(controller2, header, payload) {
    const local_port = header.dst_port;
    const state = connections.get(local_port);
    if (!state) return;
    const connection = state.controller;
    connection.update_credit(header.buf_alloc, header.fwd_cnt);
    switch (header.op) {
      case VsockOp.RESPONSE:
        state.connected = true;
        state.resolve(connection.connection);
        break;
      case VsockOp.RW:
        connection.enqueue(payload);
        break;
      case VsockOp.CREDIT_UPDATE:
        break;
      case VsockOp.CREDIT_REQUEST:
        send_packet(controller2, connection, VsockOp.CREDIT_UPDATE, 0, new Uint8Array());
        break;
      case VsockOp.SHUTDOWN:
        send_packet(controller2, connection, VsockOp.RST, 0, new Uint8Array());
        if (!state.connected) {
          state.reject(new Error("guest shut down vsock connection"));
        }
        connection.close_from_peer();
        connections.delete(local_port);
        break;
      case VsockOp.RST:
        if (!state.connected) {
          state.reject(new Error("guest reset vsock connection"));
        }
        connection.close_from_peer();
        connections.delete(local_port);
        break;
      default:
        console.warn("unknown vsock op", header.op);
    }
  }
  function notify_rx(queue, controller2) {
    for (const chain of queue) rx_buffers.push(chain);
    flush_rx(controller2);
  }
  function notify_tx(queue, controller2) {
    for (const chain of queue) {
      const { header, payload } = read_tx_packet(chain);
      handle_tx_packet(controller2, header, payload);
      chain.release(0);
    }
  }
  function reset_device() {
    rx_buffers.length = 0;
    pending_packets.length = 0;
    for (const state of connections.values()) {
      if (!state.connected) {
        state.reject(new Error("vsock device reset while connecting"));
      }
      state.controller.close_from_peer();
    }
    connections.clear();
  }
  function close_device(controller2) {
    if (closed) return;
    for (const state of connections.values()) {
      send_packet(controller2, state.controller, VsockOp.RST, 0, new Uint8Array());
      if (!state.connected) {
        state.reject(new Error("vsock device closed while connecting"));
      }
      state.controller.close_from_peer();
    }
    connections.clear();
    closed = true;
  }
  const controller = new VirtioController(
    { deviceId: 19, config },
    {
      queues: [
        notify_rx,
        notify_tx,
        () => {
        }
      ],
      reset: reset_device,
      close: close_device
    }
  );
  function connect(port, { timeoutMs = 5e3 } = {}) {
    if (closed) {
      return Promise.reject(new Error("vsock device is closed"));
    }
    const local_port = allocate_port();
    const connection = create_vsock_connection(
      {
        send(op, flags, payload, fwd_cnt) {
          if (closed) return;
          const connection2 = connections.get(local_port)?.controller;
          if (!connection2) return;
          send_packet(controller, connection2, op, flags, payload, fwd_cnt);
        },
        close() {
          const connection2 = connections.get(local_port)?.controller;
          if (!connection2) return;
          send_packet(
            controller,
            connection2,
            VsockOp.SHUTDOWN,
            VsockShutdown.RCV | VsockShutdown.SEND,
            new Uint8Array()
          );
        }
      },
      local_port,
      port
    );
    const promise = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        send_packet(controller, connection, VsockOp.RST, 0, new Uint8Array());
        connections.delete(local_port);
        connection.close_from_peer();
        reject(new Error(`timed out connecting to guest vsock port ${port}`));
      }, timeoutMs);
      connections.set(local_port, {
        controller: connection,
        connected: false,
        resolve(value) {
          clearTimeout(timeout);
          resolve(value);
        },
        reject(error) {
          clearTimeout(timeout);
          reject(error);
        }
      });
    });
    send_packet(controller, connection, VsockOp.REQUEST, 0, new Uint8Array());
    return promise;
  }
  return controller.expose({ connect, close: controller.close });
}

// src/kernel/index.ts
var MachinePanicError = class extends Error {
  constructor() {
    super("kernel panic");
    this.name = "MachinePanicError";
  }
};
async function read_resources() {
  const { bytes, module: vmlinux } = await platform.load_wasm(
    new URL("../vmlinux.wasm", import.meta.url)
  );
  const memories = read_wasm_memories(bytes);
  assert2(
    memories.imports.length === 1 && memories.definitions.length === 0,
    "Kernel must define exactly one imported memory"
  );
  const memory = memories.imports[0];
  assert2(
    memory.module === "env" && memory.name === "memory",
    "Kernel memory must be imported as env.memory"
  );
  assert2(
    memory.type.address === "i32" && memory.type.shared,
    "Kernel memory must be a shared memory32"
  );
  const custom_section = (name) => {
    const sections2 = WebAssembly.Module.customSections(vmlinux, name);
    const section = sections2[0];
    assert2(section && sections2.length === 1, `Missing custom section: ${name}`);
    return section;
  };
  const sections = JSON.parse(new TextDecoder().decode(custom_section(".linux.sections")));
  const initramfs = new Uint8Array(custom_section(".linux.initramfs"));
  return {
    vmlinux,
    memory: memory.type,
    sections,
    initramfs
  };
}
var resources;
var load_resources = () => resources ??= read_resources();
var PAGE_SIZE = 65536;
var KERNEL_MEMORY_MAXIMUM_PAGES = 65535;
function kernel_initial_pages(memory, initcpio_size) {
  const maximum = BigInt(KERNEL_MEMORY_MAXIMUM_PAGES);
  assert2(
    memory.minimum <= maximum && memory.maximum !== void 0 && memory.maximum >= maximum,
    "Kernel memory limits are incompatible with a 4 GiB - 64 KiB memory"
  );
  const initcpio_pages = Math.ceil(initcpio_size / PAGE_SIZE);
  const initial = Number(memory.minimum) + initcpio_pages;
  assert2(initial <= KERNEL_MEMORY_MAXIMUM_PAGES, "Initramfs does not fit in kernel memory");
  return initial;
}
async function bootMachine(options) {
  const configured = await configure_machine(options.args ?? [], options.plugins ?? []);
  const { devices, plugins } = configured;
  const workers = /* @__PURE__ */ new Set();
  let closed = false;
  let failed = false;
  let finish_error;
  let finish_promise;
  const closed_promise = Promise.withResolvers();
  void closed_promise.promise.catch(() => {
  });
  const boot_console = new TransformStream();
  const boot_console_writer = boot_console.writable.getWriter();
  const boot_console_write = (message) => {
    void boot_console_writer.write(new Uint8Array(message)).catch(() => {
    });
  };
  const boot_console_close = () => {
    void boot_console_writer.close().catch(() => {
    });
  };
  const finish = () => {
    if (finish_promise) return finish_promise;
    closed = true;
    finish_promise = (async () => {
      const device_closes = devices.map((device) => close_virtio_device(device));
      for (const result of await Promise.allSettled(device_closes)) {
        if (result.status === "rejected" && !failed) {
          failed = true;
          finish_error = result.reason;
        }
      }
      try {
        await Promise.all(Array.from(workers, (worker) => worker.terminate()));
      } catch (termination_error) {
        if (!failed) {
          failed = true;
          finish_error = termination_error;
        }
      }
      boot_console_close();
      if (failed) closed_promise.reject(finish_error);
      else closed_promise.resolve();
    })();
    return finish_promise;
  };
  const fail = (error) => {
    if (!failed) {
      failed = true;
      finish_error = error;
    }
    return finish();
  };
  const close = () => void finish();
  try {
    const { sections, vmlinux, initramfs, memory: memory_type } = await load_resources();
    const initcpio = options.initcpio ? await options.initcpio : void 0;
    const module_pages = Number(memory_type.minimum);
    const initcpio_addr = module_pages * PAGE_SIZE;
    const pages = kernel_initial_pages(memory_type, initcpio?.byteLength ?? 0);
    const requested_pages = options.memoryMiB ? Math.floor(options.memoryMiB * 16) : KERNEL_MEMORY_MAXIMUM_PAGES;
    const { memory: wasm_memory, maximum_pages } = allocate_shared_memory(
      pages,
      Math.max(pages, Math.min(KERNEL_MEMORY_MAXIMUM_PAGES, requested_pages))
    );
    assert2(wasm_memory.buffer.byteLength === pages * PAGE_SIZE);
    const devicetree = {
      "#address-cells": 1,
      "#size-cells": 1,
      chosen: {
        "rng-seed": crypto.getRandomValues(new Uint8Array(64)),
        bootargs: `console=hvc0 ${configured.args.join(" ")}`,
        ncpus: options.cpus
      },
      aliases: {},
      memory: {
        device_type: "memory",
        reg: [0, maximum_pages * PAGE_SIZE]
      },
      "reserved-memory": {
        "#address-cells": 1,
        "#size-cells": 1,
        ranges: void 0
      }
    };
    for (const [i, dev] of devices.entries()) {
      const device = virtio_device_description(dev);
      devicetree[`virtio${i}`] = {
        compatible: `virtio,wasm`,
        "host-id": i,
        "virtio-device-id": device.device_id,
        features: device.features,
        config: device.config
      };
    }
    const memory_reservations = [];
    if (initcpio) {
      const chosen = devicetree.chosen;
      chosen["linux,initrd-start"] = initcpio_addr;
      chosen["linux,initrd-end"] = initcpio_addr + initcpio.byteLength;
      new Uint8Array(wasm_memory.buffer).set(
        new Uint8Array(initcpio.buffer, initcpio.byteOffset, initcpio.byteLength),
        initcpio_addr
      );
      memory_reservations.push({
        address: initcpio_addr,
        size: initcpio.byteLength
      });
    }
    devicetree.chosen.sections = sections;
    merge_device_tree(devicetree, configured.deviceTree);
    const generated_devicetree = generate_devicetree(devicetree, {
      memory_reservations
    });
    let instance;
    const start_worker = (name, init) => {
      if (closed) return;
      const worker = platform.spawn_worker(name, {
        on_message(raw) {
          const message = raw;
          switch (message.type) {
            case "spawn_worker":
              try {
                start_worker(message.name, {
                  type: "forwarded_init",
                  port: message.port
                });
              } catch (error) {
                void fail(error);
              }
              break;
            case "boot_console_write":
              boot_console_write(message.message);
              break;
            case "boot_console_close":
              boot_console_close();
              break;
            case "terminate_machine":
              switch (message.reason) {
                case MachineTerminationReason.Clean:
                  void finish();
                  break;
                case MachineTerminationReason.Panic:
                  void fail(new MachinePanicError());
                  break;
                default:
                  void fail(new Error(`unknown machine termination reason: ${message.reason}`));
              }
              break;
            case "run_on_main":
              assert2(instance);
              instance.exports.__indirect_function_table.get(message.fn >>> 0)(message.arg);
              break;
            case "worker_exit": {
              workers.delete(worker);
              break;
            }
            default:
              unreachable(message);
          }
        },
        on_error: fail
      });
      workers.add(worker);
      worker.post(init, init.type === "forwarded_init" ? [init.port] : void 0);
    };
    const spawn_worker = (fn, arg, name, user, copy_user_memory) => {
      assert2(!copy_user_memory);
      start_worker(name, {
        type: "init",
        fn,
        arg,
        vmlinux,
        memory: wasm_memory,
        user,
        user_copy_status: null
      });
      return 0;
    };
    const unavailable = () => {
      throw new Error("not available on main thread");
    };
    const imports = {
      env: { memory: wasm_memory },
      boot: {
        get_devicetree: (buf, size) => {
          const address = buf >>> 0;
          const capacity = size >>> 0;
          if (address === 0 && capacity === 0) return generated_devicetree.byteLength;
          assert2(capacity >= generated_devicetree.byteLength, "Device tree truncated");
          new Uint8Array(wasm_memory.buffer).set(generated_devicetree, address);
          return generated_devicetree.byteLength;
        },
        get_initramfs: (buf, size) => {
          const address = buf >>> 0;
          const capacity = size >>> 0;
          assert2(capacity >= initramfs.byteLength, "Initramfs truncated");
          new Uint8Array(wasm_memory.buffer).set(initramfs, address);
          return initramfs.byteLength;
        }
      },
      kernel: kernel_imports({
        is_worker: false,
        memory: wasm_memory,
        spawn_worker,
        boot_console_write,
        boot_console_close,
        terminate_machine: unavailable,
        run_on_main: unavailable,
        get_user_context: unavailable,
        worker_exit: unavailable
      }),
      user: {
        compile_begin: unavailable,
        compile_write: unavailable,
        compile_end: unavailable,
        compile_abort: unavailable,
        instantiate: unavailable,
        call: unavailable,
        switch_entry: unavailable,
        call_signal_handler: unavailable,
        call_siginfo_handler: unavailable,
        read: unavailable,
        write: unavailable,
        write_zeroes: unavailable,
        futex_atomic_op: unavailable,
        futex_atomic_cmpxchg: unavailable
      },
      virtio: virtio_imports({
        memory: wasm_memory,
        devices,
        on_error: fail,
        trigger_irq(irq) {
          assert2(instance);
          instance.exports.trigger_irq(irq);
        }
      })
    };
    instance = await WebAssembly.instantiate(vmlinux, imports);
    instance.exports.boot();
    const machine = {
      memory: wasm_memory,
      bootConsole: boot_console.readable,
      closed: closed_promise.promise,
      close,
      [Symbol.dispose]: close,
      async [Symbol.asyncDispose]() {
        close();
        await closed_promise.promise;
      }
    };
    await run_machine_booted(plugins, machine);
    return machine;
  } catch (error) {
    await finish();
    throw error;
  }
}
export {
  FSError,
  MachinePanicError,
  VirtioController,
  blockDevice,
  bootMachine,
  consoleDevice,
  entropyDevice,
  ethernetDevice,
  ethernetNetwork,
  fileSystemDevice,
  serveDevice,
  vsockDevice,
  workerDevice
};
