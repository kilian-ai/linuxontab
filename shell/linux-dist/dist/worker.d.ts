export interface InitMessage {
    fn: number;
    arg: number;
    vmlinux: WebAssembly.Module;
    memory: WebAssembly.Memory;
    parent_user_module: WebAssembly.Module | null;
    parent_user_memory: WebAssembly.Memory | null;
}
export type WorkerMessage = {
    type: "spawn_worker";
    fn: number;
    arg: number;
    name: string;
    user_module: WebAssembly.Module | null;
    user_memory: WebAssembly.Memory | null;
} | {
    type: "boot_console_write";
    message: ArrayBuffer;
} | {
    type: "boot_console_close";
} | {
    type: "run_on_main";
    fn: number;
    arg: number;
};
