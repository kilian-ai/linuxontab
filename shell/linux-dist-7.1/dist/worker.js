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

// src/lot/wali-bridge.js
function makeWaliImports({ memory, kernel, syscall, log }) {
  const B = BigInt;
  const dbg = log || (() => {
  });
  const n = (x) => typeof x === "bigint" ? Number(B.asIntN(64, x)) : x;
  const i32 = (x) => n(x) | 0;
  const big = (x) => typeof x === "bigint" ? B.asIntN(64, x) : B(x | 0);
  const R = (r) => B(r | 0);
  const sc = (nr, ...a) => syscall(nr, ...[0, 1, 2, 3, 4, 5].map((k) => i32(a[k] === void 0 ? 0 : a[k])));
  const dv = () => new DataView(memory.buffer);
  const u8 = () => new Uint8Array(memory.buffer);
  const PAGE = 65536;
  const SCRATCH = memory.grow(1) * PAGE;
  let sp = 0;
  const scratch = (size, align = 8) => {
    sp = sp + align - 1 & ~(align - 1);
    const p = SCRATCH + sp;
    sp += size;
    if (sp > PAGE) throw new Error("wali scratch overflow");
    return p;
  };
  const reset = () => {
    sp = 16;
  };
  const EMPTY_STR = SCRATCH;
  const zero = (p, len) => u8().fill(0, p, p + len);
  const AT_FDCWD = -100, AT_EMPTY_PATH = 4096, AT_SYMLINK_NOFOLLOW = 256, AT_REMOVEDIR = 512;
  const ENOSYS = -38, EINVAL = -22, ENOMEM = -12, EBADF = -9;
  let args = null, debugAll = false;
  const loadArgs = () => {
    if (args) return args;
    args = { argv: [], envp: [] };
    try {
      const len = kernel.exports.get_args_length();
      if (len <= 0) {
        dbg("wali: get_args_length=" + len);
        return args;
      }
      const pages = Math.ceil(len / PAGE);
      const buf = memory.grow(pages) * PAGE;
      const gr = kernel.exports.get_args(buf);
      if (gr < 0) {
        dbg("wali: get_args=" + gr);
        return args;
      }
      const d = dv(), m = u8();
      const envc = d.getInt32(buf + 4, true), argc = d.getInt32(buf + 8, true);
      dbg("wali: args len=" + len + " argc=" + argc + " envc=" + envc);
      const argv = d.getUint32(buf + 12, true), envp = d.getUint32(buf + 16, true);
      const cstr = (p) => {
        let e = p;
        while (m[e]) e++;
        return new TextDecoder().decode(m.slice(p, e));
      };
      for (let i = 0; i < argc; i++) args.argv.push(cstr(d.getUint32(argv + 4 * i, true)));
      for (let i = 0; i < envc; i++) args.envp.push(cstr(d.getUint32(envp + 4 * i, true)));
      if (args.envp.includes("WALI_DEBUG=1")) debugAll = true;
    } catch (e) {
      dbg("wali: get_args failed: " + e);
    }
    return args;
  };
  const putStr = (p, s, max) => {
    const b = new TextEncoder().encode(s);
    const k = Math.min(b.length, max - 1);
    u8().set(b.subarray(0, k), p);
    u8()[p + k] = 0;
    return k;
  };
  const MAP_ANONYMOUS = 32, MAP_SHARED = 1, PROT_WRITE = 2;
  const shared = /* @__PURE__ */ new Map();
  const writeBack = (base, m, len) => {
    let put = 0;
    const n2 = Math.min(len, m.len);
    while (put < n2) {
      const r = sc(68, m.fd, base + put, n2 - put, m.off + put);
      if (r <= 0) {
        dbg("wali: mmap writeback failed " + r);
        break;
      }
      put += r;
    }
  };
  const free = [];
  const alloc = (bytes) => {
    const pages = Math.ceil(bytes / PAGE);
    let best = -1;
    for (let i = 0; i < free.length; i++) if (free[i].pages >= pages && (best < 0 || free[i].pages < free[best].pages)) best = i;
    if (best >= 0) {
      const run = free[best], base = run.base;
      if (run.pages === pages) free.splice(best, 1);
      else {
        run.base += pages * PAGE;
        run.pages -= pages;
      }
      zero(base, pages * PAGE);
      return base;
    }
    try {
      return memory.grow(pages) * PAGE;
    } catch (_) {
      return ENOMEM;
    }
  };
  const release = (addr, bytes) => {
    const base = addr >>> 0, pages = Math.ceil(bytes / PAGE);
    if (base % PAGE !== 0 || pages === 0) return;
    free.push({ base, pages });
    free.sort((a, b) => a.base - b.base);
    for (let i = 0; i + 1 < free.length; ) {
      if (free[i].base + free[i].pages * PAGE === free[i + 1].base) {
        free[i].pages += free[i + 1].pages;
        free.splice(i + 1, 1);
      } else i++;
    }
  };
  const grow = alloc;
  const host_mmap = (addr, length, prot, flags, fd, offset) => {
    const len = i32(length) >>> 0, fl = i32(flags), f = i32(fd);
    if (len === 0) return EINVAL;
    const base = grow(len);
    if (base < 0) return base;
    if (fl & MAP_ANONYMOUS || f < 0) return base;
    let off = Number(big(offset)), got = 0;
    while (got < len) {
      const r = sc(67, f, base + got, len - got, off + got);
      if (r <= 0) break;
      got += r;
    }
    if (fl & MAP_SHARED && i32(prot) & PROT_WRITE) {
      const d = sc(25, f, 0, 0, 0, 0, 0);
      shared.set(base, { fd: d >= 0 ? d : f, own: d >= 0, off, len });
      if (debugAll) dbg("wali: shared writable file mmap fd=" + f + " len=" + len + " @" + base.toString(16));
    }
    return base;
  };
  const host_munmap = (addr, len) => {
    const base = i32(addr) >>> 0, n2 = i32(len) >>> 0;
    const m = shared.get(base);
    if (m) {
      writeBack(base, m, n2);
      if (m.own) sc(57, m.fd, 0, 0, 0, 0, 0);
      shared.delete(base);
    }
    release(base, n2);
    return 0;
  };
  const host_msync = (addr, len) => {
    const base = i32(addr) >>> 0, m = shared.get(base);
    if (m) writeBack(base, m, i32(len) >>> 0);
    return 0;
  };
  let brk = 0;
  const host_brk = (addr) => {
    if (!brk) brk = memory.buffer.byteLength;
    return brk;
  };
  const statxToStat = (sx, st) => {
    const d = dv();
    const mkdev = (maj, min) => B(maj & 4294963200) << 32n | B((maj & 4095) << 8) | B((min & 4294967040) << 12) | B(min & 255);
    zero(st, 144);
    d.setBigUint64(st + 0, mkdev(d.getUint32(sx + 136, true), d.getUint32(sx + 140, true)), true);
    d.setBigUint64(st + 8, d.getBigUint64(sx + 32, true), true);
    d.setBigUint64(st + 16, B(d.getUint32(sx + 16, true)), true);
    d.setUint32(st + 24, d.getUint16(sx + 28, true), true);
    d.setUint32(st + 28, d.getUint32(sx + 20, true), true);
    d.setUint32(st + 32, d.getUint32(sx + 24, true), true);
    d.setBigUint64(st + 40, mkdev(d.getUint32(sx + 128, true), d.getUint32(sx + 132, true)), true);
    d.setBigUint64(st + 48, d.getBigUint64(sx + 40, true), true);
    d.setBigUint64(st + 56, B(d.getUint32(sx + 4, true)), true);
    d.setBigUint64(st + 64, d.getBigUint64(sx + 48, true), true);
    for (const [from, to] of [[64, 72], [112, 88], [96, 104]]) {
      d.setBigInt64(st + to, d.getBigInt64(sx + from, true), true);
      d.setBigInt64(st + to + 8, B(d.getUint32(sx + from + 8, true)), true);
    }
  };
  const doStat = (dirfd, path, st, flags) => {
    const sx = scratch(256);
    const r = sc(291, dirfd, path, flags, 2047, sx);
    if (r === 0) statxToStat(sx, st);
    return r;
  };
  const sigaction = (sig, act, oact, size) => {
    const d = dv();
    let kact = 0, koact = 0;
    if (act) {
      kact = scratch(16);
      d.setUint32(kact, d.getUint32(act, true), true);
      d.setUint32(kact + 4, Number(d.getBigUint64(act + 4, true) & 0xfbffffffn), true);
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
  const lseek = (fd, off, whence) => {
    const o = big(off), res = scratch(8);
    const r = sc(62, fd, Number(o >> 32n & 0xffffffffn), Number(o & 0xffffffffn), res, whence);
    return r < 0 ? B(r) : dv().getBigInt64(res, true);
  };
  const gettimeofday = (tv, tz) => {
    if (!tv) return 0;
    const ts = scratch(16), r = sc(403, 0, ts);
    if (r !== 0) return r;
    const d = dv();
    d.setBigInt64(tv, d.getBigInt64(ts, true), true);
    d.setBigInt64(tv + 8, d.getBigInt64(ts + 8, true) / 1000n, true);
    return 0;
  };
  const poll = (fds, nfds, ms) => {
    let ts = 0;
    if (ms >= 0) {
      ts = scratch(16);
      const d = dv();
      d.setBigInt64(ts, B(Math.floor(ms / 1e3)), true);
      d.setBigInt64(ts + 8, B(ms % 1e3 * 1e6), true);
    }
    return sc(414, fds, nfds, ts, 0, 8);
  };
  const pselect6 = (nfds, rd, wr, ex, ts, sig6) => {
    let k6 = 0;
    if (sig6) {
      k6 = scratch(8);
      const d = dv();
      d.setUint32(k6, Number(d.getBigUint64(sig6, true) & 0xffffffffn), true);
      d.setUint32(k6 + 4, Number(d.getBigUint64(sig6 + 8, true) & 0xffffffffn), true);
    }
    return sc(413, nfds, rd, wr, ex, ts, k6);
  };
  const getrlimit = (res, rl) => sc(261, 0, res, 0, rl);
  const setrlimit = (res, rl) => sc(261, 0, res, rl, 0);
  const wait4 = (pid, status, options, rusage) => {
    const r = sc(260, pid, status, options, 0);
    if (rusage) zero(rusage, 144);
    return r;
  };
  const getrusage = (who, rusage) => {
    if (rusage) zero(rusage, 144);
    return 0;
  };
  let envfile = null;
  const writeEnvFile = () => {
    if (envfile !== null) return envfile;
    envfile = "";
    const { envp } = loadArgs();
    if (!envp.length) return envfile;
    const name = "/tmp/.wali-env-" + (sc(172) | 0);
    const p = scratch(256);
    putStr(p, name, 256);
    const fd = sc(56, AT_FDCWD, p, 577, 384);
    if (fd < 0) {
      dbg("wali: env file open failed " + fd);
      return envfile;
    }
    const bytes = new TextEncoder().encode(envp.join("\n") + "\n");
    const pages = Math.ceil(bytes.length / PAGE), buf = memory.grow(pages) * PAGE;
    u8().set(bytes, buf);
    let off = 0;
    while (off < bytes.length) {
      const r = sc(64, fd, buf + off, bytes.length - off);
      if (r <= 0) break;
      off += r;
    }
    sc(57, fd);
    envfile = name;
    return envfile;
  };
  const direct = {
    read: 63,
    write: 64,
    close: 57,
    ioctl: 29,
    readv: 65,
    writev: 66,
    sched_yield: 124,
    dup: 23,
    dup3: 24,
    getpid: 172,
    getppid: 173,
    getuid: 174,
    geteuid: 175,
    getgid: 176,
    getegid: 177,
    gettid: 178,
    exit: 93,
    exit_group: 94,
    kill: 129,
    tkill: 130,
    uname: 160,
    getcwd: 17,
    chdir: 49,
    fchdir: 50,
    openat: 56,
    mkdirat: 34,
    unlinkat: 35,
    symlinkat: 36,
    linkat: 37,
    renameat2: 276,
    readlinkat: 78,
    faccessat: 48,
    faccessat2: 439,
    fchmod: 52,
    fchmodat: 53,
    fchownat: 54,
    fchown: 55,
    fcntl: 25,
    flock: 32,
    fsync: 82,
    fdatasync: 83,
    getdents64: 61,
    pipe2: 59,
    set_tid_address: 96,
    set_robust_list: 99,
    rt_sigprocmask: 135,
    rt_sigpending: 136,
    rt_sigsuspend: 133,
    rt_sigreturn: 139,
    sigaltstack: 132,
    getrandom: 278,
    prlimit64: 261,
    sched_getaffinity: 123,
    umask: 166,
    setsid: 157,
    setpgid: 154,
    getpgid: 155,
    getsid: 156,
    getgroups: 158,
    setgroups: 159,
    setuid: 146,
    setgid: 144,
    setreuid: 145,
    setregid: 143,
    setresuid: 147,
    setresgid: 149,
    epoll_create1: 20,
    epoll_ctl: 21,
    epoll_pwait: 22,
    eventfd2: 19,
    socket: 198,
    socketpair: 199,
    bind: 200,
    listen: 201,
    accept4: 242,
    connect: 203,
    getsockname: 204,
    getpeername: 205,
    sendto: 206,
    recvfrom: 207,
    setsockopt: 208,
    getsockopt: 209,
    shutdown: 210,
    sendmsg: 211,
    recvmsg: 212,
    statfs: 43,
    fstatfs: 44,
    utimensat: 412,
    prctl: 167,
    pread64: 67,
    pwrite64: 68,
    ftruncate: 46,
    clock_getres: 406,
    clock_gettime: 403,
    clock_nanosleep: 407,
    futex: 422,
    ppoll: 414,
    execve: 221,
    statx: 291,
    chroot: 51,
    sysinfo: 179,
    setitimer: 103
  };
  const wali = {};
  for (const [name, nr] of Object.entries(direct)) wali["SYS_" + name] = (...a) => R(sc(nr, ...a));
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
      if (tv) {
        ts = scratch(16);
        const d = dv();
        d.setBigInt64(ts, d.getBigInt64(tv, true), true);
        d.setBigInt64(ts + 8, d.getBigInt64(tv + 8, true) * 1000n, true);
      }
      return R(sc(413, nfds, rd, wr, ex, ts, 0));
    },
    SYS_nanosleep: (req, rem) => R(sc(407, 0, 0, req, rem)),
    SYS_pause: () => R(sc(414, 0, 0, 0, 0, 8)),
    // ppoll(NULL) until a signal
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
    SYS_munmap: (addr, len) => R(host_munmap(addr, len)),
    // Linear memory has no protection bits and no advice: std's stack guard
    // page (mprotect) and allocator hints (madvise) just succeed.
    SYS_mprotect: () => R(0),
    SYS_madvise: () => R(0),
    SYS_msync: (addr, len) => R(host_msync(addr, len)),
    SYS_mremap: (old, oldLen, newLen, flags) => {
      const b = grow(i32(newLen) >>> 0);
      if (b < 0) return R(b);
      u8().copyWithin(b, i32(old), i32(old) + Math.min(i32(oldLen) >>> 0, i32(newLen) >>> 0));
      release(i32(old), i32(oldLen) >>> 0);
      return R(b);
    },
    SYS_brk: (addr) => R(host_brk(addr)),
    // fork(): the worker intercepts clone(SIGCHLD, 0) from asyncified modules
    // and implements a real fork (unwind, duplicate the process, rewind the
    // child) — the same path C programs built with wasm-stubs.c use. Rust's
    // Command::spawn on Linux is fork + execve, so this is what rustc uses to
    // run the linker.
    SYS_fork: () => R(sc(220, 17, 0, 0, 0, 0, 0)),
    SYS_vfork: () => R(sc(220, 17, 0, 0, 0, 0, 0)),
    SYS_clone: () => R(ENOSYS),
    SYS_clone3: () => R(ENOSYS),
    SYS_fadvise: () => R(0),
    // lifecycle + argv/env (see wali-musl/arch/wasm32/init_env.h)
    __init: () => {
      loadArgs();
      return 0;
    },
    __deinit: () => 0,
    __proc_exit: (code) => {
      sc(94, i32(code));
    },
    // setjmp/longjmp are host imports in WALI (iwasm implements them natively).
    // lld/LLVM only reach them from CrashRecoveryContext (sigsetjmp around the
    // link, siglongjmp from a crash handler): setjmp → 0 ("direct return"),
    // longjmp → abort, since no crash handler ever runs here.
    setjmp: () => 0,
    longjmp: (env, val) => {
      dbg("wali: longjmp(" + i32(val) + ") unsupported");
      sc(94, 134);
    },
    __cl_get_argc: () => loadArgs().argv.length,
    __cl_get_argv_len: (i) => new TextEncoder().encode(loadArgs().argv[i32(i)] || "").length,
    __cl_copy_argv: (buf, i) => {
      const s = loadArgs().argv[i32(i)] || "";
      const b = new TextEncoder().encode(s);
      u8().set(b, i32(buf));
      u8()[i32(buf) + b.length] = 0;
      return b.length;
    },
    __get_init_envfile: (buf, size) => {
      const f = writeEnvFile();
      if (!f) return 0;
      return putStr(i32(buf), f, i32(size));
    },
    // threads (wali-musl pthread_impl.h / pthread_create.c): the host must
    // run `start_fn(tid, args)` on a new thread sharing this memory and
    // return the tid. That is this kernel's clone(fn, arg, flags, ...) —
    // the child worker's switch_entry sees a WALI module and calls the
    // table entry with (tid, arg) (C clone entries take just (arg)).
    // wali-musl allocated the stack + TLS itself (start_fn installs them),
    // clears its own tid on exit and joins on detach_state, so no
    // SETTLS/SETTID/CLEARTID flags are needed.
    __wasm_thread_spawn: (fn, args2) => {
      const CLONE_THREAD_FLAGS = 331520;
      const r = sc(220, i32(fn), i32(args2), CLONE_THREAD_FLAGS, 0, 0, 0);
      if (debugAll) dbg("wali: __wasm_thread_spawn fn=" + i32(fn) + " -> " + r);
      return r;
    },
    // __clone(fn, stack, flags, arg, ...): wali-musl's posix_spawn does
    // __clone(child, stack, CLONE_VM|CLONE_VFORK|SIGCHLD, &args) — the same
    // NOMMU vfork pattern busybox uses, which the worker's clone intercept
    // already implements (asyncify unwind; the child runs fn(arg) natively
    // and execs). Maps to this kernel's clone(fn, arg, flags, ...).
    __clone: (fn, stack, flags, arg) => {
      const r = sc(220, i32(fn), i32(arg), i32(flags), 0, 0, 0);
      if (debugAll) dbg("wali: __clone fn=" + i32(fn) + " flags=0x" + (i32(flags) >>> 0).toString(16) + " -> " + r);
      return r;
    },
    __set_thread_area: () => 0,
    __unmapself: () => {
    }
  });
  for (const k of Object.keys(wali)) {
    if (!k.startsWith("SYS_")) continue;
    const f = wali[k];
    wali[k] = (...a) => {
      reset();
      const r = f(...a);
      if (debugAll || globalThis.__walidebug) {
        let extra = "";
        try {
          if (k === "SYS_ioctl" && n(a[1]) === 21523) {
            const d = dv(), p = n(a[2]);
            extra = " winsize=" + [0, 2, 4, 6].map((o) => d.getUint16(p + o, true)).join("x");
          }
          if (k === "SYS_write" && n(a[2]) <= 200) extra = " " + JSON.stringify(new TextDecoder().decode(u8().slice(n(a[1]), n(a[1]) + n(a[2]))));
          if (k === "SYS_epoll_ctl") {
            const d = dv(), p = n(a[3]);
            extra = " events=0x" + d.getUint32(p, true).toString(16) + " data=" + d.getBigUint64(p + 8, true);
          }
          const pathArg = { SYS_open: 0, SYS_openat: 1, SYS_access: 0, SYS_faccessat: 1, SYS_stat: 0, SYS_lstat: 0, SYS_newfstatat: 1, SYS_readlink: 0, SYS_readlinkat: 1, SYS_execve: 0, SYS_statx: 1, SYS_mkdir: 0, SYS_unlink: 0, SYS_chdir: 0 }[k];
          if (pathArg !== void 0) {
            const m = u8(), p = n(a[pathArg]);
            let e = p;
            while (m[e] && e - p < 200) e++;
            extra += " path=" + JSON.stringify(new TextDecoder().decode(m.slice(p, e)));
          }
          if (k === "SYS_read" && r > 0 && r <= 80) extra += " " + JSON.stringify(new TextDecoder().decode(u8().slice(n(a[1]), n(a[1]) + r)));
        } catch (_) {
        }
        dbg(k + "(" + a.map(n).join(",") + ") = " + r + extra);
      }
      return r;
    };
  }
  const envExtra = {
    _Unwind_Backtrace: () => 0,
    _Unwind_GetIP: () => 0,
    _Unwind_GetIPInfo: () => 0,
    _Unwind_GetCFA: () => 0,
    _Unwind_GetRegionStart: () => 0,
    _Unwind_FindEnclosingFunction: () => 0,
    _Unwind_GetDataRelBase: () => 0,
    _Unwind_GetTextRelBase: () => 0,
    _Unwind_GetLanguageSpecificData: () => 0,
    _Unwind_SetGR: () => {
    },
    _Unwind_SetIP: () => {
    },
    _Unwind_GetGR: () => 0,
    _Unwind_RaiseException: () => 9,
    _Unwind_Resume: () => {
    },
    _Unwind_DeleteException: () => {
    }
  };
  const missing = /* @__PURE__ */ new Set();
  const proxied = new Proxy(wali, {
    get(t, k) {
      if (k in t || typeof k !== "string" || !k.startsWith("SYS_")) return t[k];
      return (...a) => {
        if (!missing.has(k)) {
          missing.add(k);
          dbg("wali: unbridged " + k + " -> ENOSYS");
        }
        return B(ENOSYS);
      };
    }
  });
  return { wali: proxied, envExtra };
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
    ({ module: module2, name, kind }) => supported_user_module_imports.has(`${module2}\0${name}\0${kind}`) || // LinuxOnTab: WALI (Rust) modules import wali.SYS_* plus env.* hooks that
    // the wali bridge supplies at instantiation (a missing one fails loudly).
    kind === "function" && (module2 === "wali" || module2 === "env")
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
var USER_MEMORY_DEFAULT_MAX_PAGES = 4096;
var USER_MEMORY_DEFAULT_MIN_PAGES = 2048;
var NR_WASM_FORK = 9999;
var NR_WASM_VFORK = 1e4;
var WASM_FORK_MAGIC = 1179603531;
var NR_CLONE = 220;
var SIGCHLD = 17;
var CLONE_VFORK = 16384;
var FORK_SCRATCH_BYTES = 4 * 1024 * 1024;
function user_imports({
  kernel_memory,
  get_kernel_instance,
  parent_user: parent,
  fork_rewind = null,
  set_pending_child_fork
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
  let pendingFork = null;
  const spGlobal = () => {
    const g = instance?.exports?.__stack_pointer;
    return g instanceof WebAssembly.Global ? g : null;
  };
  let forkRewind = fork_rewind;
  let waliThreadEntry = fork_rewind?.entry ?? null;
  const is_wali = (m) => WebAssembly.Module.imports(m).some((i) => i.module === "wali");
  function waliThreadRun() {
    assert(instance && waliThreadEntry);
    const f = instance.exports.__indirect_function_table.get(waliThreadEntry.fn);
    assert(typeof f === "function", "invalid WALI thread entry");
    const tid = get_kernel_instance().exports.syscall(178, 0, 0, 0, 0, 0, 0);
    f(tid, waliThreadEntry.arg);
    if (asyncify()?.asyncify_get_state?.() === 1) throw new Error("wali thread: asyncify unwind");
    console.warn("WALI thread entry returned");
  }
  let forkScratch = null;
  const asyncify = () => instance ? instance.exports : null;
  const sp = () => {
    const g = instance?.exports?.__stack_pointer;
    return g instanceof WebAssembly.Global ? "0x" + (g.value >>> 0).toString(16) : "n/a";
  };
  function acquireForkScratch(memory) {
    if (forkScratch && forkScratch.memory === memory) return forkScratch;
    const base = memory.grow(FORK_SCRATCH_BYTES >> 16) * 65536;
    forkScratch = { memory, retPtr: base, bufPtr: base + 16, size: FORK_SCRATCH_BYTES - 16 };
    return forkScratch;
  }
  function fork_sentinel(nr, arg0, arg1, arg2) {
    const a = asyncify();
    assert(context);
    if (!a?.asyncify_get_state || !a.asyncify_start_unwind || !a.asyncify_stop_rewind) return -38;
    const state = a.asyncify_get_state();
    if (state === 0) {
      let bufPtr, retPtr;
      if (arg2 === WASM_FORK_MAGIC) {
        bufPtr = arg0 >>> 0;
        retPtr = arg1 >>> 0;
      } else {
        const sc = acquireForkScratch(context.memory);
        bufPtr = sc.bufPtr;
        retPtr = arg1 >>> 0;
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
      const rv = new Int32Array(context.memory.buffer)[arg1 >>> 0 >> 2];
      console.debug("[fork] " + (self.name || "?") + " rewound, fork() returns " + rv + " sp=" + sp());
      return rv;
    }
    return -38;
  }
  function create_instance(context2) {
    const kernel_instance = get_kernel_instance();
    const linux_syscall = (nr, arg0, arg1, arg2, arg3, arg4, arg5) => {
      if (nr === NR_WASM_FORK || nr === NR_WASM_VFORK) return fork_sentinel(nr, arg0, arg1, arg2);
      const original_instance = instance;
      const ret = kernel_instance.exports.syscall(nr, arg0, arg1, arg2, arg3, arg4, arg5);
      if (instance !== original_instance) {
        call_entry = call_start;
        throw HALT_USER;
      }
      return ret;
    };
    let wali_env = {};
    let wali_imports;
    if (is_wali(context2.module)) {
      const w = makeWaliImports({
        memory: context2.memory,
        kernel: { exports: {
          get_args_length: () => kernel_instance.exports.get_args_length(),
          get_args: (buf) => kernel_instance.exports.syscall(NR_WASM_GET_ARGS, buf >>> 0, 262144, 0, 0, 0, 0)
        } },
        syscall: (...a) => linux_syscall(a[0], a[1], a[2], a[3], a[4], a[5], a[6]),
        log: (m) => console.debug("[wali] " + m)
      });
      wali_env = w.envExtra ?? {};
      wali_imports = w.wali;
    }
    return new WebAssembly.Instance(context2.module, {
      env: { memory: context2.memory, ...wali_env },
      ...wali_imports ? { wali: wali_imports } : {},
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
        let declared_max = 0;
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
          declared_max = Number(memory_import.type.maximum);
          maximum = Math.min(declared_max, rlimit_pages);
          const wali_module = WebAssembly.Module.imports(module).some((i) => i.module === "wali");
          if (!wali_module) maximum = Math.min(maximum, USER_MEMORY_DEFAULT_MAX_PAGES);
          if (!wali_module) minimum = Math.max(minimum, Math.min(USER_MEMORY_DEFAULT_MIN_PAGES, maximum));
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
        console.debug("[user-memory] " + (self.name || "?") + " declared min=" + minimum + " max=" + declared_max + " rlimit=" + rlimit_pages + " requested max=" + maximum + " granted max=" + allocated.maximum_pages + " pages");
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
            const a = asyncify();
            if (pendingFork && a?.asyncify_get_state?.() === 1) {
              const fork = pendingFork;
              pendingFork = null;
              assert(context);
              a.asyncify_stop_unwind();
              {
                const h = new Int32Array(context.memory.buffer);
                const cursor = h[fork.bufPtr >> 2], end = h[(fork.bufPtr >> 2) + 1];
                console.debug("[fork] " + (self.name || "?") + " unwound: asyncify used=" + (cursor - (fork.bufPtr + 8)) + " capacity=" + (end - (fork.bufPtr + 8)) + " bytes, mem pages=" + (context.memory.buffer.byteLength >> 16));
              }
              set_pending_child_fork({ bufPtr: fork.bufPtr, retPtr: fork.retPtr, sp: fork.sp, entry: waliThreadEntry });
              let pid;
              try {
                pid = get_kernel_instance().exports.syscall(
                  NR_CLONE,
                  0,
                  0,
                  SIGCHLD | (fork.vfork ? CLONE_VFORK : 0),
                  0,
                  0,
                  0
                );
              } finally {
                set_pending_child_fork(null);
              }
              new Int32Array(context.memory.buffer)[fork.retPtr >> 2] = pid;
              console.debug("[fork] " + (self.name || "?") + " clone -> " + pid + ", rewinding parent sp=" + sp());
              a.asyncify_start_rewind(fork.bufPtr);
              call_entry = waliThreadEntry ? waliThreadRun : call_start;
              continue;
            }
            console.error(
              "error running user module in " + (self.name || "?") + ":",
              error,
              "\n" + String(error?.stack ?? "").slice(0, 3e3),
              "| asyncify_state=" + (asyncify()?.asyncify_get_state?.() ?? "n/a") + " pendingFork=" + !!pendingFork + " forkRewind=" + !!forkRewind
            );
            return;
          }
        }
      },
      switch_entry(fn, arg) {
        assert(parent);
        if (forkRewind) {
          const rw = forkRewind;
          forkRewind = null;
          call_entry = () => {
            call_entry = call_start;
            assert(instance && context);
            const a = asyncify();
            assert(a?.asyncify_start_rewind, "fork child without asyncify exports");
            new Int32Array(context.memory.buffer)[rw.retPtr >> 2] = 0;
            const g = spGlobal();
            if (g && rw.sp) g.value = rw.sp;
            console.debug("[fork] " + (self.name || "?") + " child rewinding buf=0x" + rw.bufPtr.toString(16) + " sp=" + sp() + (g ? " (restored)" : " (no __stack_pointer export!)"));
            a.asyncify_start_rewind(rw.bufPtr);
            if (waliThreadEntry) {
              call_entry = waliThreadRun;
              waliThreadRun();
              return;
            }
            call_start();
          };
          return;
        }
        if (context && is_wali(context.module)) {
          call_entry = () => {
            assert(instance);
            const f = instance.exports.__indirect_function_table.get(fn >>> 0);
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
  user_copy_status,
  fork
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
      console.debug("[user-memory] " + (self.name || "?") + " fork copy pages=" + source.byteLength / 65536 + " parent max=" + user_context.maximum_pages + " granted max=" + copied.maximum_pages);
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
  let pending_child_fork = null;
  const user = user_imports({
    kernel_memory: memory,
    get_kernel_instance: () => instance,
    parent_user: user_context,
    fork_rewind: fork ?? null,
    set_pending_child_fork: (f) => {
      pending_child_fork = f;
    }
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
          user_copy_status: user_copy_status2,
          fork: pending_child_fork
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
