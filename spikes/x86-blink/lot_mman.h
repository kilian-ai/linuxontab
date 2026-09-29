/* lot_mman.h — sys/mman.h for Blink on wasm32 (the sysroot hides it all). */
#ifndef LOT_MMAN_H
#define LOT_MMAN_H
#include "../../sysroot/wasm_mman.h"
#define MAP_GROWSDOWN  0x0100
#define MAP_DENYWRITE  0x0800
#define MAP_EXECUTABLE 0x1000
#define MAP_LOCKED     0x2000
#define MAP_POPULATE   0x8000
#define MAP_NONBLOCK   0x10000
#define MAP_STACK      0x20000
#define MAP_HUGETLB    0x40000
#define MAP_FIXED_NOREPLACE 0x100000
#define MADV_NORMAL 0
#define MADV_RANDOM 1
#define MADV_SEQUENTIAL 2
#define MADV_WILLNEED 3
#define MADV_DONTNEED 4
#define MADV_FREE 8
#define MREMAP_MAYMOVE 1
#ifdef __cplusplus
extern "C" {
#endif
pid_t fork(void);
pid_t vfork(void);
int mprotect(void *, size_t, int);
int msync(void *, size_t, int);
int madvise(void *, size_t, int);
int posix_madvise(void *, size_t, int);
int mlock(const void *, size_t);
int munlock(const void *, size_t);
#ifdef __cplusplus
}
#endif
#endif
