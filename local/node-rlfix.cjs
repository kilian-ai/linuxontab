// LinuxOnTab Node TUI fix.
//
// Several common Node CLIs (anything using @clack/prompts, ink, listr2,
// inquirer prompts, …) crash or render blank inside the v86 serial
// console because:
//
//   1) `stty size` reports 0 rows (the v86 serial line has no SIGWINCH;
//      our xterm.onResize handler pushes `stty cols N rows M` after
//      first paint, but Node may already have spawned and cached 0).
//      `process.stdout.rows = 0` makes clack's scroll math produce
//      Infinity/NaN — input is captured but never echoed.
//
//   2) clack passes a non-TTY writable wrapper as readline's `output`,
//      so `rl.columns = 0`, then `_refreshLine` computes `pos % 0 = NaN`
//      and Node throws ERR_INVALID_ARG_VALUE.
//
// We patch both layers:
//   - tty.WriteStream prototype getters fall back to env $COLUMNS/$LINES
//     (or 120/40) when the underlying value is 0/undefined.
//   - readline.Interface.columns falls back to process.stdout.columns.
//
// Loaded via:  NODE_OPTIONS=--require=/etc/node-rlfix.cjs
// (set by /etc/profile.d/03nodefix.sh)
//
// IMPORTANT: Node's WriteStream constructor does `this.columns = winSize[0]`
// during init, so we MUST provide a setter — a getter-only override
// crashes every node invocation with
//   "Cannot set property columns of #<WriteStream> which has only a getter".
try {
  const tty = require("tty");
  const proto = tty.WriteStream && tty.WriteStream.prototype;
  if (proto) {
    for (const key of ["columns", "rows"]) {
      const orig = Object.getOwnPropertyDescriptor(proto, key);
      const stash = "__rlfix_" + key;
      const fallback = () =>
        key === "columns"
          ? parseInt(process.env.COLUMNS, 10) || 120
          : parseInt(process.env.LINES, 10) || 40;
      Object.defineProperty(proto, key, {
        configurable: true,
        get() {
          let v = this[stash];
          if (v == null && orig && orig.get) {
            try { v = orig.get.call(this); } catch (_) {}
          }
          if (!v || !Number.isFinite(v)) v = fallback();
          return v;
        },
        set(v) {
          if (orig && orig.set) {
            try { orig.set.call(this, v); return; } catch (_) {}
          }
          this[stash] = v;
        },
      });
    }
  }
} catch (_) {}

try {
  const rl = require("readline");
  const orig = rl.createInterface;
  rl.createInterface = function (...args) {
    const i = orig.apply(this, args);
    try {
      Object.defineProperty(i, "columns", {
        configurable: true,
        get() { return process.stdout.columns || 120; },
      });
    } catch (_) {}
    return i;
  };
} catch (_) {}
