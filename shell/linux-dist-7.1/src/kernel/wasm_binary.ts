// SPDX-License-Identifier: MIT

// The WebAssembly JavaScript API reports that an import is a memory, but not
// the memory's limits. Those live in the module's import section, so read the
// small part of the binary format that is needed to recover them.

export interface WasmMemoryType {
  address: "i32" | "i64";
  minimum: bigint;
  maximum?: bigint;
  shared: boolean;
}

export interface WasmMemoryImport {
  module: string;
  name: string;
  type: WasmMemoryType;
}

export interface WasmMemories {
  imports: WasmMemoryImport[];
  definitions: WasmMemoryType[];
}

export class WasmParseError extends Error {
  constructor(message: string, offset: number) {
    super(`${message} at byte ${offset}`);
    this.name = "WasmParseError";
  }
}

const text_decoder = new TextDecoder("utf-8", { fatal: true });

class Cursor {
  readonly #bytes: Uint8Array;
  readonly #end: number;
  #offset: number;

  constructor(bytes: Uint8Array, offset = 0, end = bytes.length) {
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
    return this.#bytes[this.#offset++]!;
  }

  u32() {
    return Number(this.#unsigned(32));
  }

  u64() {
    return this.#unsigned(64);
  }

  #unsigned(bits: number) {
    let value = 0n;
    const bytes = Math.ceil(bits / 7);

    for (let i = 0; i < bytes; i++) {
      const byte = this.byte();
      const payload = byte & 0x7f;
      const remaining = bits - i * 7;
      if (remaining < 7 && payload >= 1 << remaining) {
        this.fail(`u${bits} LEB128 overflows`);
      }
      value |= BigInt(payload) << BigInt(i * 7);
      if (!(byte & 0x80)) return value;
    }

    this.fail(`u${bits} LEB128 is too long`);
  }

