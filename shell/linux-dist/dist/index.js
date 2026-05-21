import { generate_devicetree } from "./devicetree.js";
import { assert, EventEmitter, unreachable } from "./util.js";
import { virtio_imports, VirtioDevice } from "./virtio.js";
import { kernel_imports } from "./wasm.js";
export { BlockDevice, ConsoleDevice, EntropyDevice, NetworkDevice, } from "./virtio.js";
const resources = (async () => {
    const vmlinux_response = fetch(new URL("../vmlinux.wasm", import.meta.url));
    let vmlinux;
    if ("compileStreaming" in WebAssembly) {
        vmlinux = await WebAssembly.compileStreaming(vmlinux_response);
    }
    else {
        const buffer = await (await vmlinux_response).arrayBuffer();
        vmlinux = await WebAssembly.compile(buffer);
    }
    const custom_section = (name) => {
        const sections = WebAssembly.Module.customSections(vmlinux, name);
        const section = sections[0];
        assert(section && sections.length === 1, `Missing custom section: ${name}`);
        return section;
    };
    const sections = JSON.parse(new TextDecoder().decode(custom_section(".linux.sections")));
    const initramfs = new Uint8Array(custom_section(".linux.initramfs"));
    return {
        vmlinux,
        sections,
        initramfs,
    };
})();
const INITCPIO_ADDR = 0x200000;
export class Machine extends EventEmitter {
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
        const PAGE_SIZE = 0x10000;
        const BYTES_PER_MIB = 0x100000;
        const bytes = (options.memoryMib ?? 128) * BYTES_PER_MIB;
        const pages = bytes / PAGE_SIZE;
        this.#memory = new WebAssembly.Memory({
            initial: pages,
            maximum: pages,
            shared: true,
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
            },
            aliases: {},
            memory: {
                device_type: "memory",
                reg: [0, bytes],
            },
            "reserved-memory": {
                "#address-cells": 1,
                "#size-cells": 1,
                ranges: undefined,
            },
        };
        if (this.#initcpio) {
            const chosen = this.devicetree.chosen;
            chosen["linux,initrd-start"] = INITCPIO_ADDR;
            chosen["linux,initrd-end"] = INITCPIO_ADDR + this.#initcpio.byteLength;
            this.memory.set(new Uint8Array(this.#initcpio.buffer, this.#initcpio.byteOffset, this.#initcpio.byteLength), INITCPIO_ADDR);
        }
        for (const [i, dev] of this.#devices.entries()) {
            this.devicetree[`virtio${i}`] = {
                compatible: `virtio,wasm`,
                "host-id": i,
                "virtio-device-id": dev.ID,
                features: dev.features,
                config: dev.config_bytes,
            };
        }
    }
    async boot() {
        const memory_reservations = [];
        if (this.#initcpio) {
            memory_reservations.push({
                address: INITCPIO_ADDR,
                size: this.#initcpio.byteLength,
            });
        }
        const { sections, vmlinux, initramfs } = await resources;
        this.devicetree.chosen.sections = sections;
        const devicetree = generate_devicetree(this.devicetree, {
            memory_reservations,
        });
        const boot_console_write = (message) => {
            this.#boot_console_writer.write(new Uint8Array(message)).catch(() => {
                // Ignore errors if the console is closed
            });
        };
        const boot_console_close = () => {
            this.#boot_console_writer.close();
        };
        const spawn_worker = (fn, arg, name, user_module, user_memory, fork_bufPtr = null, fork_retPtr = null) => {
            const mem_shared = user_memory ? (user_memory.buffer instanceof SharedArrayBuffer) : null;
            console.log('[SPAWN_WORKER] name=' + name + ' fn=' + fn + ' has_user_mem=' + (user_memory != null) + ' shared=' + mem_shared);
            const worker = new Worker(new URL("./worker.js", import.meta.url), {
                type: "module",
                name,
            });
            this.#workers.push(worker);
            worker.onmessage = (event) => {
                switch (event.data.type) {
                    case "spawn_worker":
                        spawn_worker(event.data.fn, event.data.arg, event.data.name, event.data.user_module, event.data.user_memory, event.data.fork_bufPtr ?? null, event.data.fork_retPtr ?? null);
                        break;
                    case "boot_console_write":
                        boot_console_write(event.data.message);
                        break;
                    case "boot_console_close":
                        boot_console_close();
                        break;
                    case "run_on_main":
                        console.log('[RUN_ON_MAIN] fn=' + event.data.fn + ' arg=' + event.data.arg);
                        instance.exports.__indirect_function_table
                            .get(event.data.fn)(event.data.arg);
                        break;
                    case "log":
                        console.log(event.data.msg);
                        break;
                    default:
                        unreachable(event.data);
                }
            };
            worker.onerror = (event) => {
                this.emit("error", event);
            };
            try {
                worker.postMessage({
                    fn,
                    arg,
                    vmlinux,
                    memory: this.#memory,
                    parent_user_module: user_module,
                    parent_user_memory: user_memory,
                    fork_bufPtr,
                    fork_retPtr,
                });
            } catch (e) {
                console.error('[SPAWN_WORKER] postMessage failed: ' + e + ' user_memory=' + user_memory);
            }
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
                    assert(size >= initramfs.byteLength, "Initramfs truncated");
                    this.memory.set(initramfs, buf);
                    return initramfs.byteLength;
                },
            },
            kernel: kernel_imports({
                is_worker: false,
                memory: this.#memory,
                spawn_worker,
                boot_console_write,
                boot_console_close,
                run_on_main: unavailable,
                get_user_module: unavailable,
                get_user_memory: unavailable,
            }),
            user: {
                compile: unavailable,
                instantiate: unavailable,
                call: unavailable,
                switch_entry: unavailable,
                call_signal_handler: unavailable,
                read: unavailable,
                write: unavailable,
                write_zeroes: unavailable,
            },
            virtio: virtio_imports({
                memory: this.#memory,
                devices: this.#devices,
                trigger_irq_for_cpu(cpu, irq) {
                    instance.exports.trigger_irq_for_cpu(cpu, irq);
                },
            }),
        };
        const instance = (await WebAssembly.instantiate(vmlinux, imports));
        instance.exports.boot();
    }
}
