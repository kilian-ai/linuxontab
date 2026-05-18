import { type DeviceTreeNode } from "./devicetree.ts";
import { EventEmitter } from "./util.ts";
import { VirtioDevice } from "./virtio.ts";
export { BlockDevice, type BlockDeviceStorage, ConsoleDevice, EntropyDevice, } from "./virtio.ts";
export declare class Machine extends EventEmitter<{
    error: ErrorEvent;
}> {
    #private;
    memory: Uint8Array;
    devicetree: DeviceTreeNode;
    get bootConsole(): ReadableStream<Uint8Array>;
    constructor(options: {
        cmdline?: string;
        memoryMib?: number;
        cpus?: number;
        devices: VirtioDevice[];
        initcpio?: ArrayBufferView;
    });
    boot(): Promise<void>;
}
