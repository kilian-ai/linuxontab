export interface DeviceTreeNode {
    [key: string]: DeviceTreeNode | DeviceTreeProperty;
}
type DeviceTreeProperty = string | number | bigint | readonly number[] | Uint8Array | Uint16Array | Uint32Array | BigUint64Array | ArrayBuffer | undefined;
export declare function generate_devicetree(tree: DeviceTreeNode, { memory_reservations, boot_cpu_id, }?: {
    memory_reservations?: Array<{
        address: number;
        size: number;
    }>;
    boot_cpu_id?: number;
}): Uint8Array;
export {};
