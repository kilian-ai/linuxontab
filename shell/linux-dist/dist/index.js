import {
  EventEmitter,
  __toBinary,
  assert,
  get_script_path,
  kernel_imports,
  unreachable
} from "./chunk-QXRZASYZ.js";

// src/build/initramfs_data.cpio
var initramfs_data_default = __toBinary("MDcwNzAxMDAwMDAyRDEwMDAwNDFFRDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMjZBMDAxRDg0MDAwMDAwMDAwMDAwMDAwMzAwMDAwMDAxMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA0MDAwMDAwMDBkZXYAAAAwNzA3MDEwMDAwMDJEMjAwMDAyMTgwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAxNkEwMDFEODQwMDAwMDAwMDAwMDAwMDAzMDAwMDAwMDEwMDAwMDAwNTAwMDAwMDAxMDAwMDAwMEMwMDAwMDAwMGRldi9jb25zb2xlAAAAMDcwNzAxMDAwMDAyRDMwMDAwNDFDMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMjZBMDAxRDg0MDAwMDAwMDAwMDAwMDAwMzAwMDAwMDAxMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA1MDAwMDAwMDByb290AAAwNzA3MDEwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAxMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMEIwMDAwMDAwMFRSQUlMRVIhISEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");

// src/build/sections.json
var sections_default = {
  ".data.once": [191656, 636],
  ".data..percpu": [195136, 8176],
  ".data..percpu..shared_aligned": [230080, 3216],
  ".init.setup": [691716, 972],
  __param: [696060, 1800],
  ".initcall7.init": [697908, 64],
  ".initcallrootfs.init": [697972, 4],
  ".initcall1.init": [697976, 32],
  ".initcall6.init": [698008, 160],
  ".initcallearly.init": [698168, 44],
  ".initcall5.init": [698212, 108],
  ".initcall4.init": [698320, 64],
  ".initcall2.init": [707396, 28],
  ".con_initcall.init": [712660, 8],
  ".initcall3s.init": [712668, 4],
  ".initcall7s.init": [712672, 4]
};

// src/build/vmlinux.wasm
var vmlinux_default = "./vmlinux-UHA6PIC5.wasm";

