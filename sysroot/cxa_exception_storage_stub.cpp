// Replacement for cxa_exception_storage.cpp that avoids thread-local storage.
// libc++abi's stock version uses TLS (built without -matomics/-mbulk-memory),
// which makes it incompatible with WASM shared memory required by the kernel.
//
// In the WASM kernel, each Linux process runs in a single Web Worker, so
// there is no actual intra-process threading — a plain global is correct.
//
// This file is compiled with -matomics -mbulk-memory to satisfy the kernel's
// shared-memory feature requirement, then swapped into libc++abi.a.

#include <stddef.h>
#include <stdlib.h>

namespace __cxxabiv1 {

struct __cxa_eh_globals {
    void* caughtExceptions;
    unsigned int uncaughtExceptions;
};

static __cxa_eh_globals globals;

extern "C" __cxa_eh_globals* __cxa_get_globals() noexcept {
    return &globals;
}

extern "C" __cxa_eh_globals* __cxa_get_globals_fast() noexcept {
    return &globals;
}

} // namespace __cxxabiv1
