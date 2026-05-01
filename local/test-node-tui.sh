#!/bin/sh
# LinuxOnTab Node TUI smoke test.
#
# Reproduces the @clack/prompts NaN / blank-echo bug in isolation, so we
# can verify /etc/node-rlfix.cjs without trial-running openclaw chat
# (which is slow to install and noisy when broken).
#
# Tests, in order:
#   1) `node -e console.log(stdout.columns, stdout.rows)`  — must NOT crash
#      and must print non-zero numbers.
#   2) Raw readline: open a readline.Interface with a non-TTY output
#      wrapper (mimicking what clack does), force `columns = 0`, then
#      type. Without the fix, Node throws ERR_INVALID_ARG_VALUE on
#      first keystroke. With the fix, `columns` getter returns 120.
#   3) Real @clack/prompts text() — installs into /tmp/clack-test if not
#      already present (~5 MB). Skipped when --no-clack is passed.
#
# Usage:
#   sh test-node-tui.sh          # all 3 tests
#   sh test-node-tui.sh --no-clack
#
# Run after editing /etc/node-rlfix.cjs to verify the change before
# committing to shell/index.html.

set -e

GREEN=''; RED=''; YEL=''; NC=''
if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; NC=$'\033[0m'; fi
ok()   { printf "%s[ OK ]%s %s\n"   "$GREEN" "$NC" "$1"; }
fail() { printf "%s[FAIL]%s %s\n"   "$RED"   "$NC" "$1"; exit 1; }
info() { printf "%s[INFO]%s %s\n"   "$YEL"   "$NC" "$1"; }

info "rlfix file: /etc/node-rlfix.cjs"
[ -f /etc/node-rlfix.cjs ] || fail "/etc/node-rlfix.cjs not present — run /etc/profile.d/03nodefix.sh first?"
info "NODE_OPTIONS=$NODE_OPTIONS"
info "TERM=$TERM  COLUMNS=$COLUMNS  LINES=$LINES"

# -------- Test 1: basic stdout.columns/rows --------
# IMPORTANT: we must NOT capture stdout (e.g. `out=$(node …)`) because
# that makes stdout a pipe, not a TTY — `process.stdout` then isn't a
# tty.WriteStream at all and `.columns`/`.rows` are undefined regardless
# of any rlfix. We dump the JSON to a file so node's stdout stays the
# real terminal.
info "test 1: process.stdout.columns / rows must be finite & nonzero (TTY mode)"
node -e '
  const fs = require("fs");
  fs.writeFileSync("/tmp/rlfix-test1.json", JSON.stringify({
    c: process.stdout.columns,
    r: process.stdout.rows,
    isTTY: process.stdout.isTTY === true,
    ctor: process.stdout.constructor && process.stdout.constructor.name,
  }));
' || fail "node crashed on startup (rlfix probably has a getter without a setter)"
out=$(cat /tmp/rlfix-test1.json)
echo "  → $out"
echo "$out" | grep -q '"isTTY":true' || \
  fail "stdout is not a TTY in this shell — run the test directly in the v86 console, not through ssh/scp/non-interactive"
echo "$out" | grep -q '"c":[1-9]' || fail "stdout.columns is 0 or missing"
echo "$out" | grep -q '"r":[1-9]' || fail "stdout.rows is 0 or missing"
ok "stdout has nonzero dimensions"

# -------- Test 2: readline NaN repro --------
info "test 2: readline with rl.columns=0 must not throw NaN on cursorTo"
node <<'EOF' || fail "readline cursorTo NaN repro crashed"
const rl = require("readline");
const { Writable } = require("stream");
// Mimic clack: pass a non-TTY writable as the readline output. Without
// the rlfix, rl.columns is 0 and any cursor math is NaN.
const out = new Writable({ write(c, e, cb) { cb(); } });
const i = rl.createInterface({ input: process.stdin, output: out, terminal: true });
const n = 8;
let pos = 0;
// Simulate _refreshLine math: pos % rl.columns. The rlfix overrides
// `columns` getter on every Interface to return process.stdout.columns
// (which itself falls back to env or 120).
const cols = i.columns;
if (!cols || !Number.isFinite(cols)) { console.error("BAD: i.columns =", cols); process.exit(1); }
const m = pos % cols;
if (!Number.isFinite(m)) { console.error("BAD: pos % cols =", m); process.exit(1); }
console.log("readline.columns =", cols, " pos%cols =", m);
i.close();
EOF
ok "readline columns non-zero, pos % columns is finite"

# -------- Test 3: real clack/prompts (optional) --------
if [ "${1:-}" = "--no-clack" ]; then
  info "test 3 skipped (--no-clack)"
  exit 0
fi
info "test 3: installing @clack/prompts into /tmp/clack-test (one-time)"
mkdir -p /tmp/clack-test
cd /tmp/clack-test
[ -f node_modules/@clack/prompts/package.json ] || \
  npm install --no-audit --no-fund --no-progress @clack/prompts 2>&1 | tail -5
info "running clack note() — should NOT throw NaN"
node -e '
  const p = require("@clack/prompts");
  p.intro("rlfix smoke test");
  p.note("If you see this, clack rendered without crashing.\nProcess: stdout " + process.stdout.columns + "x" + process.stdout.rows);
  p.outro("done");
'
ok "clack/prompts rendered without crashing"
echo
info "Interactive sanity check: try"
info "  node -e 'require(\"@clack/prompts\").text({message:\"type something:\"}).then(v=>console.log(\"got:\",v))'"
info "in /tmp/clack-test — keystrokes should echo as you type."
