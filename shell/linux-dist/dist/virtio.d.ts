import { type Type } from "./bytes.ts";
import type { Imports } from "./wasm.ts";
declare const VirtqDescriptor_base: (new (view: ArrayBufferView) => {
    addr: bigint;
    len: number;
    id: number;
    flags: number;
}) & Type<{
    addr: bigint;
    len: number;
    id: number;
    flags: number;
}>;
declare class VirtqDescriptor extends VirtqDescriptor_base {
}
declare class Chain {
    #private;
    id: number;
    skip: number;
    desc: VirtqDescriptor[];
    constructor(mem: DataView, queue: Virtqueue, id: number, skip: number, desc: VirtqDescriptor[]);
    release(written: number): void;
    [Symbol.iterator](): Generator<{
        array: Uint8Array;
        writable: boolean;
    }, void, unknown>;
}
declare class Virtqueue {
    #private;
    size: number;
    desc: VirtqDescriptor[];
    wrap: boolean;
    used_idx: number;
    avail_idx: number;
    constructor(mem: DataView, size: number, desc_addr: number);
    [Symbol.iterator](): Generator<Chain, void, unknown>;
}
export declare abstract class VirtioDevice<Config extends object = object> {
    abstract readonly ID: number;
    abstract config_bytes: Uint8Array;
    abstract config: Config;
    features: bigint;
    trigger_interrupt: (kind: "config" | "vring") => void;
    vqs: Virtqueue[];
    enable(vq: number, queue: Virtqueue): void;
    disable(vq: number): void;
    abstract notify(vq: number): void;
    setup_complete(): void;
}
declare const EmptyStruct_base: (new (view: ArrayBufferView) => object) & Type<object>;
declare class EmptyStruct extends EmptyStruct_base {
}
declare const BlockDeviceConfig_base: (new (view: ArrayBufferView) => {
    capacity: bigint;
}) & Type<{
    capacity: bigint;
}>;
declare class BlockDeviceConfig extends BlockDeviceConfig_base {
}
type MaybePromise<T> = T | Promise<T>;
export interface BlockDeviceStorage {
    read(offset: number, length: number): MaybePromise<Uint8Array>;
    write?(offset: number, data: Uint8Array): MaybePromise<number>;
    flush?(): MaybePromise<void>;
    capacity: number;
}
export declare class BlockDevice extends VirtioDevice<BlockDeviceConfig> {
    #private;
    ID: number;
    config_bytes: Uint8Array;
    config: BlockDeviceConfig;
    constructor(storage: BlockDeviceStorage);
    notify(vq: number): Promise<void>;
}
export declare class ConsoleDevice extends VirtioDevice<EmptyStruct> {
    #private;
    ID: number;
    config_bytes: Uint8Array;
    config: EmptyStruct;
    constructor(input: ReadableStream<Uint8Array>, output: WritableStream<Uint8Array>);
    notify(vq: number): Promise<void>;
}
export declare class EntropyDevice extends VirtioDevice<EmptyStruct> {
    ID: number;
    config_bytes: Uint8Array;
    config: EmptyStruct;
    notify(vq: number): void;
}
export declare function virtio_imports({ memory, devices, trigger_irq_for_cpu, }: {
    memory: WebAssembly.Memory;
    devices: VirtioDevice[];
    trigger_irq_for_cpu: (cpu: number, irq: number) => void;
}): Imports["virtio"];
export {};
