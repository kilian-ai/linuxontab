/*
 * sjlj_rt_wasmeh.c — setjmp/longjmp runtime for the NATIVE WASM
 * exception-handling SjLj lowering (-mllvm -wasm-enable-sjlj
 * -mexception-handling), as opposed to the emscripten JS-exception lowering
 * in sjlj_rt.c.
 *
 * WHY THIS EXISTS: the emscripten JS-exception SjLj does not compose with
 * Binaryen asyncify (used for fork). Both instrument every call site; a
 * longjmp raised as a JS exception unwinds past asyncify-instrumented frames
 * without going through asyncify's state machine, so after a fork-child's
 * asyncify rewind a re-raised longjmp is mis-dispatched (busybox ash
 * subshells fall through — see local/sched-debug/sjljfork2.c and
 * [[wasm-kernel-async-fixes]]). The wasm-EH lowering instead uses native
 * wasm try/catch/throw/rethrow: longjmp propagation is ordinary wasm control
 * flow that asyncify already understands, so the two compose.
 *
 * ABI (LLVM 19 -wasm-enable-sjlj), all runtime-provided:
 *   __wasm_setjmp(env, label, funcInvocationId)
 *       Records {funcInvocationId, label} in the first 8 bytes of the user's
 *       jmp_buf. label is the 1-based id of this setjmp site in the function;
 *       funcInvocationId is the address of a stack alloca unique to this live
 *       invocation of the function.
 *   unsigned __wasm_setjmp_test(env, funcInvocationId)
 *       Returns the recorded label iff env belongs to THIS invocation
 *       (funcInvocationId matches), else 0. Matching on funcInvocationId is
 *       what routes a longjmp to the exact setjmp that created the jmp_buf.
 *   __wasm_longjmp(env, val)
 *       Throws the __c_longjmp wasm tag carrying {env, val}. The compiler
 *       wraps every setjmp-scope function body in a try/catch(__c_longjmp);
 *       the catch reads args->env, calls __wasm_setjmp_test, and either
 *       dispatches to the matching setjmp (returning args->val) or rethrows
 *       to propagate to the next outer frame — all in wasm.
 *
 * The __c_longjmp tag is emitted by the compiler (index 1; index 0 is the C++
 * __cpp_exception tag). __builtin_wasm_throw(1, ...) references it, which is
 * why this file MUST be compiled with -mllvm -wasm-enable-sjlj (that pass is
 * what makes tag index 1 resolve to a properly-defined __c_longjmp instead of
 * a weak-undefined symbol).
 *
 * No __THREW__/__threwValue/JS imports here — unlike the emscripten path,
 * nothing crosses into JS.
 */

struct __wasm_sjlj_jb {
	void *invocation_id;
	unsigned label;
};

/* Args carried by the __c_longjmp tag; the compiler-generated catch reads
 * .env at offset 0 and .val at offset 4. Thread-local so concurrent workers
 * (each its own wasm instance/thread) don't clash. */
struct __wasm_longjmp_args {
	void *env;
	int   val;
};
static _Thread_local struct __wasm_longjmp_args __ljargs;

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

_Noreturn void __wasm_longjmp(void *env, int val)
{
	__ljargs.env = env;
	/* longjmp(env,0) must make setjmp return 1, per C. */
	__ljargs.val = val ? val : 1;
	__builtin_wasm_throw(1 /* __c_longjmp */, &__ljargs);
}