// src/bytes.ts
function Struct(layout) {
  let size = 0;
  return class {
    #dv;
    constructor(view) {
      this.#dv = new DataView(view.buffer, view.byteOffset, view.byteLength);
    }
    static {
      for (const [key, type] of Object.entries(
        layout
      )) {
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
        arr[i] = type.get(dv, offset + type.size * i);
      }
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
var U64LE = {
  get(dv, offset) {
    return dv.getBigUint64(offset, true);
  },
  set(dv, offset, value) {
    dv.setBigUint64(offset, value, true);
  },
  size: 8
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
    const self = this;
    return {
      get value() {
        return type.get(self.dv, offset);
      },
      set value(value) {
        type.set(self.dv, offset, value);
      }
    };
  }
};

// src/devicetree.ts
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
  function walk_tree(node, name) {
    align(bytes, 4);
    bytes.alloc(U32BE).value = FDT_BEGIN_NODE;
    const encodedName = new TextEncoder().encode(name);
    assert(
      encodedName.byteLength <= NODE_NAME_MAX_LEN,
      `property name too long: ${name}`
    );
    bytes.append(encodedName);
    bytes.alloc(U8).value = 0;
    align(bytes, 4);
    const children = Object.entries(node).filter(
      ([, value]) => typeof value === "object" && value?.constructor === Object
    );
    const properties = Object.entries(node).filter(
      ([, value]) => !(typeof value === "object" && value?.constructor === Object)
    );
    for (const [name2, prop] of properties) {
      align(bytes, 4);
      bytes.alloc(U32BE).value = FDT_PROP;
      const property = bytes.alloc(Property);
      assert(
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

// src/virtio.ts
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
  #mem;
  #queue;
  id;
  skip;
  desc;
  constructor(mem, queue, id, skip, desc) {
    this.#mem = mem;
    this.#queue = queue;
    this.id = id;
    this.skip = skip;
    this.desc = desc;
  }
  release(written) {
    const queue = this.#queue;
    const desc = queue.desc[queue.used_idx];
    assert(desc);
    const avail = (desc.flags & DescriptorFlags.AVAIL) !== 0;
    const used = (desc.flags & DescriptorFlags.USED) !== 0;
    if (avail === used || avail !== queue.wrap) throw new Error("ring full");
    let flags = 0;
    if (queue.wrap) flags |= DescriptorFlags.AVAIL | DescriptorFlags.USED;
    if (written > 0) flags |= DescriptorFlags.WRITE;
    desc.id = this.id;
    desc.len = written;
    desc.flags = flags;
    queue.used_idx += this.skip;
    if (queue.used_idx >= queue.size) {
      queue.used_idx -= queue.size;
      queue.wrap = !queue.wrap;
    }
  }
  *[Symbol.iterator]() {
    for (const desc of this.desc) {
      yield {
        array: new Uint8Array(this.#mem.buffer, Number(desc.addr), desc.len),
        writable: (desc.flags & DescriptorFlags.WRITE) !== 0
      };
    }
  }
};
var Virtqueue = class {
  #mem;
  size;
  desc;
  wrap = true;
  used_idx = 0;
  avail_idx = 0;
  constructor(mem, size, desc_addr) {
    assert(size !== 0);
    assert(mem.byteOffset === 0);
    this.#mem = mem;
    this.size = size;
    this.desc = FixedArray(VirtqDescriptor, size).get(mem, desc_addr);
  }
  #pop() {
    let i = this.#advance();
    if (i === null) return null;
    const head = i;
    let desc = this.desc[i];
    assert(desc);
    const chain = new Chain(
      this.#mem,
      this,
      desc.id,
      1,
      this.desc.slice(head, i + 1)
    );
    if (desc.flags & DescriptorFlags.NEXT) {
      do {
        i = this.#advance();
        if (i === null) throw new Error("no next descriptor is available");
        desc = this.desc[i];
        assert(desc);
      } while (desc.flags & DescriptorFlags.NEXT);
      chain.skip = i - head + 1;
      chain.desc = this.desc.slice(head, i + 1);
    } else if (desc.flags & DescriptorFlags.INDIRECT) {
      if (desc.len % VirtqDescriptor.size !== 0) {
        throw new Error("malformed indirect buffer");
      }
      chain.desc = FixedArray(VirtqDescriptor, desc.len / VirtqDescriptor.size).get(this.#mem, Number(desc.addr));
    }
    return chain;
  }
  *[Symbol.iterator]() {
    let chain;
    while (chain = this.#pop()) yield chain;
  }
  #advance() {
    const desc = this.desc[this.avail_idx];
    assert(desc);
    const avail = (desc.flags & DescriptorFlags.AVAIL) !== 0;
    const used = (desc.flags & DescriptorFlags.USED) !== 0;
    if (avail === used || avail !== this.wrap) return null;
    const index = this.avail_idx;
    this.avail_idx = (this.avail_idx + 1) % this.size;
    return index;
  }
};
var VirtioDevice = class {
  features = TransportFeatures.VERSION_1 | TransportFeatures.RING_PACKED | TransportFeatures.INDIRECT_DESC;
  trigger_interrupt = (kind) => {
    throw new Error("trigger_interrupt called before setup");
  };
  vqs = [];
  enable(vq, queue) {
    this.vqs[vq] = queue;
  }
  disable(vq) {
    const queue = this.vqs[vq];
    assert(queue);
  }
  setup_complete() {
  }
};
var EmptyStruct = class extends Struct({}) {
};
var BlockDeviceFeatures = {
  RO: 1n << 5n,
  FLUSH: 1n << 9n
};
var BlockDeviceConfig = class extends Struct({
  capacity: U64LE
}) {
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
var BlockDevice = class extends VirtioDevice {
  ID = 2;
  config_bytes = new Uint8Array(BlockDeviceConfig.size);
  config = new BlockDeviceConfig(this.config_bytes);
  #storage;
  constructor(storage) {
    super();
    this.#storage = storage;
    if (storage.flush) this.features |= BlockDeviceFeatures.FLUSH;
    if (!storage.write) this.features |= BlockDeviceFeatures.RO;
    this.config.capacity = BigInt(storage.capacity / 512);
  }
  async notify(vq) {
    assert(vq === 0);
    const queue = this.vqs[vq];
    assert(queue);
    for (const chain of queue) {
      let set_status2 = function(value) {
        status_desc.array[0] = value;
      };
      var set_status = set_status2;
      const descs = [...chain];
      const header = descs[0];
      const status = descs[descs.length - 1];
      const data = descs.slice(1, -1);
      assert(header && !header.writable, "header must be readonly");
      assert(
        header.array.byteLength === BlockDeviceRequest.size,
        `header size is ${header.array.byteLength}`
      );
      assert(status && status.writable, "status must be writable");
      assert(
        status.array.byteLength === 1,
        `status size is ${status.array.byteLength}`
      );
      const status_desc = status;
      const request = new BlockDeviceRequest(header.array);
      let n = 0;
      let offset = Number(request.sector) * 512;
      switch (request.type) {
        case BlockDeviceRequestType.IN: {
          for (const desc of data) {
            assert(desc.writable, "data must be writable when IN");
            const arr = await this.#storage.read(offset, desc.array.byteLength);
            desc.array.set(arr);
            n += arr.byteLength;
            offset += arr.byteLength;
          }
          set_status2(BlockDeviceStatus.OK);
          break;
        }
        case BlockDeviceRequestType.OUT: {
          if (!this.#storage.write) {
            set_status2(BlockDeviceStatus.UNSUPP);
            break;
          }
          let ok = true;
          for (const desc of data) {
            assert(!desc.writable, "data must be readonly when OUT");
            const written = await this.#storage.write(offset, desc.array);
            if (written !== desc.array.byteLength) {
              ok = false;
              break;
            }
            n += written;
            offset += written;
          }
          set_status2(ok ? BlockDeviceStatus.OK : BlockDeviceStatus.IOERR);
          break;
        }
        case BlockDeviceRequestType.FLUSH: {
          if (!this.#storage.flush) {
            set_status2(BlockDeviceStatus.UNSUPP);
            break;
          }
          await this.#storage.flush();
          set_status2(BlockDeviceStatus.OK);
          break;
        }
        case BlockDeviceRequestType.GET_ID: {
          console.log("GET_ID");
          set_status2(BlockDeviceStatus.OK);
          break;
        }
        default:
          console.error("unknown request type", request.type);
          set_status2(BlockDeviceStatus.UNSUPP);
      }
      chain.release(n);
    }
    this.trigger_interrupt("vring");
  }
};
var ConsoleDevice = class extends VirtioDevice {
  ID = 3;
  config_bytes = new Uint8Array(0);
  config = new EmptyStruct(this.config_bytes);
  #input;
  #output;
  constructor(input, output) {
    super();
    this.#input = input;
    this.#output = output.getWriter();
  }
  #writing = null;
  async #writer(queue) {
    const queue_iter = queue[Symbol.iterator]();
    const reader = this.#input.getReader();
    for (; ; ) {
      const { value, done } = await reader.read();
      if (done) break;
      let chunk = value;
      while (chunk.length > 0) {
        const chain = queue_iter.next().value;
        if (!chain) {
          console.warn("no more descriptors, dropping console input");
          break;
        }
        const [desc, trailing] = chain;
        assert(desc && desc.writable, "receiver must be writable");
        assert(!trailing, "too many descriptors");
        const n = Math.min(chunk.length, desc.array.byteLength);
        desc.array.set(chunk.subarray(0, n));
        chunk = chunk.subarray(n);
        chain.release(n);
      }
      this.trigger_interrupt("vring");
    }
  }
  async notify(vq) {
    const queue = this.vqs[vq];
    assert(queue);
    switch (vq) {
      case 0:
        this.#writing ??= this.#writer(queue);
        break;
      case 1:
        for (const chain of queue) {
          let n = 0;
          for (const { array, writable } of chain) {
            assert(!writable, "transmitter must be readable");
            await this.#output.write(array);
            n += array.byteLength;
          }
          chain.release(n);
        }
        break;
      default:
        console.error("ConsoleDevice: unknown vq", vq);
    }
  }
};
var EntropyDevice = class extends VirtioDevice {
  ID = 4;
  config_bytes = new Uint8Array(0);
  config = new EmptyStruct(this.config_bytes);
  notify(vq) {
    assert(vq === 0);
    const queue = this.vqs[vq];
    assert(queue);
    for (const chain of queue) {
      let n = 0;
      for (const { array, writable } of chain) {
        assert(writable);
        const arr = new Uint8Array(array.length);
        crypto.getRandomValues(arr);
        array.set(arr);
        n += array.byteLength;
      }
      chain.release(n);
    }
    this.trigger_interrupt("vring");
  }
};
function virtio_imports({
  memory,
  devices,
  trigger_irq_for_cpu
}) {
  const dv = new DataView(memory.buffer);
  return {
    set_features(dev, features) {
      const device = devices[dev];
      assert(device);
      assert(
        device.features === features,
        "the kernel should accept every feature we offer, and no more"
      );
    },
    enable_vring(dev, vq, size, desc_addr) {
      const device = devices[dev];
      assert(device);
      device.enable(
        vq,
        new Virtqueue(dv, size, desc_addr)
      );
    },
    disable_vring(dev, vq) {
      const device = devices[dev];
      assert(device);
      device.disable(vq);
    },
    setup(dev, irq, is_config_addr, is_vring_addr, config_addr, config_len) {
      const device = devices[dev];
      assert(device);
      const config_type = device.config.constructor;
      assert(config_len >= config_type.size, "config space too small");
      const new_config_bytes = new Uint8Array(
        dv.buffer,
        config_addr,
        config_len
      );
      new_config_bytes.set(device.config_bytes);
      device.config_bytes = new_config_bytes;
      device.config = config_type.get(dv, config_addr);
      device.trigger_interrupt = (kind) => {
        U8.set(dv, is_config_addr, kind === "config" ? 1 : 0);
        U8.set(dv, is_vring_addr, kind === "vring" ? 1 : 0);
        trigger_irq_for_cpu(0, irq);
      };
      device.setup_complete();
    },
    notify(dev, vq) {
      const device = devices[dev];
      assert(device);
      device.notify(vq);
    }
  };
}

// src/index.ts
var worker_url = get_script_path(() => import("./worker-Q7XWPLKR.js"), import.meta);
var vmlinux_response = fetch(new URL(vmlinux_default, import.meta.url));
var vmlinux_promise = "compileStreaming" in WebAssembly ? WebAssembly.compileStreaming(vmlinux_response) : vmlinux_response.then((r) => r.arrayBuffer()).then(WebAssembly.compile);
var INITCPIO_ADDR = 2097152;
var Machine = class extends EventEmitter {
  #boot_console;
  #boot_console_writer;
  #workers = [];
  #memory;
  #devices;
  #initcpio;
  memory;
  devicetree;
  get bootConsole() {
    return this.#boot_console.readable;
  }
  constructor(options) {
    super();
    this.#boot_console = new TransformStream();
    this.#boot_console_writer = this.#boot_console.writable.getWriter();
    this.#devices = options.devices;
    this.#initcpio = options.initcpio;
    const PAGE_SIZE = 65536;
    const BYTES_PER_MIB = 1048576;
    const bytes = (options.memoryMib ?? 128) * BYTES_PER_MIB;
    const pages = bytes / PAGE_SIZE;
    this.#memory = new WebAssembly.Memory({
      initial: pages,
      maximum: pages,
      shared: true
    });
    assert(this.#memory.buffer.byteLength === bytes);
    this.memory = new Uint8Array(this.#memory.buffer);
    this.devicetree = {
      "#address-cells": 1,
      "#size-cells": 1,
      chosen: {
        "rng-seed": crypto.getRandomValues(new Uint8Array(64)),
        bootargs: `console=hvc0 ${options.cmdline ?? ""}`,
        ncpus: options.cpus ?? navigator.hardwareConcurrency,
        sections: sections_default
      },
      aliases: {},
      memory: {
        device_type: "memory",
        reg: [0, bytes]
      },
      "reserved-memory": {
        "#address-cells": 1,
        "#size-cells": 1,
        ranges: void 0
      }
    };
    if (this.#initcpio) {
      const chosen = this.devicetree.chosen;
      chosen["linux,initrd-start"] = INITCPIO_ADDR;
      chosen["linux,initrd-end"] = INITCPIO_ADDR + this.#initcpio.byteLength;
      this.memory.set(
        new Uint8Array(
          this.#initcpio.buffer,
          this.#initcpio.byteOffset,
          this.#initcpio.byteLength
        ),
        INITCPIO_ADDR
      );
    }
    for (const [i, dev] of this.#devices.entries()) {
      this.devicetree[`virtio${i}`] = {
        compatible: `virtio,wasm`,
        "host-id": i,
        "virtio-device-id": dev.ID,
        features: dev.features,
        config: dev.config_bytes
      };
    }
  }
  async boot() {
    const memory_reservations = [];
    if (this.#initcpio) {
      memory_reservations.push({
        address: INITCPIO_ADDR,
        size: this.#initcpio.byteLength
      });
    }
    const devicetree = generate_devicetree(this.devicetree, {
      memory_reservations
    });
    const vmlinux = await vmlinux_promise;
    const boot_console_write = (message) => {
      this.#boot_console_writer.write(new Uint8Array(message)).catch(() => {
      });
    };
    const boot_console_close = () => {
      this.#boot_console_writer.close();
    };
    const spawn_worker = (fn, arg, name, user_module, user_memory) => {
      const worker = new Worker(worker_url, { type: "module", name });
      this.#workers.push(worker);
      worker.onmessage = (event) => {
        switch (event.data.type) {
          case "spawn_worker":
            spawn_worker(
              event.data.fn,
              event.data.arg,
              event.data.name,
              event.data.user_module,
              event.data.user_memory
            );
            break;
          case "boot_console_write":
            boot_console_write(event.data.message);
            break;
          case "boot_console_close":
            boot_console_close();
            break;
          case "run_on_main":
            instance.exports.__indirect_function_table.get(event.data.fn)(event.data.arg);
            break;
          default:
            unreachable(event.data);
        }
      };
      worker.onerror = (event) => {
        this.emit("error", event);
      };
      worker.postMessage(
        {
          fn,
          arg,
          vmlinux,
          memory: this.#memory,
          parent_user_module: user_module,
          parent_user_memory: user_memory
        }
      );
    };
    const unavailable = () => {
      throw new Error("not available on main thread");
    };
    const imports = {
      env: { memory: this.#memory },
      boot: {
        get_devicetree: (buf, size) => {
          assert(size >= devicetree.byteLength, "Device tree truncated");
          this.memory.set(devicetree, buf);
        },
        get_initramfs: (buf, size) => {
          assert(size >= initramfs_data_default.byteLength, "Initramfs truncated");
          this.memory.set(initramfs_data_default, buf);
          return initramfs_data_default.byteLength;
        }
      },
      kernel: kernel_imports({
        is_worker: false,
        memory: this.#memory,
        spawn_worker,
        boot_console_write,
        boot_console_close,
        run_on_main: unavailable,
        get_user_module: unavailable,
        get_user_memory: unavailable
      }),
      user: {
        compile: unavailable,
        instantiate: unavailable,
        call: unavailable,
        switch_entry: unavailable,
        call_signal_handler: unavailable,
        read: unavailable,
        write: unavailable,
        write_zeroes: unavailable
      },
      virtio: virtio_imports({
        memory: this.#memory,
        devices: this.#devices,
        trigger_irq_for_cpu(cpu, irq) {
          instance.exports.trigger_irq_for_cpu(cpu, irq);
        }
      })
    };
    const instance = await WebAssembly.instantiate(vmlinux, imports);
    instance.exports.boot();
  }
};
export {
  BlockDevice,
  ConsoleDevice,
  EntropyDevice,
  Machine
};
//# sourceMappingURL=index.js.map
