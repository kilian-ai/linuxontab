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
 *     __THREW__         — TLS int at __tls_base+0: set to jmp_buf ptr by longjmp
 *     __threwValue      — TLS int at __tls_base+4: longjmp value
 *     __wasm_setjmp     — registers a setjmp frame in the table
 *     __wasm_setjmp_test — checks if __THREW__ matches our registered setjmp
 *     setTempRet0 / getTempRet0 — side-channel for returning longjmp val
 *
 *   JS imports from "env" (must be provided by worker.js):
 *     emscripten_longjmp(buf, val) — writes TLS, throws JS exception
 *     invoke_v(fn)                 — void fn()    wrapped in try/catch
 *     invoke_vi(fn, a0)            — void fn(i32)
 *     invoke_vii(fn, a0, a1)       — void fn(i32, i32)
 *     invoke_viii(fn, a0, a1, a2)  — void fn(i32, i32, i32)
 *     invoke_viiii(...)            — void fn(i32 x4)
 *     invoke_i(fn)                 — i32 fn()
 *     invoke_ii(fn, a0)            — i32 fn(i32)
 *     invoke_iii(fn, a0, a1)       — i32 fn(i32, i32)
 *     invoke_iiii(fn, a0, a1, a2)  — i32 fn(i32, i32, i32)
 *     invoke_iiiii(...)            — i32 fn(i32 x4)
 */

/* __THREW__ and __threwValue live at tls_base+0 and tls_base+4 */
_Thread_local int __THREW__ = 0;
_Thread_local int __threwValue = 0;

/*
 * __wasm_setjmp(env, id, table)
 *   env   = jmp_buf pointer (not used here; setjmp ID is what matters)
 *   id    = unique integer id for this setjmp call site (assigned by LLVM)
 *   table = pointer to an i32 slot in the current stack frame
 *
 * We store id in *table so __wasm_setjmp_test can match it later.
 */
void __wasm_setjmp(void *env, int id, int *table) {
    (void)env;
    *table = id;
}

/*
 * __wasm_setjmp_test(threw_val, table)
 *   threw_val = current value of __THREW__ (= jmp_buf address that was passed
 *               to emscripten_longjmp; the LLVM transform passes the whole
 *               __THREW__ TLS value here, not the jmp_buf id)
 *   table     = the setjmp table slot for this frame (set by __wasm_setjmp)
 *
 * Returns non-zero if this setjmp frame matches the longjmp target,
 * i.e. if *table != 0 (frame was registered) AND we are the right target.
 *
 * The LLVM transform compares (threw_val == jmp_buf address of this frame).
 * Since each jmp_buf is at a unique address, matching threw_val to the address
 * of jb passed to setjmp identifies the right setjmp frame.
 * *table is non-zero iff this setjmp was reached (registered) — if it is 0
 * then we were never setjmp'd and should not catch the longjmp.
 */
int __wasm_setjmp_test(int threw_val, int *table) {
    return *table != 0 && threw_val != 0 ? 1 : 0;
}

/* Side-channel for returning the longjmp value (second return value) */
static _Thread_local int __tempRet0 = 0;
void setTempRet0(int v) { __tempRet0 = v; }
int  getTempRet0(void)  { return __tempRet0; }
