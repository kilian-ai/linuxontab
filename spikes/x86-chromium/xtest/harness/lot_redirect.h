/* native test harness: route Blink's (not libc's) mmap family to lot_mmap.c */
#include <sys/mman.h>
#include <unistd.h>
void *lot_mmap(void *, size_t, int, int, int, off_t);
int lot_munmap(void *, size_t);
int lot_mprotect(void *, size_t, int);
int lot_msync(void *, size_t, int);
int lot_madvise(void *, size_t, int);
#define mmap lot_mmap
#define munmap lot_munmap
#define mprotect lot_mprotect
#define msync lot_msync
#define madvise lot_madvise
