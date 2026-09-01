/* wasm_mmap_anon.c — minimal mmap/munmap for MAP_ANON on wasm32-musl.
 *
 * The wasm sysroot has no mmap at all (sys/mman.h guards it behind
 * #ifndef __wasm__), but nginx/httpd allocate anonymous (shared) memory for
 * counters/scoreboards even in single-process mode. In a single process,
 * MAP_SHARED|MAP_ANON and MAP_PRIVATE|MAP_ANON are the same thing: page
 * -aligned zeroed memory. Serve both from malloc; refuse file mappings.
 *
 * Link before -lc in single-process server builds only. NOT a real mmap:
 * multi-process shared memory will silently not be shared.
 */
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "wasm_mman.h"

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    (void)addr; (void)prot; (void)off;
    if (!(flags & MAP_ANON) || fd != -1 || len == 0) {
        errno = ENOSYS;
        return MAP_FAILED;
    }
    void *p = NULL;
    if (posix_memalign(&p, 65536, len) != 0) {
        errno = ENOMEM;
        return MAP_FAILED;
    }
    memset(p, 0, len);
    return p;
}

int munmap(void *addr, size_t len)
{
    (void)len;
    if (addr && addr != MAP_FAILED)
        free(addr);
    return 0;
}
