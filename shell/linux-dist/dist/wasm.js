export const HALT_KERNEL = Symbol("halt kernel");
export function kernel_imports({ is_worker, memory, spawn_worker, boot_console_write, boot_console_close, run_on_main, get_user_module, get_user_memory, }) {
    const mem = new Uint8Array(memory.buffer);
    return {
        breakpoint: () => {
            // deno-lint-ignore no-debugger
            debugger;
        },
        halt_worker: () => {
            if (!is_worker)
                throw new Error("Halt called in main thread");
            self.close();
            throw HALT_KERNEL;
        },
        boot_console_write: (msg, len) => {
            boot_console_write(memory.buffer.slice(msg, msg + len));
        },
        boot_console_close,
        return_address: (_level) => {
            return 0;
        },
        get_now_nsec: () => {
            /*
              The more straightforward way to do this is
              `BigInt(Math.round(performance.now() * 1_000_000))`.
              Below is semantically identical but has less floating point
              inaccuracy.
              `performance.now()` has 5μs precision in the browser.
              In server runtimes it has full nanosecond precision, but this code
              rounds to the same 5μs precision.
            */
            return BigInt(Math.round((performance.now() + performance.timeOrigin) * 200)) * 5000n;
        },
        get_stacktrace: (buf, size) => {
            // 5 lines: strip Error, strip 4 common lines of stack
            const trace = new TextEncoder().encode(new Error().stack?.split("\n").slice(5).join("\n"));
            if (trace.byteLength > size) {
                /// 46 = "."
                trace[size - 1] = 46;
                trace[size - 2] = 46;
                trace[size - 3] = 46;
            }
            mem.set(trace.slice(0, size), buf);
        },
        spawn_worker: (fn, arg, comm, comm_len, share_user_memory) => {
            const name = new TextDecoder().decode(mem.slice(comm, comm + comm_len));
            spawn_worker(fn, arg, name, share_user_memory ? get_user_module() : null, share_user_memory ? get_user_memory() : null);
        },
        run_on_main,
    };
}
