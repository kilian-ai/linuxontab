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
 * Single-threaded (USE_LOCKS 0): the kernel's futex handoff is broken anyway.
 */
#define HAVE_MMAP 0
#define HAVE_MREMAP 0
#define HAVE_MORECORE 1
#define MORECORE_CONTIGUOUS 1
#define MORECORE_CANNOT_TRIM 1
#define USE_LOCKS 0
#define MALLOC_ALIGNMENT ((size_t)16U)
#define DEFAULT_GRANULARITY ((size_t)(1U << 20))
#define NO_MALLINFO 1
#define NO_MALLOC_STATS 1
#define LACKS_SYS_MMAN_H 1
#define MALLOC_FAILURE_ACTION
#include "dlmalloc.c"

void *aligned_alloc(size_t align, size_t len) { return dlmemalign(align, len); }
