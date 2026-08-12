/*
 * sjlj_rt.c — Emscripten-sjlj runtime for wasm32-unknown-unknown + musl
 *
 * Required when building with: -mllvm --enable-emscripten-sjlj
 *
 * The LLVM emscripten-sjlj pass transforms every call inside a setjmp scope
 * into a call via invoke_*(fn_idx, ...), and transforms longjmp() into a
 * call to emscripten_longjmp(buf, val).
 *
 * Responsibilities split between WASM (this file) and JS (worker.js):
 *
 *   WASM (here):
 *     __THREW__           — TLS int at __tls_base+0: set to jmp_buf ptr on longjmp
 *     __threwValue        — TLS int at __tls_base+4: longjmp value
 *     __sjlj_set_threw    — EXPORTED setter so JS can write the two TLS slots
 *                           without knowing the TLS base (link with
 *                           -Wl,--export=__sjlj_set_threw)
 *     __wasm_setjmp       — records {invocation_id, label} in the jmp_buf
 *     __wasm_setjmp_test  — returns the recorded label iff the longjmp'd
 *                           jmp_buf belongs to THIS function invocation
 *     setTempRet0/getTempRet0 — side-channel used by the generated code
 *
 *   JS imports from "env" (provided by worker.js):
 *     emscripten_longjmp(buf, val) — records via __sjlj_set_threw, throws a
 *                                    JS sentinel that invoke_* catches
 *     invoke_*(fn_idx, ...)        — table call wrapped in try/catch
 *
 * ABI (LLVM 17+ "new" SjLj lowering, verified against LLVM 19 codegen):
 *   setjmp site:   __wasm_setjmp(env, label, func_invocation_id)
 *     env                = the user's jmp_buf pointer
 *     label              = 1-based id of this setjmp site within the function
 *     func_invocation_id = address of a stack alloca unique to this live
 *                          function invocation
 *   landing pad:   label = __wasm_setjmp_test(threw_env, func_invocation_id)
 *     Returns the label to dispatch to, or 0 if the longjmp targets some
 *     OTHER frame (the pad then rethrows to propagate further up).
 *
 * The {invocation_id, label} pair lives in the first 8 bytes of the user's
 * jmp_buf (musl's wasm32 jmp_buf is 6x u64 — plenty). Matching on
 * invocation_id is what routes a longjmp past inner frames to the exact
 * setjmp that created the jmp_buf; the previous stub returned "1" for any
 * registered frame, so the innermost setjmp caught every longjmp and
 * multi-frame consumers (busybox ash) spun forever.
 */

struct __wasm_sjlj_jb {
	void *invocation_id;
	unsigned label;
};

/* __THREW__ and __threwValue live at tls_base+0 and tls_base+4 */
_Thread_local int __THREW__ = 0;
_Thread_local int __threwValue = 0;

/* Exported: lets JS record a longjmp without computing the TLS base. */
void __sjlj_set_threw(int buf, int val)
{
	__THREW__ = buf;
	__threwValue = val;
}

void __wasm_setjmp(void *env, unsigned label, void *func_invocation_id)
{
	struct __wasm_sjlj_jb *jb = env;
	jb->invocation_id = func_invocation_id;
	jb->label = label;
}

unsigned __wasm_setjmp_test(void *env, void *func_invocation_id)
{
	struct __wasm_sjlj_jb *jb = env;
	return (jb->invocation_id == func_invocation_id) ? jb->label : 0;
}

/* Side-channel for returning the longjmp value (second return value) */
static _Thread_local int __tempRet0 = 0;
void setTempRet0(int v) { __tempRet0 = v; }
int  getTempRet0(void)  { return __tempRet0; }
