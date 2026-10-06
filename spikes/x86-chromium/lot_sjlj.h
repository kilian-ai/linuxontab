/* lot_sjlj.h: sigsetjmp/siglongjmp for Blink on the wasm guest.
 *
 * The sysroot's musl longjmp is a trapping stub, so Blink's HaltMachine
 * (siglongjmp(m->onhalt) after it has queued a guest fault) used to hit
 * `unreachable`: a faulting x86 program killed Blink instead of reaching its
 * SIGSEGV handler. Blink is now compiled with the native wasm exception
 * handling SjLj lowering (-mexception-handling -mllvm -wasm-enable-sjlj,
 * runtime sysroot/sjlj_rt_wasmeh.c), which composes with asyncify. That pass
 * only rewrites setjmp/longjmp, so the sig* variants map onto them here, with
 * the signal mask saved in the jmp_buf's own __fl/__ss fields.
 *
 * -included into every Blink translation unit (after lot_mman.h). */
#ifndef LOT_SJLJ_H
#define LOT_SJLJ_H
#include <setjmp.h>
#include <signal.h>

static inline void lot_sigsave_(struct __jmp_buf_tag *b, int save) {
  b->__fl = save;
  if (save) pthread_sigmask(SIG_BLOCK, 0, (sigset_t *)b->__ss);
}
static inline void lot_sigrestore_(struct __jmp_buf_tag *b) {
  if (b->__fl) pthread_sigmask(SIG_SETMASK, (sigset_t *)b->__ss, 0);
}

#undef sigsetjmp
#undef siglongjmp
#define sigsetjmp(b, s) (lot_sigsave_((b), (s)), setjmp(b))
#define siglongjmp(b, v) (lot_sigrestore_(b), longjmp((b), (v)))
#endif
