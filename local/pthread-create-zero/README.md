# pthread_create handed new threads unzeroed TLS / struct pthread / TSD

`pool2.cpp` is comphelper::ThreadPool in miniature: osl-style threads
(4 MB stack, created suspended, then resumed), workers spawned lazily by
`push`, two "filter passes" per round, each ending in `notify_all` + join.

Before `toolchain/patches/musl-wasm-pthread-create-zero-tls.patch` it hung
in `pthread_join` within the first few rounds (about half the runs). The
console showed `RuntimeError: table index is out of bounds` in a worker:
musl's wasm `pthread_create` took the thread region from `__libc_malloc`
instead of zeroed mmap pages, so a recycled heap block gave the new thread a
stale `self->cancelbuf`. `__pthread_exit` then called garbage through
`call_indirect` and trapped before setting `detach_state`, and the joiner
waited forever. Stale TSD slots made `pthread_getspecific` return garbage
too (libxml2 in LibreOffice read zip data as its per-thread state).

    /lot/spike/bin/wasm-c++ -O2 pool2.cpp -o pool2     # in the `lo` container
    pool2 6 4 24      # rounds, max workers, tasks per pass; SIGUSR1 dumps the event ring

After the patch: 12/12 runs pass; LibreOffice's About dialog opens with
real pool workers again.
