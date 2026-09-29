/* lot_dlmalloc_mt.c — sysroot/wasm_dlmalloc.c with locking, for threaded Blink.
 *
 * Same sbrk-only dlmalloc, but USE_LOCKS: with threads, Blink runs one host
 * pthread per guest thread and they all allocate. Spin locks (dlmalloc's
 * __sync-based ones, sched_yield under contention) rather than pthread
 * mutexes, so malloc never depends on futex wake handoffs. */
#define HAVE_MMAP 0
#define HAVE_MREMAP 0
#define HAVE_MORECORE 1
#define MORECORE_CONTIGUOUS 1
#define MORECORE_CANNOT_TRIM 1
#define USE_LOCKS 1
#define USE_SPIN_LOCKS 1
#define MALLOC_ALIGNMENT ((size_t)16U)
#define DEFAULT_GRANULARITY ((size_t)(1U << 20))
#define NO_MALLINFO 1
#define NO_MALLOC_STATS 1
#define LACKS_SYS_MMAN_H 1
#define MALLOC_FAILURE_ACTION
#include "../../sysroot/dlmalloc.c"

void *aligned_alloc(size_t align, size_t len) { return dlmemalign(align, len); }

/* musl's own internal allocations (pthread_create's stack + TLS block,
 * pthread_join/exit, atexit, locale, ...) go through __libc_malloc, which
 * forwards to mallocng — and mallocng's large-block path needs mmap and
 * traps ("unreachable") here. A 128 KB default thread stack is a large
 * block, so every guest clone() died. Route them to this dlmalloc too;
 * defined before -lc, the lite_malloc/free/realloc/libc_calloc members
 * are then never pulled in. */
void *__libc_malloc(size_t n) { return dlmalloc(n); }
void *__libc_calloc(size_t m, size_t n) { return dlcalloc(m, n); }
void *__libc_realloc(void *p, size_t n) { return dlrealloc(p, n); }
void __libc_free(void *p) { dlfree(p); }
