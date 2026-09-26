// SPDX-License-Identifier: MIT

// The seam between web APIs (browsers) and node builtins (node, deno).
// Selected at runtime by the presence of process.getBuiltinModule, so bundlers
// only ever see the web path and never try to resolve node builtins.

import { listen_endpoint, post_endpoint, type EmitterEndpoint, type Endpoint } from "./endpoint.ts";
import { assert } from "./util.ts";

export interface WorkerHandle {
  post(message: unknown, transfer?: Transferable[]): void;
  terminate(): Promise<void>;
}

export interface WorkerHandlers {
  on_message(message: unknown): void;
  on_error(error: Error): void;
}

interface Platform {
  load_wasm(url: URL): Promise<{
    bytes: Uint8Array<ArrayBuffer>;
    module: WebAssembly.Module;
  }>;
  spawn_worker(name: string, handlers: WorkerHandlers): WorkerHandle;
  worker_endpoint(): Endpoint;
  quit(): void;
}

function worker_handle(
  endpoint: Endpoint,
  terminate: () => void | Promise<unknown>,
  handlers: WorkerHandlers,
): WorkerHandle {
  const stop_listening = listen_endpoint(endpoint, {
    message: handlers.on_message,
    error: handlers.on_error,
  });
  return {
    post: (message, transfer) => post_endpoint(endpoint, message, transfer),
    terminate: async () => {
      stop_listening();
      await terminate();
    },
  };
}

const web: Platform = {
  async load_wasm(url) {
    const response = await fetch(url);
    // native code caching is only supported with the *Streaming functions, so use it:
    const module = await WebAssembly.compileStreaming(response.clone());
    const bytes = new Uint8Array(await response.arrayBuffer());
    return { bytes, module };
  },
  spawn_worker(name, handlers) {
    const worker = new Worker(new URL("./worker.js", import.meta.url), {
      type: "module",
      name,
    });
    return worker_handle(worker, () => worker.terminate(), handlers);
  },
  worker_endpoint() {
    return self;
  },
  quit() {
    self.close();
  },
};

// Hand-written types for the slices of the node builtins we use, so that
// @types/node doesn't leak into a web-first package.
interface NodeWorker extends EmitterEndpoint {
  terminate(): Promise<number>;
}

interface GetBuiltinModule {
  (id: "node:fs/promises"): {
    readFile(path: URL): Promise<Uint8Array<ArrayBuffer>>;
  };
  (id: "node:worker_threads"): {
    Worker: new (filename: URL, options: { name: string }) => NodeWorker;
    parentPort: Endpoint | null;
  };
}

interface NodeProcess {
  getBuiltinModule?: GetBuiltinModule;
  exit(code: number): never;
}

function node(getBuiltinModule: GetBuiltinModule, process: NodeProcess): Platform {
  const { readFile } = getBuiltinModule("node:fs/promises");
  const { Worker, parentPort } = getBuiltinModule("node:worker_threads");
  return {
    async load_wasm(url) {
      const bytes = await readFile(url);
      return { bytes, module: await WebAssembly.compile(bytes) };
    },
    spawn_worker(name, handlers) {
      const worker = new Worker(new URL("./worker.js", import.meta.url), {
        name,
      });
      return worker_handle(worker, () => worker.terminate(), handlers);
    },
    worker_endpoint() {
      assert(parentPort, "not in a worker");
      return parentPort;
    },
    quit() {
      process.exit(0);
    },
  };
}

const process = (globalThis as { process?: NodeProcess }).process;
const getBuiltinModule = process?.getBuiltinModule;

export const platform: Platform =
  getBuiltinModule && process ? node(getBuiltinModule, process) : web;
