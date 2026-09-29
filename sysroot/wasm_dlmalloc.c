/* wasm_dlmalloc.c — sbrk-only malloc for ports that move big buffers.
 *
 * The sysroot's musl mallocng backs every allocation above ~128 KB with
 * mmap/munmap/mremap, and this platform has no real mmap: large free() and
 * realloc() trap in mallocng's consistency checks (wasm "unreachable", the
 * guest prints "Segmentation fault"). ffmpeg hit it on every >=720p frame.
 *
 * This is Doug Lea's dlmalloc (sysroot/dlmalloc.c, public domain) configured
 * to grow the heap only through sbrk (kernel brk), never mmap. Linked before
 * -lc it replaces malloc/free/calloc/realloc/posix_memalign/memalign/
 * malloc_usable_size; musl >= 1.2.2 supports exactly that replacement (its
 * internals hand out public-malloc memory whenever the caller must free it).
 *
 * musl's OWN allocations (__libc_malloc & co: pthread_create's stack + TLS
 * block, freed again at join/exit; the startup TLS area; atexit, locale, ...)
 * do not go through the public malloc — they went to mallocng, whose large
 * path traps as above: a default 128 KB thread stack is a large block. They
 * are routed to dlmalloc too (below), so mallocng is never linked at all.
 *
 * Single-threaded by default (USE_LOCKS 0). Threaded ports link
 * wasm_dlmalloc_mt.c instead, which sets LOT_DLMALLOC_THREADS: spin locks
 * (__sync-based, sched_yield under contention) rather than pthread mutexes,
 * so malloc never depends on futex wake handoffs.
 */
#ifndef LOT_DLMALLOC_THREADS
#define LOT_DLMALLOC_THREADS 0
#endif
#define HAVE_MMAP 0
#define HAVE_MREMAP 0
#define HAVE_MORECORE 1
#define MORECORE_CONTIGUOUS 1
#define MORECORE_CANNOT_TRIM 1
#if LOT_DLMALLOC_THREADS
#define USE_LOCKS 1
#define USE_SPIN_LOCKS 1
#else
#define USE_LOCKS 0
#endif
#define MALLOC_ALIGNMENT ((size_t)16U)
#define DEFAULT_GRANULARITY ((size_t)(1U << 20))
#define NO_MALLINFO 1
#define NO_MALLOC_STATS 1
#define LACKS_SYS_MMAN_H 1
#define MALLOC_FAILURE_ACTION
#include "dlmalloc.c"

void *aligned_alloc(size_t align, size_t len) { return dlmemalign(align, len); }

/* Defined before -lc, these keep libc.a's lite_malloc/libc_calloc and
 * mallocng free/realloc members from ever being pulled in. */
void *__libc_malloc(size_t n) { return dlmalloc(n); }
void *__libc_calloc(size_t m, size_t n) { return dlcalloc(m, n); }
void *__libc_realloc(void *p, size_t n) { return dlrealloc(p, n); }
void __libc_free(void *p) { dlfree(p); }