  // Heap types can be type indices encoded as s33. Their value is immaterial
  // here, but consuming the complete, bounded encoding lets us skip table and
  // global imports without parsing unrelated type sections.
  signed33(first: number) {
    let byte = first;
    for (let i = 0; i < 5; i++) {
      const payload = byte & 0x7f;
      const remaining = 33 - i * 7;
      if (!(byte & 0x80)) {
        if (remaining < 7) {
          const used = (1 << remaining) - 1;
          const unused = 0x7f ^ used;
          const sign = 1 << (remaining - 1);
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
    return new Cursor(this.#bytes, start, end);
  }

  text(): string {
    try {
      return text_decoder.decode(this.view());
    } catch {
      return this.fail("name is not valid UTF-8");
    }
  }

  view() {
    return this.#bytes.subarray(this.#offset, this.#end);
  }

  expect_done(what: string) {
    if (!this.done) this.fail(`trailing bytes in ${what}`);
  }

  fail(message: string): never {
    throw new WasmParseError(message, this.#offset);
  }
}

function read_memory_type(bytes: Cursor): WasmMemoryType {
  const flags = bytes.byte();
  if (flags & ~0x07) bytes.fail("unknown memory limits flags");

  const has_maximum = !!(flags & 0x01);
  const shared = !!(flags & 0x02);
  const address = flags & 0x04 ? "i64" : "i32";
  const read_limit = address === "i64" ? () => bytes.u64() : () => BigInt(bytes.u32());
  const minimum = read_limit();
  const maximum = has_maximum ? read_limit() : undefined;

  return { address, minimum, maximum, shared };
}

function skip_reference_type(bytes: Cursor) {
  const type = bytes.byte();
  if (type === 0x63 || type === 0x64) {
    bytes.signed33(bytes.byte());
  } else if (type < 0x69 || type > 0x74) {
    bytes.fail("invalid reference type");
  }
}

function skip_value_type(bytes: Cursor) {
  const type = bytes.byte();
  if (type >= 0x7b && type <= 0x7f) return;
  if (type === 0x63 || type === 0x64) {
    bytes.signed33(bytes.byte());
  } else if (type < 0x69 || type > 0x74) {
    bytes.fail("invalid value type");
  }
}

function skip_limits(bytes: Cursor) {
  const flags = bytes.byte();
  if (flags & ~0x05) bytes.fail("unknown limits flags");
  const read_limit = flags & 0x04 ? () => bytes.u64() : () => bytes.u32();
  read_limit();
  if (flags & 0x01) read_limit();
}

function read_imports(bytes: Cursor, imports: WasmMemoryImport[]) {
  const count = bytes.u32();
  for (let i = 0; i < count; i++) {
    // Keep names as spans until we know this is a memory import. Typical Linux
    // modules have many function imports whose names this reader need not own.
    const module = bytes.span();
    const name = bytes.span();
    switch (bytes.byte()) {
      case 0x00: // function
        bytes.u32();
        break;
      case 0x01: // table
        skip_reference_type(bytes);
        skip_limits(bytes);
        break;
      case 0x02: // memory
        imports.push({
          module: module.text(),
          name: name.text(),
          type: read_memory_type(bytes),
        });
        break;
      case 0x03: // global
        skip_value_type(bytes);
        if (bytes.byte() > 1) bytes.fail("invalid global mutability");
        break;
      case 0x04: // tag
        if (bytes.byte() !== 0) bytes.fail("unknown tag attribute");
        bytes.u32();
        break;
      default:
        bytes.fail("unknown import type");
    }
  }
  bytes.expect_done("import section");
}

function read_definitions(bytes: Cursor, definitions: WasmMemoryType[]) {
  const count = bytes.u32();
  for (let i = 0; i < count; i++) definitions.push(read_memory_type(bytes));
  bytes.expect_done("memory section");
}

export function read_wasm_memories(module: Uint8Array): WasmMemories {
  const bytes = new Cursor(module);
  const header = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  for (const expected of header) {
    if (bytes.byte() !== expected) bytes.fail("invalid WebAssembly header");
  }

  const memories: WasmMemories = { imports: [], definitions: [] };
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

// LinuxOnTab: pre-7.1 userland compat. Binaries built against the old
// LinuxOnTab musl sysroot export neither __stack_pointer nor a siginfo
// trampoline, yet the host must carve a siginfo_t out of the interrupted
// thread's stack to call their SA_SIGINFO handlers (see worker.ts). wasm-ld
// always defines __stack_pointer as the first global of a non-PIC module, so
// re-export that global under `name`. Returns null (leave the module alone)
// unless the layout is exactly that: no imported globals, a first global of
// type `mut i32` initialised by a 16-byte aligned i32.const, and an existing
// export section that does not already use `name`.

function skip_imports(bytes: Cursor): number {
  let globals = 0;
  const count = bytes.u32();
  for (let i = 0; i < count; i++) {
    bytes.span();
    bytes.span();
    switch (bytes.byte()) {
      case 0x00:
        bytes.u32();
        break;
      case 0x01:
        skip_reference_type(bytes);
        skip_limits(bytes);
        break;
      case 0x02:
        read_memory_type(bytes);
        break;
      case 0x03:
        globals++;
        skip_value_type(bytes);
        bytes.byte();
        break;
      case 0x04:
        bytes.byte();
        bytes.u32();
        break;
      default:
        bytes.fail("unknown import type");
    }
  }
  return globals;
}

function leb_u32(value: number): number[] {
  const out: number[] = [];
  do {
    let byte = value & 0x7f;
    value >>>= 7;
    if (value) byte |= 0x80;
    out.push(byte);
  } while (value);
  return out;
}

export function export_stack_pointer(module: Uint8Array, name: string): Uint8Array | null {
  const bytes = new Cursor(module);
  for (let i = 0; i < 8; i++) bytes.byte();

  let imported_globals = 0;
  let stack_pointer_ok = false;
  let exports: { start: number; end: number; body: Cursor } | null = null;
  while (!bytes.done) {
    const start = bytes.offset;
    const id = bytes.byte();
    const section = bytes.span();
    if (id === 2) {
      imported_globals = skip_imports(section);
    } else if (id === 6) {
      if (section.u32() === 0) return null;
      // globaltype (i32, var) then a constant expression `i32.const n; end`.
      if (section.byte() !== 0x7f || section.byte() !== 0x01 || section.byte() !== 0x41) return null;
      let value = 0;
      let shift = 0;
      let byte: number;
      do {
        byte = section.byte();
        value |= (byte & 0x7f) << shift;
        shift += 7;
      } while (byte & 0x80 && shift < 35);
      if (section.byte() !== 0x0b) return null;
      stack_pointer_ok = value > 0 && (value & 15) === 0;
    } else if (id === 7) {
      exports = { start, end: bytes.offset, body: section };
    }
  }
  if (imported_globals !== 0 || !stack_pointer_ok || !exports) return null;

  const body = exports.body;
  const count = body.u32();
  const entries_start = body.offset;
  for (let i = 0; i < count; i++) {
    if (body.span().text() === name) return null;
    body.byte();
    body.u32();
  }
  const encoder = new TextEncoder();
  const encoded_name = encoder.encode(name);
  const old_entries = module.subarray(entries_start, body.offset);
  const new_body = [
    ...leb_u32(count + 1),
    ...old_entries,
    ...leb_u32(encoded_name.length),
    ...encoded_name,
    0x03, // global
    0x00, // index 0: __stack_pointer
  ];
  const header = [0x07, ...leb_u32(new_body.length)];
  const out = new Uint8Array(module.length - (exports.end - exports.start) + header.length + new_body.length);
  out.set(module.subarray(0, exports.start), 0);
  out.set(header, exports.start);
  out.set(new_body, exports.start + header.length);
  out.set(module.subarray(exports.end), exports.start + header.length + new_body.length);
  return out;
}
