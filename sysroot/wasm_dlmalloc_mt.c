/* wasm_dlmalloc_mt.c — sysroot/wasm_dlmalloc.c with locking, for ports that
 * run threads (pthreads, or anything calling clone(CLONE_VM)). Link it in
 * place of wasm_dlmalloc.c, never both. */
#define LOT_DLMALLOC_THREADS 1
#include "wasm_dlmalloc.c"
