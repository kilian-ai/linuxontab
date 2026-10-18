// Preloaded with `node --import` into the runner AND every kernel worker
// (worker_threads inherit the parent's --import). Two jobs:
//
//  1. worker.js was bundled for browsers and reads `self.name` in its debug
//     lines; Node workers have no `self`.
//  2. stdout belongs to the guest console. The kernel runtime and the
//     networking code log freely with console.*, so route those away from
//     stdout: everything to $LOT_RUN_LOG when set, otherwise warnings and
//     errors to stderr and the rest nowhere.
import { openSync, writeSync } from "node:fs";
import { format } from "node:util";
import { isMainThread, threadId } from "node:worker_threads";

globalThis.self ??= globalThis;

const logPath = process.env.LOT_RUN_LOG;
const logFd = logPath ? openSync(logPath, "a") : null;
const tag = isMainThread ? "main" : "w" + threadId;

function sink(toStderr) {
  return (...args) => {
    const line = `[${tag}] ${format(...args)}\n`;
    try {
      if (logFd !== null) writeSync(logFd, line);
      else if (toStderr) writeSync(2, line);
    } catch {}
  };
}

console.log = console.info = console.debug = console.trace = sink(false);
console.warn = console.error = sink(true);

globalThis.__lotShim = true;
