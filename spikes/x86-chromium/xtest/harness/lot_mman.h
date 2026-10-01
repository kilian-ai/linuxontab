#include <sys/mman.h>
#include <unistd.h>
#define mmap lot_mmap
#define munmap lot_munmap
#define mprotect lot_mprotect
#define msync lot_msync
#define madvise lot_madvise
#define posix_madvise lot_posix_madvise
#define mlock lot_mlock
#define munlock lot_munlock
