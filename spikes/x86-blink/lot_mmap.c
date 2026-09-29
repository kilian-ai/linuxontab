/* lot_mmap.c — the host mmap Blink needs, on a platform with no mmap.
 *
 * Blink on a 32-bit host runs in its "nolinear" mode: every guest page lives
 * in a host page it got from mmap(MAP_ANONYMOUS) in 256 KB chunks, and guest
 * addresses are translated through a software page table. So the host only
 * has to supply (1) zeroed anonymous memory and (2) private read-only file
 * images for the ELF loader. Both come from malloc; protections are advisory.
 * MAP_FIXED requests are refused (nolinear Blink never makes them).
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <unistd.h>
#include "lot_mman.h"

/* Every mapping's base, so munmap frees only what mmap returned. Blink may
 * unmap sub-ranges or pointers it computed; those are ignored (leaked). */
static void **g_maps;
static size_t g_nmaps, g_cmaps;
static volatile int g_lock;   /* threaded Blink maps from several threads */

static void lock(void) {
  while (__atomic_exchange_n(&g_lock, 1, __ATOMIC_ACQUIRE)) sched_yield();
}
static void unlock(void) { __atomic_store_n(&g_lock, 0, __ATOMIC_RELEASE); }

static void track(void *p) {
  lock();
  if (g_nmaps == g_cmaps) {
    size_t c = g_cmaps ? g_cmaps * 2 : 256;
    void **n = realloc(g_maps, c * sizeof(*n));
    if (!n) { unlock(); return; }   /* untracked: never freed, never wrongly freed */
    g_maps = n; g_cmaps = c;
  }
  g_maps[g_nmaps++] = p;
  unlock();
}

static int untrack(void *p) {
  int found = 0;
  lock();
  for (size_t i = g_nmaps; i-- > 0;)
    if (g_maps[i] == p) { g_maps[i] = g_maps[--g_nmaps]; found = 1; break; }
  unlock();
  return found;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
  void *p = NULL;
  (void)prot;
  if (!len || (flags & MAP_FIXED)) { errno = EINVAL; return MAP_FAILED; }
  if (addr && (flags & MAP_FIXED_NOREPLACE)) { errno = EEXIST; return MAP_FAILED; }
  if (posix_memalign(&p, 4096, len)) {
    /* say so: Blink turns a failed page allocation into a guest SIGSEGV at a
     * random place, which otherwise looks like memory corruption */
    static int warned;
    if (!warned++) {
      static const char m[] = "blink: host out of memory (wasm32 heap full)\n";
      write(2, m, sizeof(m) - 1);
    }
    errno = ENOMEM;
    return MAP_FAILED;
  }
  if (flags & MAP_ANON) {
    memset(p, 0, len);
    track(p);
    return p;
  }
  /* file mapping: private copy of the file's bytes, zero-filled past EOF */
  size_t got = 0;
  while (got < len) {
    ssize_t r = pread(fd, (char *)p + got, len - got, off + got);
    if (r < 0) { if (errno == EINTR) continue; free(p); return MAP_FAILED; }
    if (r == 0) break;
    got += r;
  }
  memset((char *)p + got, 0, len - got);
  track(p);
  return p;
}

int munmap(void *addr, size_t len) {
  (void)len;
  if (addr && addr != MAP_FAILED && untrack(addr)) free(addr);
  return 0;
}

int mprotect(void *a, size_t n, int p) { (void)a; (void)n; (void)p; return 0; }
int msync(void *a, size_t n, int f) { (void)a; (void)n; (void)f; return 0; }
int madvise(void *a, size_t n, int f) { (void)a; (void)n; (void)f; return 0; }
int posix_madvise(void *a, size_t n, int f) { (void)a; (void)n; (void)f; return 0; }
int mlock(const void *a, size_t n) { (void)a; (void)n; return 0; }
int munlock(const void *a, size_t n) { (void)a; (void)n; return 0; }

/* Marker for the worker: keep this module's declared memory maximum (1 GiB,
 * see build.sh) instead of clamping it to 256 MiB like other C programs. */
__attribute__((export_name("__lot_big_memory"))) void __lot_big_memory(void) {}
