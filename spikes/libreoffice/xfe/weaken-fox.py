#!/usr/bin/env python3
"""Make FOX's definitions of the methods Xfe overrides weak.

Xfe replaces ~60 FOX methods by defining them again in its own sources
(foxhacks.cpp, moderncontrols.cpp, ...). With a shared libFOX the
executable's definitions interpose; in a static wasm link they are
duplicate symbols (wasm-ld has no --allow-multiple-definition). Weak FOX
definitions keep FOX's code for everything else and let Xfe's strong
definitions win.
  weaken-fox.py <fox-src-dir> <xfe-src-dir>"""
import re, sys, glob
fox, xfe = sys.argv[1], sys.argv[2]
# an out-of-line definition at the start of a line, with or without a return
# type (constructors): [<type> ]FXCls::meth(
DEF = r'^(?:[A-Za-z_][\w:<>*&]*[ *&]+)*?(FX\w+)::(~?\w+)\('
pairs = set()
for path in glob.glob(xfe + '/*.cpp') + glob.glob(xfe + '/*.h'):
    pairs |= set(re.findall(DEF, open(path, encoding='latin-1').read(), re.M))
n = 0
for path in glob.glob(fox + '/*.cpp'):
    src = open(path, encoding='latin-1').read()
    out = src
    for cls, meth in pairs:
        pat = re.compile(r'^(?!__attribute__)((?:[A-Za-z_][\w:<>*&]*[ *&]+)*?' + cls + r'::' + re.escape(meth) + r'\()', re.M)
        out, k = pat.subn(r'__attribute__((weak)) \1', out)
        n += k
    if out != src:
        open(path, 'w', encoding='latin-1').write(out)
print(f"weakened {n} definitions for {len(pairs)} overridden methods")
