"""WebFuse wasm-guest compat shim (auto-imported via PYTHONPATH).

The app targets pydantic v2, but v2 needs the Rust pydantic-core which can't
run on this kernel, so we ship pydantic v1.10. The schemas declare
`class Config: from_attributes = True` (the v2 name); v1 ignores it, leaving
orm_mode off, so FastAPI can't serialise SQLAlchemy ORM rows against
response_model. Enable orm_mode globally before any model is defined.
"""
try:
    import pydantic
    if pydantic.VERSION.startswith("1."):
        pydantic.BaseConfig.orm_mode = True
except Exception:
    pass

# --- Run sync route handlers on the event-loop thread, not a worker thread. ---
# FastAPI/Starlette dispatch every sync `def` endpoint to an anyio worker thread
# (run_in_threadpool -> anyio.to_thread.run_sync). Under this wasm kernel's
# asyncify/threading model, once the loop hands off to a worker thread and
# returns, the epoll wait for the *next* request on a kept-alive socket never
# wakes ("HTTP connection lost" after the 1st request) — so HTTP/1.1 keep-alive
# reuse breaks and browsers stall on the 2nd request. The guest runs one request
# at a time anyway, so run sync handlers inline on the loop thread: correct
# behaviour, no worker thread, keep-alive works. Remove once the kernel's
# thread<->epoll wakeup is fixed. See [[wasm-kernel-async-fixes]].
try:
    import anyio.to_thread

    async def _lot_run_sync_inline(func, *args, **kwargs):  # noqa: ANN001
        # Ignore cancellable/abandon_on_cancel/limiter kwargs — no thread here.
        return func(*args)

    anyio.to_thread.run_sync = _lot_run_sync_inline
except Exception:
    pass

# --- Real thread stacks need a real size. ---
# Since sysroot/wasm_clone.c each pthread runs on its own malloc'd stack (before
# that fix they all shared the main thread's 32 MB one), and musl's default is
# 128 KB — far too small for asyncified wasm frames running Python. Ask for 4 MB (thread stacks come from the mmap shim; 16 MB per thread exhausted the 256 MB process cap)
# before any thread is created (uvicorn/anyio spawn workers at startup).
try:
    import threading
    threading.stack_size(4 * 1024 * 1024)
except Exception:
    pass
