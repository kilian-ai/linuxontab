#!/usr/bin/env python3
# zsh 5.9: wasm call_indirect signature fix (same class as the glib and mc
# patches in this directory — see glib-2.56-wasm-call-indirect.py).
#
# zsh registers completion hooks with addhookfunc(), whose table holds
#     Hookfn = int (*)(Hookdef, void *)
# and every registration casts the function to (Hookfn). Two of them are
# actually ZERO-argument functions:
#
#     int accept_last(void)        -> "accept_completion"
#     int invalidate_list(void)    -> "invalidate_list"
#
# On x86/ARM the cast is harmless: the callee just ignores the extra register
# arguments. On wasm32 the arity IS the type, so runhookdef()'s call_indirect
# traps with "function signature mismatch" — which the kernel reports as a
# SIGSEGV. That killed every interactive zsh: the first ZLE widget dispatch
# runs execzlefunc -> invalidatelist() -> runhookdef(INVALIDATELISTHOOK) ->
# trap, so zsh printed its prompt and died before reading a key.
#
# Both functions are ALSO called directly (zero-arg) from complist.c and
# compresult.c, so their signatures must not change. Instead register
# exactly-typed thunks that forward to them — the same fix shape used for
# glib/mc. addhookfunc/deletehookfunc match on the pointer, so both sides
# have to name the thunk.
#
# Run from the extracted zsh source root.
import sys

PATH = 'Src/Zle/complete.c'

THUNKS = '''
/* wasm: an indirect call's signature must match EXACTLY, so a zero-argument
 * function cannot be invoked through Hookfn (Hookdef, void *) the way the
 * (Hookfn) casts below pretend. Forward through correctly-typed thunks. The
 * underlying functions stay zero-arg for their many direct callers. */

/**/
static int
accept_last_hook(UNUSED(Hookdef dummy), UNUSED(void *dat))
{
    return accept_last();
}

/**/
static int
invalidate_list_hook(UNUSED(Hookdef dummy), UNUSED(void *dat))
{
    return invalidate_list();
}
'''

ANCHOR = '''/**/
int
boot_(Module m)
{'''

SUBS = [
    ('addhookfunc("accept_completion", (Hookfn) accept_last);',
     'addhookfunc("accept_completion", accept_last_hook);'),
    ('addhookfunc("invalidate_list", (Hookfn) invalidate_list);',
     'addhookfunc("invalidate_list", invalidate_list_hook);'),
    ('deletehookfunc("accept_completion", (Hookfn) accept_last);',
     'deletehookfunc("accept_completion", accept_last_hook);'),
    ('deletehookfunc("invalidate_list", (Hookfn) invalidate_list);',
     'deletehookfunc("invalidate_list", invalidate_list_hook);'),
]

s = open(PATH).read()
if 'invalidate_list_hook' in s:
    print('already patched', PATH)
    sys.exit(0)
assert ANCHOR in s, f'anchor missing in {PATH}'
s = s.replace(ANCHOR, THUNKS + '\n' + ANCHOR, 1)
for old, new in SUBS:
    assert old in s, f'NOT FOUND {PATH}: {old}'
    s = s.replace(old, new)
open(PATH, 'w').write(s)
print('patched', PATH)
