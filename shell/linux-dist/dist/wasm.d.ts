export interface Instance extends WebAssembly.Instance {
    exports: {
        __indirect_function_table: WebAssembly.Table;
        boot(): void;
        trigger_irq_for_cpu(cpu: number, irq: number): void;
        syscall(nr: number, arg0: number, arg1: number, arg2: number, arg3: number, arg4: number, arg5: number): number;
        get_thread_area(): number;
        get_args_length(): number;
        get_args(buf: number): number;
    };
}
export interface Imports {
    env: {
        memory: WebAssembly.Memory;
    };
    boot: {
        get_devicetree(buf: number, size: number): void;
        get_initramfs(buf: number, size: number): number;
    };
    kernel: {
        breakpoint(): void;
        halt_worker(): void;
        boot_console_write(msg: number, len: number): void;
        boot_console_close(): void;
        return_address(_level: number): number;
        get_now_nsec(): bigint;
        get_stacktrace(buf: number, size: number): void;
        spawn_worker(fn: number, arg: number, comm: number, comm_len: number, share_user_memory: number): void;
        run_on_main(fn: number, arg: number): void;
    };
    user: {
        compile(buf: number, size: number): number;
        instantiate(fresh_memory: number): void;
        call(): void;
        switch_entry(fn: number, arg: number): void;
        call_signal_handler(fn: number, sig: number): void;
        read(to: number, from: number, n: number): number;
        write(to: number, from: number, n: number): number;
        write_zeroes(to: number, n: number): number;
    };
    virtio: {
        set_features(dev: number, features: bigint): void;
        setup(dev: number, irq: number, is_config_addr: number, is_vring_addr: number, config_addr: number, config_len: number): void;
        enable_vring(dev: number, vq: number, size: number, desc_addr: number): void;
        disable_vring(dev: number, vq: number): void;
        notify(dev: number, vq: number): void;
    };
}
export declare const HALT_KERNEL: unique symbol;
export declare function kernel_imports({ is_worker, memory, spawn_worker, boot_console_write, boot_console_close, run_on_main, get_user_module, get_user_memory, }: {
    is_worker: boolean;
    memory: WebAssembly.Memory;
    spawn_worker: (fn: number, arg: number, name: string, user_module: WebAssembly.Module | null, user_memory: WebAssembly.Memory | null) => void;
    boot_console_write: (message: ArrayBuffer) => void;
    boot_console_close: () => void;
    run_on_main: (fn: number, arg: number) => void;
    get_user_module: () => WebAssembly.Module | null;
    get_user_memory: () => WebAssembly.Memory | null;
}): Imports["kernel"];
