/* wasm_mmap.c — mmap for wasm32 processes, in userspace.
 *
 * A wasm process can only address its own linear memory, so the kernel's
 * mmap (which returns kernel-chosen addresses) is useless to it, and the
 * wasm32 musl leaves mmap out entirely. Large ports (LibreOffice, freetype)
 * map files and anonymous memory routinely, so serve both from the heap:
 *   - MAP_ANONYMOUS: zeroed, page-aligned memory
 *   - file mappings: the range is read in with pread(); a MAP_SHARED mapping
 *     opened for writing is written back with pwrite() on msync and munmap
 *     (one process per address space: nothing else can see it in between)
 * MAP_FIXED is refused. munmap of a whole mapping frees it; a partial munmap
 * writes back but keeps the memory (a sub-range of a malloc block can't be
 * returned). Protections are advisory. Thread-safe.
 *
 * Link before -lc; with toolchain/cpp-eh-sysroot, whose sys/mman.h declares
 * mmap on wasm (the plain sysroot needs -include sysroot/wasm_mman.h).
 */
#include <errno.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#ifndef PROT_WRITE
#include "wasm_mman.h"
#else
#include <sys/mman.h>
#endif

#define MAP_ALIGN 65536          /* the kernel's page size */

typedef struct {
    char *addr;
    size_t len;
    int fd;                      /* dup of the file for write-back, or -1 */
    off_t off;
    int writeback;               /* MAP_SHARED + PROT_WRITE on a file */
} Mapping;

static Mapping *maps;
static size_t nmaps, cmaps;
static volatile int maplock;

static void lock(void) { while (__atomic_exchange_n(&maplock, 1, __ATOMIC_ACQUIRE)) sched_yield(); }
static void unlock(void) { __atomic_store_n(&maplock, 0, __ATOMIC_RELEASE); }

static Mapping *find(char *p) {           /* the mapping containing p (locked) */
    for (size_t i = 0; i < nmaps; i++)
        if (p >= maps[i].addr && p < maps[i].addr + maps[i].len) return &maps[i];
    return NULL;
}

static int write_back(const Mapping *m, char *from, size_t len) {
    if (!m->writeback) return 0;
    off_t o = m->off + (from - m->addr);
    while (len) {
        ssize_t w = pwrite(m->fd, from, len, o);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        if (w == 0) break;
        from += w; o += w; len -= (size_t)w;
    }
    return 0;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    (void)addr;
    if (!len || (flags & MAP_FIXED)) { errno = EINVAL; return MAP_FAILED; }
    int anon = (flags & MAP_ANONYMOUS) || fd < 0;
    void *p = NULL;
    if (posix_memalign(&p, MAP_ALIGN, len)) { errno = ENOMEM; return MAP_FAILED; }
    memset(p, 0, len);
    Mapping m = { p, len, -1, off, 0 };
    if (!anon) {
        size_t got = 0;
        while (got < len) {                     /* short file: rest stays zero */
            ssize_t r = pread(fd, (char *)p + got, len - got, off + (off_t)got);
            if (r < 0) {
                if (errno == EINTR) continue;
                int e = errno; free(p); errno = e; return MAP_FAILED;
            }
            if (r == 0) break;
            got += (size_t)r;
        }
        if ((flags & MAP_SHARED) && (prot & PROT_WRITE)) {
            m.fd = dup(fd);
            m.writeback = m.fd >= 0;
        }
    }
    lock();
    if (nmaps == cmaps) {
        size_t c = cmaps ? cmaps * 2 : 64;
        Mapping *n = realloc(maps, c * sizeof *n);
        if (!n) {
            unlock();
            if (m.fd >= 0) close(m.fd);
            free(p);
            errno = ENOMEM;
            return MAP_FAILED;
        }
        maps = n; cmaps = c;
    }
    maps[nmaps++] = m;
    unlock();
    return p;
}

int munmap(void *addr, size_t len) {
    char *p = addr;
    lock();
    Mapping *m = find(p);
    if (!m) { unlock(); return 0; }             /* not ours / already gone */
    if (p + len > m->addr + m->len) len = (size_t)(m->addr + m->len - p);
    write_back(m, p, len);
    if (p == m->addr && len >= m->len) {        /* the whole mapping */
        Mapping gone = *m;
        *m = maps[--nmaps];
        unlock();
        if (gone.fd >= 0) close(gone.fd);
        free(gone.addr);
        return 0;
    }
    unlock();
    return 0;
}

int msync(void *addr, size_t len, int flags) {
    (void)flags;
    char *p = addr;
    lock();
    Mapping *m = find(p);
    int r = 0;
    if (m) {
        if (p + len > m->addr + m->len) len = (size_t)(m->addr + m->len - p);
        r = write_back(m, p, len);
    }
    unlock();
    return r;
}

void *mremap(void *old, size_t old_len, size_t new_len, int flags, ...) {
    (void)old_len;
    if (!(flags & 1 /* MREMAP_MAYMOVE */)) { errno = ENOMEM; return MAP_FAILED; }
    lock();
    Mapping *m = find(old);
    if (!m || m->addr != old || m->writeback) { unlock(); errno = EINVAL; return MAP_FAILED; }
    void *p = NULL;
    if (posix_memalign(&p, MAP_ALIGN, new_len)) { unlock(); errno = ENOMEM; return MAP_FAILED; }
    size_t keep = m->len < new_len ? m->len : new_len;
    memcpy(p, m->addr, keep);
    if (new_len > keep) memset((char *)p + keep, 0, new_len - keep);
    free(m->addr);
    m->addr = p; m->len = new_len;
    unlock();
    return p;
}

int mprotect(void *a, size_t n, int p) { (void)a; (void)n; (void)p; return 0; }
int madvise(void *a, size_t n, int f) { (void)a; (void)n; (void)f; return 0; }
int posix_madvise(void *a, size_t n, int f) { (void)a; (void)n; (void)f; return 0; }
int mlock(const void *a, size_t n) { (void)a; (void)n; return 0; }
int munlock(const void *a, size_t n) { (void)a; (void)n; return 0; }
int mlockall(int f) { (void)f; return 0; }
int munlockall(void) { return 0; }
