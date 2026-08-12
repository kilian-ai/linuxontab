# Scheduler lost-wake / CPU-token wedge — repro + harness

Debug harness for the wasm-kernel "lost wake" bug (a parked thread never wakes
and the whole guest wedges). See the memory file `wasm-kernel-async-fixes` for
the original 20-line Python repro.

## Repros

- **`futexpp.c`** — minimal RAW-futex pthread ping-pong (no CPython/GIL). Two
  threads bounce a token via FUTEX_WAIT/FUTEX_WAKE. **RESULT: PASSES** — 5/5
  rounds complete. Proves the kernel futex+scheduler baton is sound; the bug is
  NOT raw futex. Build against toolchain/musl-sysroot-fixed with -pthread, then
  `wasm-opt --asyncify -O1`, install to /usr/local/bin/futexpp.
  Markers: `getpriority(0, step)` shows as `nr=141 a1=step` in the syscall trace.

- **`condpp.c`** — RAW pthread **mutex + condition-variable** ping-pong (pure C,
  no CPython). Two threads hand a `turn` flag back and forth using
  `pthread_mutex_lock` + `pthread_cond_wait`/`pthread_cond_signal`. **RESULT:
  WEDGES at round 2** — prints "condpp round 0 ok", "condpp round 1 ok", then
  both threads block in `futex_wait` forever. Build/install exactly like
  futexpp. This is the decisive repro: it removes CPython entirely and still
  reproduces, so the bug is the **musl mutex+cond path**, not Python and not the
  CPU-token/idle-starvation theory (both threads here are cleanly *blocked*,
  not spinning — time is NOT frozen).

- **`evrepro.py`** — CPython `threading.Event` ping-pong. Same failure at a
  small round count. (Historically framed as a `swapper/0` spin-hold; the
  condpp.c repro shows the real mechanism below — a lost cond signal, not a
  spin-hold. The signal-restart fix moved evrepro's wedge from round 0 to
  round 2, matching condpp.)

## FIXED July 24, 2026 — kernel futex read must be coherent with userspace atomics

Root cause: user memory is a SharedArrayBuffer that musl mutates with wasm
ATOMIC ops. The kernel's futex value-check read the futex word through the
`user.read` uaccess import — a plain (non-atomic) `Uint8Array` copy in worker.js.
The wasm/JS shared-memory model does NOT guarantee a non-atomic read observes
the latest value an *atomic* store in another agent (worker) wrote, so the
value-check could read a STALE futex word (e.g. musl cond_signal's
`a_swap(barrier,0)` not yet visible) and enqueue a waiter for a wake that already
landed = lost wakeup. Timing-dependent: any scheduling perturbation that yields
the CPU token (a syscall, a nanosleep) hid it; the raw tight loop hit it ~every
run at the first round where both threads block concurrently.

Fix (`shell/linux-dist/dist/worker.js`, `read()`): aligned 4-byte uaccess reads
go through `Atomics.load`/`Atomics.store` (seq-cst) instead of a Uint8Array copy,
keeping the kernel's view of futex words coherent with musl. Bulk copies (I/O
buffers, the n≠4 path) are unchanged. VERIFIED: condpp 51/51 clean (was ~0/10),
python threading.Event 8/8, SSH + 200KB SFTP intact. NOTE: a symmetric change to
`write()` was tried and REVERTED — it regressed (a wedge), and the read side alone
is sufficient and proven.

## Diagnosis (net) — updated July 24 (historical, superseded by the fix above)

Raw single-futex ping-pong (`futexpp.c`) PASSES; pthread **cond** ping-pong
(`condpp.c`) WEDGES at round 2. Clean syscall trace (`?debuglog=98,141`) of the
condpp wedge shows: worker registers as a cond waiter and blocks in
`futex_wait`; main runs its round, but its `pthread_cond_signal` issues **NO
futex_wake at all** (no `nr=98 a1=129` between main's marker and its next wait)
— i.e. main's signaler sees an **empty waiter list** even though the worker is
already registered. Worker then sleeps forever. This is a **cross-worker
shared-memory visibility gap in musl's condvar waiter list**: the waiter's store
that links its node (`_c_head`/`_c_seq` inside pthread_cond_t) is not observed by
the signaler's load, so the signal is skipped. Each cond_wait uses a fresh
on-stack waiter node, so the futex address changes every round (normal musl
behavior — not the bug).

Not the CPU token (both threads block, time keeps advancing), not raw futex,
not Python. The fix likely lives at the memory-ordering boundary between the
kernel's uaccess path (`wasm_user_read`/`raw_copy_from_user`, a plain byte copy
with no barrier) and userspace's atomics on the same word — the kernel may read
a stale futex/cond word — OR in how musl-on-wasm's cond orders its waiter-list
publish vs the signaler's read. Next step: instrument the kernel futex
enqueue/wake (hash-bucket + observed uval) to confirm whether the worker's wait
is on the hash bucket when main's signal *would* have fired, and whether a
memory fence in the uaccess read closes it.

## Kernel sched-trace (built, gated)

arch/wasm/kernel/{process.c,irq.c} carry a gated `@K@`-prefixed trace of every
`__switch_to` (token handoff, from->to pid:comm) and `arch_cpu_idle` entry. It
auto-arms on a python3/futexpp task and self-limits (budget). PROVEN to emit
(an unconditional boot probe reached the guest console). wasm.js's
boot_console_write shim is meant to route `@K@` lines to the host /log, but that
routing is flaky under browser module-caching — read the trace from the xterm
buffer (window.__xterm__) instead, or fix the module-cache issue first.
