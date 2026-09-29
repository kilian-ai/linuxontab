# thread / fork shim regression tests

Native guest programs for the three platform bugs the x86-blink spike found
(spikes/x86-blink/README.md, "Threads") and that are now fixed in the shared
shims under `sysroot/`:

| test | shim | checks |
|---|---|---|
| `tlsprobe` | `wasm_clone.c` + `wasm_dlmalloc_mt.c` | 4 threads each get their own `_Thread_local` block, freshly initialised (.tdata + .tbss), 4 distinct `&v` |
| `tlsprobe-big` | same, `-DBIG` | same with an 8 KB TLS array: the aligned_alloc path instead of the on-stack one |
| `forktls` | `wasm_fork.c` (asyncified) | fork child keeps `__tls_base` and `__stack_pointer`: reads/writes a `_Thread_local`, ~100 KB of deep calls, caller frames intact in the parent and in a child that returns up through them |
| `vforktls` | `wasm_clone.c` + `wasm_dlmalloc_mt.c` | a `clone(CLONE_VM\|CLONE_VFORK)` child with its own stack (Blink's guest vfork) gets a fresh TLS block and leaves the parent's untouched; `posix_spawn` still works |
| `threadstacks` | `wasm_clone.c` + `wasm_dlmalloc_mt.c` | 4 rounds x 6 `pthread_create` with default 128 KB stacks (freed at join), detached threads, malloc/realloc churn from every thread |

`*-old` are the same programs linked with the shims as of `$OLD_REV` (before the fixes).

    sh local/thread-shims/build.sh          # -> local/thread-shims/out/

In the guest (dev server `lot-dev`), the virtual gateway serves repo paths directly:

    mount -t tmpfs tmpfs /tmp; cd /tmp
    lotfetch http://192.168.86.1/local/thread-shims/out/tlsprobe tlsprobe; chmod +x tlsprobe

Results 2026-09-29, kernel 7.1.5:

    tlsprobe-old      3 of 4 threads saw another thread's value, 4 did not start from a fresh image, 1 distinct &v
    tlsprobe          0 of 4 ..., 0 did not start from a fresh image, 4 distinct &v   (5/5 runs, -big 5/5)
    forktls-old       child: t=0, want 42 (TLS base lost) ... FAIL
    forktls           OK   (5/5)
    vforktls-old      vfork child saw t=0 (want 42: fresh block) ... FAIL
    vforktls          OK   (4/4)
    threadstacks-old  main traps (unreachable) in mallocng during pthread_create, no output
    threadstacks      24 threads joined, 4 detached done, 0 errors: OK   (3/3)

`tlsprobe-ng16` is python3's configuration (musl mallocng, 16 MB thread
stacks). It FAILS with the old and the new `__clone`, and with the libc.a from
before the brk fix: after two threads are created, the main thread traps in
`__libc_malloc_impl` (mallocng's large-block path) inside the third
`pthread_create`, and the process hangs with its remaining threads asleep.
With the old `__clone` the threads also trapped in mallocng's `free()` of the
trampoline argument (the new `__clone` does not allocate there). Threaded
programs should link `sysroot/wasm_dlmalloc_mt.c`.
