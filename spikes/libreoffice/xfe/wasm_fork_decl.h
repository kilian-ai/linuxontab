/* Force-included into Xfe: wasm32 musl hides fork(), but the guest kernel
 * provides it through asyncify (sysroot/wasm_fork.c, linked in; the binary
 * is asyncified after the link). */
#include <sys/types.h>
#ifdef __cplusplus
extern "C"
#endif
pid_t fork(void);
