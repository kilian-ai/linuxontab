/* wasm_mman.h — the sys/mman.h pieces the wasm32 sysroot hides.
 *
 * musl's sys/mman.h wraps every PROT_ and MAP_ constant and the mmap/munmap
 * prototypes in #ifndef __wasm__, leaving only MAP_FAILED. Ports that keep
 * their mmap calls (nginx ngx_shmem.c, APR apr_shm.c) get the Linux values
 * back from here; the implementation is sysroot/wasm_mmap_anon.c.
 * Use with:  -include $REPO_ROOT/sysroot/wasm_mman.h
 */
#ifndef LOT_WASM_MMAN_H
#define LOT_WASM_MMAN_H
#include <sys/types.h>

#define PROT_NONE      0
#define PROT_READ      1
#define PROT_WRITE     2
#define PROT_EXEC      4

#define MAP_SHARED     0x01
#define MAP_PRIVATE    0x02
#define MAP_FIXED      0x10
#define MAP_ANON       0x20
#define MAP_ANONYMOUS  MAP_ANON
#define MAP_NORESERVE  0x4000

#define MS_ASYNC       1
#define MS_INVALIDATE  2
#define MS_SYNC        4

#ifndef MAP_FAILED
#define MAP_FAILED ((void *) -1)
#endif

#ifdef __cplusplus
extern "C" {
#endif
void *mmap(void *, size_t, int, int, int, off_t);
int munmap(void *, size_t);
#ifdef __cplusplus
}
#endif

#endif
