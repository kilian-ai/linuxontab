# cross-process futex keying

Two threaded wasm processes running at once could hang with every thread in
`S` (0:00 CPU) while each passed alone (ffmpeg7 r1/r2 concurrent encodes, two
`threadstacks`). Root cause is in the generic futex code, not the allocator or
worker.ts: on `!CONFIG_MMU`, `FLAGS_SHARED` is 0 and `get_futex_key()` sets
`key->private.mm = NULL`, keying every futex by virtual address alone ("there
is only one address space"). wasm is NOMMU but every process has its own
linear memory with an identical layout, so the same address in two processes
is the same futex to the kernel: a `FUTEX_WAKE(n=1)` in one process can be
consumed by a waiter in the other, which re-checks its own word, goes back to
sleep, and the intended waiter never wakes.

Fix (kernel `wasm-linuxontab-7.1`): new `ARCH_NOMMU_PER_MM_ADDRESS_SPACE`,
selected by `WASM`, makes `get_futex_key()` include the mm as on MMU systems.

| test | checks |
|---|---|
| `futexkey wait` / `futexkey wake` | deterministic: `wake` on a word nobody in *its* process waits on must report 0 woken; the other process's `wait` must time out (4 s) |
| `condpp [rounds]` | two threads ping-pong through one mutex + condvar; run two copies at once |

    sh local/futex-keying/build.sh     # -> local/futex-keying/out/

In the guest (`lot-dev`):

    mount -t tmpfs tmpfs /tmp; cd /tmp
    for f in futexkey condpp; do lotfetch http://192.168.86.1/local/futex-keying/out/$f $f; done
    chmod +x futexkey condpp
    ./futexkey wait & sleep 1; ./futexkey wake; wait
    ./condpp 2000 > c1.log 2>&1 & ./condpp 2000 > c2.log 2>&1 &

Results 2026-09-29, kernel 7.1.5 before the fix (1f2c5017459f):

    wake: pid 68 futex @0x41528 woke 1: FAIL, crossed processes
    wait: returned 0 (woken): FAIL, woken by another process        (2/2)
    condpp 2000 alone: OK; two at once: both hang, all 6 tasks State S, empty logs

After the fix (same tests, local test kernel = 1f2c5017459f + the futex patch):

    futexkey: wake woke 0: OK, wait timed out: OK                     (2/2)
    condpp 2000 x3 concurrent + 2 busy loops: 9/9 OK                  (3 rounds)
    threadstacks x2 concurrent: both "0 errors: OK"                   (3/3)
    ffmpeg7 7.0.2-r2 x2 concurrent 720p mpeg4 -threads 4: both 100 frames (2/2)
