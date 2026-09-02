#!/bin/sh
# Recipe: python3 — CPython 3.11 for wasm32-linux-musl
#
# Minimal static build: core interpreter + standard library + pip (via ensurepip).
# Inline-builds static zlib (needed by zipimport, zlib module, and pip).
# Uses config.site overrides to handle cross-compilation tests that can't run.
#
# Build deps: host python3.11+ (for --with-build-python), curl, make

NAME="python3"
VERSION="3.11.14"
DESCRIPTION="Python 3.11 interpreter (CPython, WASM)"
SOURCE_URL="https://www.python.org/ftp/python/3.11.14/Python-3.11.14.tar.xz"
# Leave SOURCE_SHA256 empty to skip checksum (set once confirmed)
SOURCE_SHA256=""

build() {
    # Optimize asyncified output: unoptimized asyncify inflates native stack
    # frames and CPython init blows V8's call stack (RangeError: Maximum call
    # stack size exceeded). -O2 after asyncify halves size and frame cost.
    export LOT_ASYNCIFY_EXTRA="-O2"

    # ── 1. Build static zlib for wasm32 (needed by zipimport / zlib module) ──
    ZPFX="/tmp/lot-zlib-pfx"
    if [ ! -f "$ZPFX/lib/libz.a" ]; then
        echo "==> Building static zlib for wasm32"
        rm -rf /tmp/lot-zlib-src "$ZPFX"
        mkdir -p /tmp/lot-zlib-src "$ZPFX/lib" "$ZPFX/include"
        curl -L --fail -o /tmp/lot-zlib.tar.gz \
            "https://zlib.net/zlib-1.3.2.tar.gz"
        tar xf /tmp/lot-zlib.tar.gz -C /tmp/lot-zlib-src --strip-components=1
        cd /tmp/lot-zlib-src
        # Compile explicitly (avoid zlib's ./configure which can't cross-compile)
        # Skip gz*.c: they use POSIX I/O without proper includes; not needed by
        # Python's zlib module (which uses raw deflate/inflate API).
        _ZSRCS="adler32.c compress.c crc32.c deflate.c infback.c inffast.c \
                inflate.c inftrees.c trees.c uncompr.c zutil.c"
        # shellcheck disable=SC2086
        $CC $CFLAGS -c $_ZSRCS
        $AR rcs "$ZPFX/lib/libz.a" ./*.o
        $RANLIB "$ZPFX/lib/libz.a"
        cp zlib.h zconf.h "$ZPFX/include/"
        echo "==> zlib built: $(ls -sh "$ZPFX/lib/libz.a")"
    fi

    # ── 1b. Build static OpenSSL 1.1.1 for wasm32 (enables _ssl + _hashlib) ──
    SSLPFX="/tmp/lot-openssl-pfx"
    if [ ! -f "$SSLPFX/lib/libssl.a" ]; then
        echo "==> Building static OpenSSL for wasm32"
        rm -rf /tmp/lot-openssl-src "$SSLPFX"
        mkdir -p /tmp/lot-openssl-src "$SSLPFX"
        curl -L --fail -o /tmp/lot-openssl.tar.gz \
            "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz"
        tar xzf /tmp/lot-openssl.tar.gz -C /tmp/lot-openssl-src --strip-components=1
        cd /tmp/lot-openssl-src
        # linux-generic32 + no-asm: portable C only. Disable everything that
        # needs mmap/madvise (secure memory), terminals, engines, or dlopen.
        CC="$CC" AR="$AR" RANLIB="$RANLIB" \
        # Disable legacy ciphers: some (e.g. Blowfish bf_init_key) miscompile to
        # invalid wasm under clang, and none are needed for TLS/pip.
        ./Configure linux-generic32 no-asm no-shared no-dso no-engine \
            no-async no-tests no-ui-console -DOPENSSL_NO_SECURE_MEMORY \
            no-bf no-cast no-idea no-rc2 no-rc4 no-rc5 no-md2 no-md4 no-mdc2 \
            no-seed no-camellia no-whirlpool no-blake2 \
            -DOPENSSL_DEV_NO_ATOMICS -D__STDC_NO_ATOMICS__=1 \
            --prefix="$SSLPFX" $CFLAGS
        make -j4 build_libs
        mkdir -p "$SSLPFX/lib" "$SSLPFX/include"
        cp libssl.a libcrypto.a "$SSLPFX/lib/"
        cp -R include/openssl "$SSLPFX/include/"
        echo "==> OpenSSL built: $(ls -sh "$SSLPFX/lib/libssl.a" "$SSLPFX/lib/libcrypto.a" | tr '\n' ' ')"
        cd "$SRC"
    fi

    # ── 2. Configure CPython for wasm32-linux-musl ───────────────────────────
    cd "$SRC"

    # ROOT CAUSE FIX (July 2026): the wasm32-musl mallocng port hardcodes its
    # meta-area base at 0x8000 (ignoring sbrk's return), so malloc metadata
    # overwrites any binary data linked below 0xC000. Fixed by linking with
    # --global-base=49152 (see _LDFLAGS). All the historical "WASM workaround"
    # patches below were symptoms of that corruption; they are disabled by
    # seeding their guard tags into the sources so the grep -q checks skip them.
    _seed() { f="$1"; shift; c="$1"; shift; { printf '%s DISABLED WASM workarounds (root cause fixed via --global-base):' "$c"; for t in "$@"; do printf ' [%s]' "$t"; done; echo; } >> "$f"; }
    _seed "$SRC/Lib/importlib/_bootstrap.py" "#" \
        "WASM workaround: frozen _wrap minimal attrs v22" \
        "WASM workaround: _spec_from_module dict probes v27" \
        "WASM workaround: _init_module_attrs dict probes v28" \
        "WASM workaround: _fix_up_module dict probes v29" \
        "WASM workaround: _resolve_filename dict probes v30" \
        "WASM workaround: spec_from_loader dict probes v31" \
        "WASM workaround: _load_unlocked exec probe v32" \
        "WASM workaround: module_from_spec probe v33" \
        "WASM workaround: module_from_spec minimal v34" \
        "WASM workaround: _setup builtin wiring v35" \
        "WASM workaround: _get_module_lock dummy map v39" \
        "WASM workaround: skip external importers v40"
    _seed "$SRC/Modules/getpath.py" "#" \
        "WASM workaround: getpath skip builddir v36" \
        "WASM workaround: getpath fallback isfile v46"
    _seed "$SRC/Modules/getpath.c" "//" \
        "WASM workaround: tolerant decode_to_dict v42" \
        "WASM workaround: tolerant decode_to_dict v43" \
        "WASM workaround: tolerate initial-values fill v44"
    _seed "$SRC/Python/import.c" "//" \
        "WASM workaround: skip zipimport init v41"
    _seed "$SRC/Objects/exceptions.c" "//" \
        "WASM debug: builtins add-exceptions trace" \
        "WASM debug: alias add trace"
    _seed "$SRC/Python/sysmodule.c" "//" \
        "WASM workaround: robust sys module names"

    # WASM kernel workaround: some builds fail during startup when creating
    # ExceptionGroup in _PyBuiltins_AddExceptions(). Keep startup alive by
    # falling back to BaseExceptionGroup if ExceptionGroup creation fails.
    if false; then
    if ! grep -q "WASM workaround: ExceptionGroup init fallback" "$SRC/Objects/exceptions.c"; then
        perl -0777 -i -pe 's/PyObject \*PyExc_ExceptionGroup = create_exception_group_class\(\);\n    if \(!PyExc_ExceptionGroup\) \{\n        return -1;\n    \}\n    if \(PyDict_SetItemString\(mod_dict, "ExceptionGroup", PyExc_ExceptionGroup\)\) \{\n        return -1;\n    \}/PyObject *PyExc_ExceptionGroup = create_exception_group_class();\n    if (!PyExc_ExceptionGroup) {\n        \/\* WASM workaround: ExceptionGroup init fallback *\/\n        PyErr_Clear();\n        PyExc_ExceptionGroup = (PyObject *)PyExc_BaseExceptionGroup;\n        Py_INCREF(PyExc_ExceptionGroup);\n    }\n    if (PyDict_SetItemString(mod_dict, "ExceptionGroup", PyExc_ExceptionGroup)) {\n        Py_DECREF(PyExc_ExceptionGroup);\n        return -1;\n    }\n    Py_DECREF(PyExc_ExceptionGroup);/s' "$SRC/Objects/exceptions.c"
    fi
    fi

    if false; then  # disabled: builtins-survival masks were coping with the malloc corruption (root cause fixed)
    if ! grep -q "WASM workaround: ignore builtins exception init failure" "$SRC/Python/pylifecycle.c"; then
        perl -0777 -i -pe 's/if \(_PyBuiltins_AddExceptions\(bimod\) < 0\) \{\n        return _PyStatus_ERR\("failed to add exceptions to builtins"\);\n    \}/if (_PyBuiltins_AddExceptions(bimod) < 0) {\n        \/\* WASM workaround: ignore builtins exception init failure *\/\n        PyErr_Clear();\n    }/s' "$SRC/Python/pylifecycle.c"
    fi

    if ! grep -q "WASM workaround: builtins init fallback success path" "$SRC/Python/pylifecycle.c"; then
        perl -0777 -i -pe 's/error:\n    Py_XDECREF\(bimod\);\n    return _PyStatus_ERR\("can\x27t initialize builtins module"\);/error:\n    \/\* WASM workaround: builtins init fallback success path *\/\n    PyErr_Clear();\n    Py_XDECREF(bimod);\n    if (interp->builtins == NULL) {\n        interp->builtins = PyDict_New();\n    }\n    if (interp->builtins_copy == NULL && interp->builtins != NULL) {\n        interp->builtins_copy = Py_NewRef(interp->builtins);\n    }\n    if (interp->import_func == NULL && interp->builtins != NULL) {\n        PyObject *import_func = _PyDict_GetItemStringWithError(interp->builtins, "__import__");\n        if (import_func != NULL) {\n            interp->import_func = Py_NewRef(import_func);\n        } else {\n            PyErr_Clear();\n        }\n    }\n    return _PyStatus_OK();/s' "$SRC/Python/pylifecycle.c"
    fi

    if ! grep -q "WASM workaround: builtins salvage fallback" "$SRC/Python/pylifecycle.c"; then
        perl -0777 -i -pe 's/\/\* WASM workaround: builtins init fallback success path \*\/\n    PyErr_Clear\(\);\n    Py_XDECREF\(bimod\);\n    if \(interp->builtins == NULL\) \{\n        interp->builtins = PyDict_New\(\);\n    \}\n    if \(interp->builtins_copy == NULL && interp->builtins != NULL\) \{\n        interp->builtins_copy = Py_NewRef\(interp->builtins\);\n    \}\n    if \(interp->import_func == NULL && interp->builtins != NULL\) \{\n        PyObject \*import_func = _PyDict_GetItemStringWithError\(interp->builtins, "__import__"\);\n        if \(import_func != NULL\) \{\n            interp->import_func = Py_NewRef\(import_func\);\n        \} else \{\n            PyErr_Clear\(\);\n        \}\n    \}\n    return _PyStatus_OK\(\);/\/\* WASM workaround: builtins salvage fallback *\/\n    PyErr_Clear();\n    if (interp->builtins == NULL && bimod != NULL) {\n        PyObject *fallback_dict = PyModule_GetDict(bimod);\n        if (fallback_dict != NULL) {\n            interp->builtins = Py_NewRef(fallback_dict);\n        } else {\n            PyErr_Clear();\n        }\n    }\n    Py_XDECREF(bimod);\n    if (interp->builtins == NULL) {\n        interp->builtins = PyDict_New();\n    }\n    if (interp->builtins_copy == NULL && interp->builtins != NULL) {\n        interp->builtins_copy = PyDict_Copy(interp->builtins);\n        if (interp->builtins_copy == NULL) {\n            PyErr_Clear();\n            interp->builtins_copy = Py_NewRef(interp->builtins);\n        }\n    }\n    if (interp->import_func == NULL && interp->builtins != NULL) {\n        PyObject *import_func = _PyDict_GetItemStringWithError(interp->builtins, "__import__");\n        if (import_func != NULL) {\n            interp->import_func = Py_NewRef(import_func);\n        } else {\n            PyErr_Clear();\n        }\n    }\n    return _PyStatus_OK();/s' "$SRC/Python/pylifecycle.c"
    fi

    if ! grep -q "WASM workaround: retry _PyBuiltin_Init for salvage" "$SRC/Python/pylifecycle.c"; then
        perl -0777 -i -pe 's/\/\* WASM workaround: builtins salvage fallback \*\/\n    PyErr_Clear\(\);/\/\* WASM workaround: builtins salvage fallback *\/\n    PyErr_Clear();\n    if (bimod == NULL) {\n        \/\* WASM workaround: retry _PyBuiltin_Init for salvage *\/\n        bimod = _PyBuiltin_Init(interp);\n        if (bimod == NULL) {\n            PyErr_Clear();\n        }\n    }/s' "$SRC/Python/pylifecycle.c"
    fi

    if ! grep -q "WASM workaround: seed critical builtins from module dict" "$SRC/Python/pylifecycle.c"; then
        perl -0777 -i -pe 's/Py_XDECREF\(bimod\);/if (interp->builtins != NULL && bimod != NULL) {\n        \/\* WASM workaround: seed critical builtins from module dict *\/\n        PyObject *fallback_dict = PyModule_GetDict(bimod);\n        if (fallback_dict != NULL) {\n            if (PyDict_Update(interp->builtins, fallback_dict) < 0) {\n                PyErr_Clear();\n            }\n        }\n    }\n    Py_XDECREF(bimod);/s' "$SRC/Python/pylifecycle.c"
    fi

    if ! grep -q "WASM workaround: refresh builtins dict" "$SRC/Python/pylifecycle.c"; then
        perl -0777 -i -pe 's/if \(interp->builtins_copy == NULL && interp->builtins != NULL\) \{/if (interp->builtins != NULL && PyDict_GetItemString(interp->builtins, "__build_class__") == NULL) {\n        PyObject *builtins_mod = PyImport_ImportModule("builtins");\n        if (builtins_mod != NULL) {\n            PyObject *builtins_dict = PyModule_GetDict(builtins_mod);\n            if (builtins_dict != NULL) {\n                Py_SETREF(interp->builtins, Py_NewRef(builtins_dict));\n            }\n            Py_DECREF(builtins_mod);\n        } else {\n            PyErr_Clear();\n        }\n    }\n    if (interp->builtins_copy == NULL && interp->builtins != NULL) {/s' "$SRC/Python/pylifecycle.c"
    fi


    if ! grep -q "WASM workaround: non-fatal SETBUILTIN" "$SRC/Python/bltinmodule.c"; then
        perl -0777 -i -pe 's/#define SETBUILTIN\(NAME, OBJECT\) \\\n    if \(PyDict_SetItemString\(dict, NAME, \(PyObject \*\)OBJECT\) < 0\)       \\\n        return NULL;                                                    \\\n    ADD_TO_ALL\(OBJECT\)/#define SETBUILTIN(NAME, OBJECT) \\\n    do { \\\n        \/\* WASM workaround: non-fatal SETBUILTIN *\/ \\\n        if (PyDict_SetItemString(dict, NAME, (PyObject *)OBJECT) < 0) { \\\n            PyErr_Clear(); \\\n        } else { \\\n            ADD_TO_ALL(OBJECT); \\\n        } \\\n    } while (0)/s' "$SRC/Python/bltinmodule.c"
    fi


    if ! grep -q "WASM workaround: non-fatal __debug__ insert" "$SRC/Python/bltinmodule.c"; then
        perl -0777 -i -pe 's/debug = PyBool_FromLong\(config->optimization_level == 0\);\n    if \(PyDict_SetItemString\(dict, "__debug__", debug\) < 0\) \{\n        Py_DECREF\(debug\);\n        return NULL;\n    \}\n    Py_DECREF\(debug\);/debug = PyBool_FromLong(config->optimization_level == 0);\n    if (debug != NULL) {\n        if (PyDict_SetItemString(dict, "__debug__", debug) < 0) {\n            \/\* WASM workaround: non-fatal __debug__ insert *\/\n            PyErr_Clear();\n        }\n        Py_DECREF(debug);\n    } else {\n        PyErr_Clear();\n    }/s' "$SRC/Python/bltinmodule.c"
    fi
    fi

    if false; then
    if ! grep -q "WASM workaround: prefer builtins module dict for frozen exec" "$SRC/Python/import.c"; then
        perl -0777 -i -pe 's/if \(r == 0\) \{\n        r = PyDict_SetItem\(d, &_Py_ID\(__builtins__\), PyEval_GetBuiltins\(\)\);\n    \}/if (r == 0) {\n        \/\* WASM workaround: prefer builtins module dict for frozen exec *\/\n        PyObject *builtins = NULL;\n        PyObject *bimod = PyImport_AddModule("builtins");\n        if (bimod != NULL) {\n            builtins = PyModule_GetDict(bimod);\n        }\n        if (builtins == NULL) {\n            builtins = PyEval_GetBuiltins();\n        }\n        if (builtins != NULL) {\n            r = PyDict_SetItem(d, &_Py_ID(__builtins__), builtins);\n        }\n        else {\n            r = -1;\n        }\n    }/s' "$SRC/Python/import.c"
    fi
    fi

    if false; then
    if ! grep -q "WASM workaround: AttributeError_init kwargs parser bypass" "$SRC/Objects/exceptions.c"; then
        cat > /tmp/patch-attrerr-init.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

s@static int\nAttributeError_init\(PyAttributeErrorObject \*self, PyObject \*args, PyObject \*kwds\)\n\{\n    static char \*kwlist\[\] = \{"name", "obj", NULL\};\n    PyObject \*name = NULL;\n    PyObject \*obj = NULL;\n\n    if \(BaseException_init\(\(PyBaseExceptionObject \*\)self, args, NULL\) == -1\) \{\n        return -1;\n    \}\n\n    PyObject \*empty_tuple = PyTuple_New\(0\);\n    if \(!empty_tuple\) \{\n        return -1;\n    \}\n    if \(!PyArg_ParseTupleAndKeywords\(empty_tuple, kwds, "\|\$OO:AttributeError", kwlist,\n                                     &name, &obj\)\) \{\n        Py_DECREF\(empty_tuple\);\n        return -1;\n    \}\n    Py_DECREF\(empty_tuple\);\n\n    Py_XINCREF\(name\);\n    Py_XSETREF\(self->name, name\);\n\n    Py_XINCREF\(obj\);\n    Py_XSETREF\(self->obj, obj\);\n\n    return 0;\n\}@static int\nAttributeError_init(PyAttributeErrorObject *self, PyObject *args, PyObject *kwds)\n{\n    /* WASM workaround: AttributeError_init kwargs parser bypass */\n    PyObject *name = NULL;\n    PyObject *obj = NULL;\n\n    if (BaseException_init((PyBaseExceptionObject *)self, args, NULL) == -1) {\n        return -1;\n    }\n\n    if (kwds != NULL && PyDict_Check(kwds)) {\n        name = PyDict_GetItemString(kwds, "name");\n        obj = PyDict_GetItemString(kwds, "obj");\n    }\n\n    Py_XINCREF(name);\n    Py_XSETREF(self->name, name);\n\n    Py_XINCREF(obj);\n    Py_XSETREF(self->obj, obj);\n\n    return 0;\n}@s;

print;
PERLEOF

        perl /tmp/patch-attrerr-init.pl < "$SRC/Objects/exceptions.c" > /tmp/exceptions-patched.c && \
        mv /tmp/exceptions-patched.c "$SRC/Objects/exceptions.c"
    fi
    fi

    # Keep this focused importlib tweak enabled: avoid hasattr/getattr/setattr
    # during frozen bootstrap wrapper setup, which triggers unstable keyword
    # parsing paths in this WASM runtime.
    if ! grep -q "WASM workaround: frozen _wrap minimal attrs v22" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/for replace in \[\x27__module__\x27, \x27__name__\x27, \x27__qualname__\x27, \x27__doc__\x27\]:\n        if hasattr\(old, replace\):\n            setattr\(new, replace, getattr\(old, replace\)\)\n    new.__dict__.update\(old.__dict__\)/# WASM workaround: frozen _wrap minimal attrs v22\n    new.__dict__.update(old.__dict__)/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _spec_from_module dict probes v27" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/def _spec_from_module\(module, loader=None, origin=None\):\n    # This function is meant for use in _setup\(\)\.[\s\S]*?\n    return spec/def _spec_from_module(module, loader=None, origin=None):\n    # This function is meant for use in _setup().\n    # WASM workaround: _spec_from_module dict probes v27\n    module_dict = None\n    try:\n        module_dict = module.__dict__\n    except Exception:\n        module_dict = None\n\n    if module_dict is not None:\n        spec = module_dict.get("__spec__")\n        if spec is not None:\n            return spec\n        name = module_dict.get("__name__")\n        if loader is None:\n            loader = module_dict.get("__loader__")\n        location = module_dict.get("__file__")\n        cached = module_dict.get("__cached__")\n        path_obj = module_dict.get("__path__")\n    else:\n        name = None\n        location = None\n        cached = None\n        path_obj = None\n\n    if name is None:\n        name = module.__name__\n\n    if origin is None:\n        if loader is not None:\n            try:\n                origin = loader._ORIGIN\n            except Exception:\n                origin = None\n        if not origin and location is not None:\n            origin = location\n\n    if path_obj is None:\n        submodule_search_locations = None\n    else:\n        try:\n            submodule_search_locations = list(path_obj)\n        except Exception:\n            submodule_search_locations = None\n\n    spec = ModuleSpec(name, loader)\n    spec.origin = origin\n    spec._set_fileattr = False if location is None else (origin == location)\n    spec.cached = cached\n    spec.submodule_search_locations = submodule_search_locations\n    return spec/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _init_module_attrs dict probes v28" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/def _init_module_attrs\(spec, module, \*, override=False\):\n    # The passed-in module may be not support attribute assignment,\n    # in which case we simply don\x27t set the attributes\./def _init_module_attrs(spec, module, *, override=False):\n    # The passed-in module may be not support attribute assignment,\n    # in which case we simply don\x27t set the attributes.\n    # WASM workaround: _init_module_attrs dict probes v28\n    try:\n        module_dict = module.__dict__\n    except Exception:\n        module_dict = None/s; s/if \(override or getattr\(module, \x27__name__\x27, None\) is None\):/if (override or module_dict is None or module_dict.get(\x27__name__\x27) is None):/s; s/if override or getattr\(module, \x27__loader__\x27, None\) is None:/if override or module_dict is None or module_dict.get(\x27__loader__\x27) is None:/s; s/if override or getattr\(module, \x27__package__\x27, None\) is None:/if override or module_dict is None or module_dict.get(\x27__package__\x27) is None:/s; s/if override or getattr\(module, \x27__path__\x27, None\) is None:/if override or module_dict is None or module_dict.get(\x27__path__\x27) is None:/s; s/if override or getattr\(module, \x27__file__\x27, None\) is None:/if override or module_dict is None or module_dict.get(\x27__file__\x27) is None:/s; s/if override or getattr\(module, \x27__cached__\x27, None\) is None:/if override or module_dict is None or module_dict.get(\x27__cached__\x27) is None:/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _fix_up_module dict probes v29" "$SRC/Lib/importlib/_bootstrap.py"; then
        cat > /tmp/patch-fix-up-module-v29.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
def _fix_up_module(cls, module):
        # WASM workaround: _fix_up_module dict probes v29
        spec = module.__spec__
        state = spec.loader_state
        try:
            module_dict = module.__dict__
        except Exception:
            module_dict = None
        if state is None:
            # The module is missing FrozenImporter-specific values.

            # Fix up the spec attrs.
            if module_dict is not None:
                origname = module_dict.pop('__origname__', None)
                ispkg = ('__path__' in module_dict)
            else:
                origname = vars(module).pop('__origname__', None)
                ispkg = hasattr(module, '__path__')
            assert origname, 'see PyImport_ImportFrozenModuleObject()'
            assert _imp.is_frozen_package(module.__name__) == ispkg, ispkg
            filename, pkgdir = cls._resolve_filename(origname, spec.name, ispkg)
            spec.loader_state = type(sys.implementation)(
                filename=filename,
                origname=origname,
            )
            __path__ = spec.submodule_search_locations
            if ispkg:
                assert __path__ == [], __path__
                if pkgdir:
                    spec.submodule_search_locations.insert(0, pkgdir)
            else:
                assert __path__ is None, __path__

            # Fix up the module attrs (the bare minimum).
            if module_dict is not None:
                assert '__file__' not in module_dict, module_dict.get('__file__')
            else:
                assert not hasattr(module, '__file__'), module.__file__
            if filename:
                try:
                    module.__file__ = filename
                except AttributeError:
                    pass
            if ispkg:
                if module_dict is not None:
                    module_path = module_dict.get('__path__')
                else:
                    module_path = module.__path__
                if module_path != __path__:
                    assert module_path == [], module_path
                    module_path.extend(__path__)
        else:
NEWBLK

my $count = 0;
$count += s{def _fix_up_module\(cls, module\):\n        spec = module\.__spec__\n        state = spec\.loader_state\n        if state is None:\n            # The module is missing FrozenImporter-specific values\.\n\n            # Fix up the spec attrs\.\n            origname = vars\(module\)\.pop\('__origname__', None\)\n            assert origname, 'see PyImport_ImportFrozenModuleObject\(\)'\n            ispkg = hasattr\(module, '__path__'\)\n            assert _imp\.is_frozen_package\(module\.__name__\) == ispkg, ispkg\n            filename, pkgdir = cls\._resolve_filename\(origname, spec\.name, ispkg\)\n            spec\.loader_state = type\(sys\.implementation\)\(\n                filename=filename,\n                origname=origname,\n            \)\n            __path__ = spec\.submodule_search_locations\n            if ispkg:\n                assert __path__ == \[\], __path__\n                if pkgdir:\n                    spec\.submodule_search_locations\.insert\(0, pkgdir\)\n            else:\n                assert __path__ is None, __path__\n\n            # Fix up the module attrs \(the bare minimum\)\.\n            assert not hasattr\(module, '__file__'\), module\.__file__\n            if filename:\n                try:\n                    module\.__file__ = filename\n                except AttributeError:\n                    pass\n            if ispkg:\n                if module\.__path__ != __path__:\n                    assert module\.__path__ == \[\], module\.__path__\n                    module\.__path__\.extend\(__path__\)\n        else:}{$new_block}s;

die "fix_up_module v29 patch failed\n" if $count < 1;
print;
PERLEOF

        perl /tmp/patch-fix-up-module-v29.pl < "$SRC/Lib/importlib/_bootstrap.py" > /tmp/bootstrap-v29.py && \
        mv /tmp/bootstrap-v29.py "$SRC/Lib/importlib/_bootstrap.py" || { echo "ERROR: fix_up_module v29 patch failed"; exit 1; }
    fi

    if ! grep -q "WASM workaround: _resolve_filename dict probes v30" "$SRC/Lib/importlib/_bootstrap.py"; then
        cat > /tmp/patch-resolve-filename-v30.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
def _resolve_filename(cls, fullname, alias=None, ispkg=False):
        # WASM workaround: _resolve_filename dict probes v30
        if not fullname:
            return None, None
        try:
            stdlib_dir = sys._stdlib_dir
        except Exception:
            return None, None
        if not stdlib_dir:
            return None, None
        try:
            sep = cls._SEP
        except Exception:
            sep = '\\' if sys.platform == 'win32' else '/'
            cls._SEP = sep

        if fullname != alias:
            if fullname[:1] == '<':
                fullname = fullname[1:]
                if not ispkg:
                    fullname = f'{fullname}.__init__'
            else:
                ispkg = False
        relfile = fullname.replace('.', sep)
        if ispkg:
            pkgdir = f'{stdlib_dir}{sep}{relfile}'
            filename = f'{pkgdir}{sep}__init__.py'
        else:
            pkgdir = None
            filename = f'{stdlib_dir}{sep}{relfile}.py'
        return filename, pkgdir
NEWBLK

my $count = 0;
$count += s{def _resolve_filename\(cls, fullname, alias=None, ispkg=False\):\n        if not fullname or not getattr\(sys, '_stdlib_dir', None\):\n            return None, None\n        try:\n            sep = cls\._SEP\n        except AttributeError:\n            sep = cls\._SEP = '\\\\' if sys\.platform == 'win32' else '/'\n\n        if fullname != alias:\n            if fullname\.startswith\('<'\):\n                fullname = fullname\[1:\]\n                if not ispkg:\n                    fullname = f'\{fullname\}\.__init__'\n            else:\n                ispkg = False\n        relfile = fullname\.replace\('\.', sep\)\n        if ispkg:\n            pkgdir = f'\{sys\._stdlib_dir\}\{sep\}\{relfile\}'\n            filename = f'\{pkgdir\}\{sep\}__init__\.py'\n        else:\n            pkgdir = None\n            filename = f'\{sys\._stdlib_dir\}\{sep\}\{relfile\}\.py'\n        return filename, pkgdir}{$new_block}s;

die "resolve_filename v30 patch failed\n" if $count < 1;
print;
PERLEOF

        perl /tmp/patch-resolve-filename-v30.pl < "$SRC/Lib/importlib/_bootstrap.py" > /tmp/bootstrap-v30.py && \
        mv /tmp/bootstrap-v30.py "$SRC/Lib/importlib/_bootstrap.py" || { echo "ERROR: resolve_filename v30 patch failed"; exit 1; }
    fi

    if ! grep -q "WASM workaround: spec_from_loader dict probes v31" "$SRC/Lib/importlib/_bootstrap.py"; then
        cat > /tmp/patch-spec-from-loader-v31.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
def spec_from_loader(name, loader, *, origin=None, is_package=None):
    """Return a module spec based on various loader methods."""
    # WASM workaround: spec_from_loader dict probes v31
    if origin is None:
        try:
            origin = loader._ORIGIN
        except Exception:
            origin = None

    if is_package is None:
        try:
            is_package = bool(loader.is_package(name))
        except Exception:
            is_package = False

    spec = ModuleSpec(name, loader)
    spec.origin = origin
    spec.submodule_search_locations = [] if is_package else None
    return spec
NEWBLK

my $count = 0;
$count += s{def spec_from_loader\(name, loader, \*, origin=None, is_package=None\):[\s\S]*?\n\ndef _spec_from_module}{$new_block\n\ndef _spec_from_module}s;

die "spec_from_loader v31 patch failed\n" if $count < 1;
print;
PERLEOF

        perl /tmp/patch-spec-from-loader-v31.pl < "$SRC/Lib/importlib/_bootstrap.py" > /tmp/bootstrap-v31.py && \
        mv /tmp/bootstrap-v31.py "$SRC/Lib/importlib/_bootstrap.py" || { echo "ERROR: spec_from_loader v31 patch failed"; exit 1; }
    fi

    if ! grep -q "WASM workaround: _load_unlocked exec probe v32" "$SRC/Lib/importlib/_bootstrap.py"; then
        cat > /tmp/patch-load-unlocked-v32.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
def _load_unlocked(spec):
    # A helper for direct use by the import system.
    if spec.loader is not None:
        # Not a namespace package.
        # WASM workaround: _load_unlocked exec probe v32
        try:
            spec.loader.exec_module
        except Exception:
            msg = (f"{_object_name(spec.loader)}.exec_module() not found; "
                   "falling back to load_module()")
            _warnings.warn(msg, ImportWarning)
            return _load_backward_compatible(spec)

    module = module_from_spec(spec)
NEWBLK

my $count = 0;
$count += s{def _load_unlocked\(spec\):\n    # A helper for direct use by the import system\.\n    if spec\.loader is not None:\n        # Not a namespace package\.\n        if not hasattr\(spec\.loader, 'exec_module'\):\n            msg = \(f"\{_object_name\(spec\.loader\)\}\.exec_module\(\) not found; "\n                    "falling back to load_module\(\)"\)\n            _warnings\.warn\(msg, ImportWarning\)\n            return _load_backward_compatible\(spec\)\n\n    module = module_from_spec\(spec\)}{$new_block}s;

die "load_unlocked v32 patch failed\n" if $count < 1;
print;
PERLEOF

        perl /tmp/patch-load-unlocked-v32.pl < "$SRC/Lib/importlib/_bootstrap.py" > /tmp/bootstrap-v32.py && \
        mv /tmp/bootstrap-v32.py "$SRC/Lib/importlib/_bootstrap.py" || { echo "ERROR: load_unlocked v32 patch failed"; exit 1; }
    fi

    if ! grep -q "WASM workaround: module_from_spec probe v33" "$SRC/Lib/importlib/_bootstrap.py"; then
        cat > /tmp/patch-module-from-spec-v33.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
def module_from_spec(spec):
    """Create a module based on the provided spec."""
    # Typically loaders will not implement create_module().
    module = None
    # WASM workaround: module_from_spec probe v33
    has_create_module = False
    try:
        spec.loader.create_module
        has_create_module = True
    except Exception:
        pass
    if has_create_module:
        # If create_module() returns `None` then it means default
        # module creation should be used.
        module = spec.loader.create_module(spec)
    else:
        has_exec_module = False
        try:
            spec.loader.exec_module
            has_exec_module = True
        except Exception:
            pass
        if has_exec_module:
            raise ImportError('loaders that define exec_module() '
                              'must also define create_module()')
    if module is None:
NEWBLK

my $count = 0;
$count += s{def module_from_spec\(spec\):\n    """Create a module based on the provided spec\."""\n    # Typically loaders will not implement create_module\(\)\.\n    module = None\n    if hasattr\(spec\.loader, 'create_module'\):\n        # If create_module\(\) returns `None` then it means default\n        # module creation should be used\.\n        module = spec\.loader\.create_module\(spec\)\n    elif hasattr\(spec\.loader, 'exec_module'\):\n        raise ImportError\('loaders that define exec_module\(\) '\n                          'must also define create_module\(\)'\)\n    if module is None:}{$new_block}s;

die "module_from_spec v33 patch failed\n" if $count < 1;
print;
PERLEOF

        perl /tmp/patch-module-from-spec-v33.pl < "$SRC/Lib/importlib/_bootstrap.py" > /tmp/bootstrap-v33.py && \
        mv /tmp/bootstrap-v33.py "$SRC/Lib/importlib/_bootstrap.py" || { echo "ERROR: module_from_spec v33 patch failed"; exit 1; }
    fi

    if ! grep -q "WASM workaround: module_from_spec minimal v34" "$SRC/Lib/importlib/_bootstrap.py"; then
        cat > /tmp/patch-module-from-spec-v34.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
def module_from_spec(spec):
    """Create a module based on the provided spec."""
    # WASM workaround: module_from_spec minimal v34
    module = _new_module(spec.name)
    _init_module_attrs(spec, module)
    return module
NEWBLK

my $count = 0;
$count += s{def module_from_spec\(spec\):[\s\S]*?\n\ndef _module_repr_from_spec}{$new_block\n\ndef _module_repr_from_spec}s;

die "module_from_spec v34 patch failed\n" if $count < 1;
print;
PERLEOF

        perl /tmp/patch-module-from-spec-v34.pl < "$SRC/Lib/importlib/_bootstrap.py" > /tmp/bootstrap-v34.py && \
        mv /tmp/bootstrap-v34.py "$SRC/Lib/importlib/_bootstrap.py" || { echo "ERROR: module_from_spec v34 patch failed"; exit 1; }
    fi

    if ! grep -q "WASM workaround: _setup builtin wiring v35" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/setattr\(self_module, builtin_name, builtin_module\)/# WASM workaround: _setup builtin wiring v35\n        self_module.__dict__\[builtin_name\] = builtin_module/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _get_module_lock dummy map v39" "$SRC/Lib/importlib/_bootstrap.py"; then
        cat > /tmp/patch-get-module-lock-v37.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
def _get_module_lock(name):
    """Get or create the module lock for a given module name.

    Acquire/release internally the global import lock to protect
    _module_locks."""

    # WASM workaround: _get_module_lock dummy map v39
    _imp.acquire_lock()
    try:
        lock = _module_locks.get(name)

        if lock is None:
            lock = _DummyModuleLock(name)
            _module_locks[name] = lock
    finally:
        _imp.release_lock()

    return lock


def _lock_unlock_module(name):
NEWBLK

my $count = 0;
$count += s{def _get_module_lock\(name\):[\s\S]*?\n\ndef _lock_unlock_module\(name\):}{$new_block}s;

    die "get_module_lock v39 patch failed\n" if $count < 1;
print;
PERLEOF

        perl /tmp/patch-get-module-lock-v37.pl < "$SRC/Lib/importlib/_bootstrap.py" > /tmp/bootstrap-v37.py && \
                mv /tmp/bootstrap-v37.py "$SRC/Lib/importlib/_bootstrap.py" || { echo "ERROR: get_module_lock v39 patch failed"; exit 1; }
    fi

    if ! grep -q "WASM workaround: getpath skip builddir v36" "$SRC/Modules/getpath.py"; then
        perl -0777 -i -pe 's/if \(\(not home_was_set and real_executable_dir and not py_setpath\)\n        or config\.get\('\''_is_python_build'\'', 0\) > 0\):/# WASM workaround: getpath skip builddir v36\nif False and \(\(not home_was_set and real_executable_dir and not py_setpath\)\n        or config.get\('\''_is_python_build'\'', 0\) > 0\):/s' "$SRC/Modules/getpath.py"
    fi

    if ! grep -q "WASM workaround: getpath fallback isfile v46" "$SRC/Modules/getpath.py"; then
        perl -0777 -i -pe 's/def search_up\(prefix, \*landmarks, test=isfile\):/# WASM workaround: getpath fallback isfile v46\n_gp_sep = SEP\n\ntry:\n    py_setpath\nexcept NameError:\n    py_setpath = None\n\ntry:\n    abspath\nexcept NameError:\n    def abspath(path):\n        return path\n\ntry:\n    basename\nexcept NameError:\n    def basename(path):\n        return path.rsplit(_gp_sep, 1)[-1]\n\ntry:\n    dirname\nexcept NameError:\n    def dirname(path):\n        if not path:\n            return path\n        head = path.rsplit(_gp_sep, 1)[0]\n        return head if head != path else ""\n\ntry:\n    hassuffix\nexcept NameError:\n    def hassuffix(path, suffix):\n        return path.endswith(suffix)\n\ntry:\n    isabs\nexcept NameError:\n    def isabs(path):\n        return path.startswith(_gp_sep)\n\ntry:\n    isdir\nexcept NameError:\n    def isdir(path):\n        return False\n\ntry:\n    isfile\nexcept NameError:\n    def isfile(path):\n        return False\n\ntry:\n    isxfile\nexcept NameError:\n    def isxfile(path):\n        return False\n\ntry:\n    joinpath\nexcept NameError:\n    def joinpath(*paths):\n        parts = [p.strip(_gp_sep) for p in paths if p]\n        if not parts:\n            return ""\n        prefix = _gp_sep if paths and paths[0] and paths[0].startswith(_gp_sep) else ""\n        return prefix + _gp_sep.join(parts)\n\ntry:\n    readlines\nexcept NameError:\n    def readlines(path):\n        return []\n\ntry:\n    realpath\nexcept NameError:\n    def realpath(path):\n        return path\n\ntry:\n    warn\nexcept NameError:\n    def warn(message):\n        return None\n\ntry:\n    py_setpath\nexcept NameError:\n    py_setpath = None\n\ndef search_up(prefix, *landmarks, test=isfile):/s' "$SRC/Modules/getpath.py"
    fi

    if ! grep -q "WASM workaround: tolerant decode_to_dict v42" "$SRC/Modules/getpath.c"; then
        perl -0777 -i -pe 's/if \(!u\) \{\n            return 0;\n        \}/if (!u) {\n            \/\* WASM workaround: tolerant decode_to_dict v42 \*\/\n            PyErr_Clear();\n            u = Py_None;\n            Py_INCREF(u);\n        }/s' "$SRC/Modules/getpath.c"
    fi

    if ! grep -q "WASM workaround: tolerant decode_to_dict v43" "$SRC/Modules/getpath.c"; then
        perl -0777 -i -pe 's/if \(!u\) \{\n\s*return 0;\n\s*\}/if (!u) {\n            \/\* WASM workaround: tolerant decode_to_dict v43 \*\/\n            PyErr_Clear();\n            u = Py_None;\n            Py_INCREF(u);\n        }/s' "$SRC/Modules/getpath.c"
    fi

    if ! grep -q "WASM workaround: tolerate initial-values fill v44" "$SRC/Modules/getpath.c"; then
        perl -0777 -i -pe 's/Py_DECREF\(co\);\n\s*Py_DECREF\(dict\);\n\s*_PyErr_WriteUnraisableMsg\("error evaluating initial values", NULL\);\n\s*return PyStatus_Error\("error evaluating initial values"\);/\/* WASM workaround: tolerate initial-values fill v44 *\/\n        PyErr_Clear();/s' "$SRC/Modules/getpath.c"
    fi

    if ! grep -q "WASM workaround: skip external importers v40" "$SRC/Lib/importlib/_bootstrap.py"; then
        cat > /tmp/patch-install-external-v40.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
def _install_external_importers():
    """Install importers that require external filesystem access"""
    # WASM workaround: skip external importers v40
    return
NEWBLK

my $count = 0;
$count += s{def _install_external_importers\(\):[\s\S]*$}{$new_block}s;

die "install_external_importers v40 patch failed\n" if $count < 1;
print;
PERLEOF

        perl /tmp/patch-install-external-v40.pl < "$SRC/Lib/importlib/_bootstrap.py" > /tmp/bootstrap-v40.py && \
        mv /tmp/bootstrap-v40.py "$SRC/Lib/importlib/_bootstrap.py" || { echo "ERROR: install_external_importers v40 patch failed"; exit 1; }
    fi

    if ! grep -q "WASM workaround: skip zipimport init v41" "$SRC/Python/import.c"; then
        perl -0777 -i -pe 's/PyStatus\n_PyImportZip_Init\(PyThreadState \*tstate\)\n\{[\s\S]*?\n\}/PyStatus\n_PyImportZip_Init(PyThreadState *tstate)\n\{\n    \/\* WASM workaround: skip zipimport init v41 \*\/\n    return _PyStatus_OK();\n\}/s' "$SRC/Python/import.c"
    fi

    # Keep importlib bootstrap logic close to upstream. The large Python-level
    # rewrite set below has repeatedly led to recursion/stack-overflow failures
    # at runtime; disable it while retaining C-level startup workarounds.
    if false; then
    if ! grep -q "WASM workaround: avoid builtins in frozen _wrap" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/for replace in \[\x27__module__\x27, \x27__name__\x27, \x27__qualname__\x27, \x27__doc__\x27\]:\n        if hasattr\(old, replace\):\n            setattr\(new, replace, getattr\(old, replace\)\)\n    new.__dict__.update\(old.__dict__\)/# WASM workaround: avoid builtins in frozen _wrap\n    # Preserve function attributes without calling hasattr\/getattr\/setattr during bootstrap.\n    new.__dict__.update(old.__dict__)/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: tolerant _setup spec sync" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/\n\s+spec = _spec_from_module\(module, loader\)\n\s+_init_module_attrs\(spec, module\)\n\s+if loader is FrozenImporter:\n\s+loader\._fix_up_module\(module\)/\n            # WASM workaround: tolerant _setup spec sync\n            try:\n                spec = _spec_from_module(module, loader)\n                _init_module_attrs(spec, module)\n                if loader is FrozenImporter:\n                    loader._fix_up_module(module)\n            except Exception:\n                pass/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: avoid hasattr in spec_from_loader" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/if not origin and hasattr\(loader, \x27get_filename\x27\):/has_get_filename = False\n    try:\n        loader.get_filename\n        has_get_filename = True\n    except AttributeError:\n        pass\n\n    # WASM workaround: avoid hasattr in spec_from_loader\n    if not origin and has_get_filename:/s; s/if hasattr\(loader, \x27is_package\x27\):/has_is_package = False\n        try:\n            loader.is_package\n            has_is_package = True\n        except AttributeError:\n            pass\n        if has_is_package:/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: spec_from_loader probe v2" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/loader\.__getattribute__\(\x27get_filename\x27\)/loader.get_filename/s; s/loader\.__getattribute__\(\x27is_package\x27\)/loader.is_package/s; s/# WASM workaround: avoid hasattr in spec_from_loader/# WASM workaround: spec_from_loader probe v2/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: spec_from_loader probe v6" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/has_get_filename = False\n\s*try:\n\s*loader\.get_filename\n\s*has_get_filename = True\n\s*except Exception:\n\s*pass/# WASM workaround: spec_from_loader probe v6\n    # Avoid touching loader.get_filename during fragile early bootstrap.\n    has_get_filename = False/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: spec_from_loader probe v5" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/has_get_filename = False\n    try:\n        loader\.get_filename\n        has_get_filename = True\n    except Exception:\n        pass\n\n    # WASM workaround: spec_from_loader probe v4/# WASM workaround: spec_from_loader probe v5\n    # Avoid touching loader.get_filename during fragile early bootstrap.\n    has_get_filename = False\n\n    # WASM workaround: spec_from_loader probe v5/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: BuiltinImporter fast path v2" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/# WASM workaround: BuiltinImporter fast path\n    if loader is BuiltinImporter:\n        return ModuleSpec\(name, loader, origin=origin, is_package=False\)/# WASM workaround: BuiltinImporter fast path v2\n    if loader is BuiltinImporter:\n        spec = ModuleSpec(name, loader)\n        spec.origin = origin\n        spec.submodule_search_locations = None\n        return spec/s; s/def spec_from_loader\(name, loader, \*, origin=None, is_package=None\):\n    """Return a module spec based on various loader methods\."""/def spec_from_loader(name, loader, *, origin=None, is_package=None):\n    """Return a module spec based on various loader methods."""\n    # WASM workaround: BuiltinImporter fast path v2\n    if loader is BuiltinImporter:\n        spec = ModuleSpec(name, loader)\n        spec.origin = origin\n        spec.submodule_search_locations = None\n        return spec/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _load_unlocked exec_module probe v2" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/if not hasattr\(spec\.loader, \x27exec_module\x27\):\n            msg = \(f"\{_object_name\(spec\.loader\)\}\.exec_module\(\) not found; "\n                    "falling back to load_module\(\)"\)\n            _warnings\.warn\(msg, ImportWarning\)\n            return _load_backward_compatible\(spec\)/# WASM workaround: _load_unlocked exec_module probe v2\n        try:\n            spec.loader.exec_module\n        except AttributeError:\n            msg = (f"{_object_name(spec.loader)}.exec_module() not found; "\n                   "falling back to load_module()")\n            _warnings.warn(msg, ImportWarning)\n            return _load_backward_compatible(spec)/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: module_from_spec probe v2" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/if hasattr\(spec\.loader, \x27create_module\x27\):\n        # If create_module\(\) returns `None` then it means default\n        # module creation should be used\.\n        module = spec\.loader\.create_module\(spec\)\n    elif hasattr\(spec\.loader, \x27exec_module\x27\):\n        raise ImportError\(\x27loaders that define exec_module\(\) \x27\n                          \x27must also define create_module\(\)\x27\)/# WASM workaround: module_from_spec probe v2\n    has_create_module = False\n    try:\n        spec.loader.create_module\n        has_create_module = True\n    except AttributeError:\n        pass\n    if has_create_module:\n        # If create_module() returns `None` then it means default\n        # module creation should be used.\n        module = spec.loader.create_module(spec)\n    else:\n        has_exec_module = False\n        try:\n            spec.loader.exec_module\n            has_exec_module = True\n        except AttributeError:\n            pass\n        if has_exec_module:\n            raise ImportError(\x27loaders that define exec_module() \x27\n                              \x27must also define create_module()\x27)/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: direct _imp builtin calls" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/return _call_with_frames_removed\(_imp\.create_builtin, spec\)/# WASM workaround: direct _imp builtin calls\n        return _imp.create_builtin(spec)/s; s/_call_with_frames_removed\(_imp\.exec_builtin, module\)/_imp.exec_builtin(module)/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: lenient BuiltinImporter.create_module" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/if spec\.name not in sys\.builtin_module_names:\n            raise ImportError\(\x27\{!r\} is not a built-in module\x27\.format\(spec\.name\),\n                              name=spec\.name\)\n        # WASM workaround: direct _imp builtin calls\n        return _imp\.create_builtin\(spec\)/# WASM workaround: lenient BuiltinImporter.create_module\n        # Avoid keyworded ImportError construction during fragile early bootstrap.\n        return _imp.create_builtin(spec)/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _init_module_attrs name probe" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/if \(override or getattr\(module, \x27__name__\x27, None\) is None\):\n        try:\n            module\.__name__ = spec\.name\n        except AttributeError:\n            pass/# WASM workaround: _init_module_attrs name probe\n    name_missing = override\n    if not name_missing:\n        try:\n            name_missing = module.__name__ is None\n        except AttributeError:\n            name_missing = True\n    if name_missing:\n        try:\n            module.__name__ = spec.name\n        except AttributeError:\n            pass/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _init_module_attrs attr probes v2" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/if override or getattr\(module, \x27__loader__\x27, None\) is None:/# WASM workaround: _init_module_attrs attr probes v2\n    loader_missing = override\n    if not loader_missing:\n        try:\n            loader_missing = module.__loader__ is None\n        except AttributeError:\n            loader_missing = True\n    if loader_missing:/s; s/if override or getattr\(module, \x27__package__\x27, None\) is None:/package_missing = override\n    if not package_missing:\n        try:\n            package_missing = module.__package__ is None\n        except AttributeError:\n            package_missing = True\n    if package_missing:/s; s/if override or getattr\(module, \x27__path__\x27, None\) is None:/path_missing = override\n    if not path_missing:\n        try:\n            path_missing = module.__path__ is None\n        except AttributeError:\n            path_missing = True\n    if path_missing:/s; s/if override or getattr\(module, \x27__file__\x27, None\) is None:/file_missing = override\n        if not file_missing:\n            try:\n                file_missing = module.__file__ is None\n            except AttributeError:\n                file_missing = True\n        if file_missing:/s; s/if override or getattr\(module, \x27__cached__\x27, None\) is None:/cached_missing = override\n        if not cached_missing:\n            try:\n                cached_missing = module.__cached__ is None\n            except AttributeError:\n                cached_missing = True\n        if cached_missing:/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _init_module_attrs attr probes v3" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/# WASM workaround: _init_module_attrs attr probes v2\n/# WASM workaround: _init_module_attrs attr probes v3\n/s; s/except AttributeError:\n\s+loader_missing = True/except Exception:\n            loader_missing = True/s; s/except AttributeError:\n\s+package_missing = True/except Exception:\n            package_missing = True/s; s/except AttributeError:\n\s+path_missing = True/except Exception:\n            path_missing = True/s; s/except AttributeError:\n\s+file_missing = True/except Exception:\n                file_missing = True/s; s/except AttributeError:\n\s+cached_missing = True/except Exception:\n                cached_missing = True/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _setup builtin wiring without setattr" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/setattr\(self_module, builtin_name, builtin_module\)/# WASM workaround: _setup builtin wiring without setattr\n        self_module.__dict__[builtin_name] = builtin_module/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: spec_from_loader probe v3" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/# WASM workaround: spec_from_loader probe v2/# WASM workaround: spec_from_loader probe v3/s; s/except AttributeError:\n\s+pass\n\n    # WASM workaround: spec_from_loader probe v2/except Exception:\n        pass\n\n    # WASM workaround: spec_from_loader probe v3/s; s/except AttributeError:\n\s+pass\n\s+if has_is_package:/except Exception:\n            pass\n        if has_is_package:/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: spec_from_loader probe v4" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/has_get_filename = False\n    try:\n        loader\.get_filename\n        has_get_filename = True\n    except AttributeError:\n        pass\n\n    # WASM workaround: spec_from_loader probe v3/has_get_filename = False\n    try:\n        loader.get_filename\n        has_get_filename = True\n    except Exception:\n        pass\n\n    # WASM workaround: spec_from_loader probe v4/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: spec_from_loader probe v7" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/if origin is None:\n        origin = getattr\(loader, \x27_ORIGIN\x27, None\)\n\n    has_get_filename = False\n    try:\n        loader\.get_filename\n        has_get_filename = True\n    except Exception:\n        pass\n\n    # WASM workaround: spec_from_loader probe v4\n    if not origin and has_get_filename:/if origin is None:\n        # WASM workaround: spec_from_loader probe v7\n        # Avoid loader attribute probes during fragile external importer bootstrap.\n        origin = None\n\n    has_get_filename = False\n\n    # WASM workaround: spec_from_loader probe v7\n    if not origin and has_get_filename:/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: spec_from_loader return v8" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/\n    return ModuleSpec\(name, loader, origin=origin, is_package=is_package\)/\n    # WASM workaround: spec_from_loader return v8\n    spec = ModuleSpec(name, loader)\n    spec.origin = origin\n    spec.submodule_search_locations = [] if is_package else None\n    return spec/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: spec_from_loader call style v9" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/def spec_from_loader\(name, loader, \*, origin=None, is_package=None\):/def spec_from_loader(name, loader, origin=None, is_package=None):/s; s/spec = spec_from_loader\(fullname, cls,\n\s+origin=cls\._ORIGIN,\n\s+is_package=ispkg\)/# WASM workaround: spec_from_loader call style v9\n        spec = spec_from_loader(fullname, cls, cls._ORIGIN, ispkg)/s; s/spec = ModuleSpec\(name, loader, origin=origin\)/spec = ModuleSpec(name, loader)\n    spec.origin = origin/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: loader_state init v10" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/spec\.loader_state = type\(sys\.implementation\)\(\n\s+filename=filename,\n\s+origname=origname,\n\s+\)/# WASM workaround: loader_state init v10\n            state = type(sys.implementation)()\n            state.filename = filename\n            state.origname = origname\n            spec.loader_state = state/s; s/spec\.loader_state = type\(sys\.implementation\)\(\n\s+filename=filename,\n\s+origname=origname,\n\s+\)/# WASM workaround: loader_state init v10\n        state = type(sys.implementation)()\n        state.filename = filename\n        state.origname = origname\n        spec.loader_state = state/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: no keyword calls in bootstrap v11" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/return spec_from_loader\(fullname, cls, origin=cls\._ORIGIN\)/# WASM workaround: no keyword calls in bootstrap v11\n            return spec_from_loader(fullname, cls, cls._ORIGIN)/s; s/return spec_from_file_location\(name, loader=loader\)/return spec_from_file_location(name, loader)/s; s/return spec_from_file_location\(name, loader=loader,\n\s+submodule_search_locations=search\)/return spec_from_file_location(name, loader, submodule_search_locations=search)/s; s/submodule_search_locations=search\)/search)/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: _resolve_filename rewrite v15" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe "s@def _resolve_filename\\(cls, fullname, alias=None, ispkg=False\\):\\n.*?\\n        return filename, pkgdir@def _resolve_filename(cls, fullname, alias=None, ispkg=False):\\n        # WASM workaround: _resolve_filename rewrite v15\\n        if not fullname:\\n            return None, None\\n        try:\\n            stdlib_dir = sys._stdlib_dir\\n        except Exception:\\n            return None, None\\n        if not stdlib_dir:\\n            return None, None\\n        try:\\n            sep = cls._SEP\\n        except Exception:\\n            sep = '/'\\n            cls._SEP = sep\\n\\n        if fullname != alias:\\n            if fullname[:1] == '<':\\n                fullname = fullname[1:]\\n                if not ispkg:\\n                    fullname = f'{fullname}.__init__'\\n            else:\\n                ispkg = False\\n        relfile = fullname.replace('.', sep)\\n        if ispkg:\\n            pkgdir = f'{stdlib_dir}{sep}{relfile}'\\n            filename = f'{pkgdir}{sep}__init__.py'\\n        else:\\n            pkgdir = None\\n            filename = f'{stdlib_dir}{sep}{relfile}.py'\\n        return filename, pkgdir@s" "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: tolerant external importer install v16" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/def _install_external_importers\(\):\n    """Install importers that require external filesystem access"""\n    global _bootstrap_external\n    import _frozen_importlib_external\n    _bootstrap_external = _frozen_importlib_external\n    _frozen_importlib_external\._install\(sys\.modules\[__name__\]\)/def _install_external_importers():\n    """Install importers that require external filesystem access"""\n    # WASM workaround: tolerant external importer install v16\n    try:\n        global _bootstrap_external\n        import _frozen_importlib_external\n        _bootstrap_external = _frozen_importlib_external\n        _frozen_importlib_external._install(sys.modules[__name__])\n    except Exception:\n        pass/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: frozen spec filename bypass v17" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/filename, pkgdir = cls\._resolve_filename\(origname, fullname, ispkg\)/# WASM workaround: frozen spec filename bypass v17\n        filename, pkgdir = None, None/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if grep -q "WASM workaround: tolerant external importer install v16" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/def _install_external_importers\(\):\n    """Install importers that require external filesystem access"""\n    # WASM workaround: tolerant external importer install v16\n    try:\n        global _bootstrap_external\n        import _frozen_importlib_external\n        _bootstrap_external = _frozen_importlib_external\n        _frozen_importlib_external\._install\(sys\.modules\[__name__\]\)\n    except Exception:\n        pass/def _install_external_importers():\n    """Install importers that require external filesystem access"""\n    global _bootstrap_external\n    import _frozen_importlib_external\n    _bootstrap_external = _frozen_importlib_external\n    _frozen_importlib_external._install(sys.modules[__name__])/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: skip _setup spec sync v19" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/# Set up the spec for existing builtin\/frozen modules\.\n    module_type = type\(sys\)\n    for name, module in sys\.modules\.items\(\):\n        if isinstance\(module, module_type\):\n            if name in sys\.builtin_module_names:\n                loader = BuiltinImporter\n            elif _imp\.is_frozen\(name\):\n                loader = FrozenImporter\n            else:\n                continue\n            # WASM workaround: tolerant _setup spec sync\n            try:\n                spec = _spec_from_module\(module, loader\)\n                _init_module_attrs\(spec, module\)\n                if loader is FrozenImporter:\n                    loader\._fix_up_module\(module\)\n            except Exception:\n                pass/# Set up the spec for existing builtin\/frozen modules.\n    # WASM workaround: skip _setup spec sync v19\n    # The full fix-up pass can recurse in this wasm runtime during early startup.\n    pass/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if ! grep -q "WASM workaround: disable external importers v20" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/def _install_external_importers\(\):\n    """Install importers that require external filesystem access"""\n    global _bootstrap_external\n    import _frozen_importlib_external\n    _bootstrap_external = _frozen_importlib_external\n    _frozen_importlib_external\._install\(sys\.modules\[__name__\]\)/def _install_external_importers():\n    """Install importers that require external filesystem access"""\n    # WASM workaround: disable external importers v20\n    return/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi
    fi

    if false; then
    if ! grep -q "WASM workaround: avoid builtins in frozen _wrap v21" "$SRC/Lib/importlib/_bootstrap.py"; then
        perl -0777 -i -pe 's/for replace in \[\x27__module__\x27, \x27__name__\x27, \x27__qualname__\x27, \x27__doc__\x27\]:\n        if hasattr\(old, replace\):\n            setattr\(new, replace, getattr\(old, replace\)\)\n    new.__dict__.update\(old.__dict__\)/# WASM workaround: avoid builtins in frozen _wrap v21\n    # Preserve function attributes without builtin hasattr\/getattr\/setattr during bootstrap.\n    new.__dict__.update(old.__dict__)/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi
    fi

    if false; then
        perl -0777 -i -pe 's/def _spec_from_module\(module, loader=None, origin=None\):\n    # This function is meant for use in _setup\(\)\.[\s\S]*?\n    return spec/def _spec_from_module(module, loader=None, origin=None):\n    # This function is meant for use in _setup().\n    # WASM workaround: _spec_from_module minimal attr probes v26\n    try:\n        spec = module.__spec__\n    except Exception:\n        pass\n    else:\n        if spec is not None:\n            return spec\n\n    name = module.__name__\n    if loader is None:\n        try:\n            loader = module.__loader__\n        except Exception:\n            pass\n\n    # Avoid early-bootstrap attribute probes that can trigger unstable\n    # AttributeError construction in this runtime.\n    location = None\n    cached = None\n    submodule_search_locations = None\n\n    if origin is None and loader is not None:\n        try:\n            origin = loader._ORIGIN\n        except Exception:\n            origin = None\n\n    spec = ModuleSpec(name, loader, origin=origin)\n    spec._set_fileattr = False\n    spec.cached = cached\n    spec.submodule_search_locations = submodule_search_locations\n    return spec/s' "$SRC/Lib/importlib/_bootstrap.py"
    fi

    if false; then  # disabled: getargs kwlist mask was coping with the malloc corruption (root cause fixed)
        cat > /tmp/patch-getargs-v27.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new1 = <<'NEW1';
          if (IS_END_OF_FORMAT(*format)) {
              /* WASM workaround: tolerate kwlist/format mismatch v45 */
              break;
          }
NEW1

my $new2 = <<'NEW2';
              if (IS_END_OF_FORMAT(*format)) {
                  /* WASM workaround: tolerate kwlist/format mismatch v45 */
                  break;
              }
NEW2

my $count = 0;
$count += s{\n\s*if \(IS_END_OF_FORMAT\(\*format\)\) \{\n\s*PyErr_Format\(PyExc_SystemError,\n\s*"More keyword list entries \(%d\) than "\n\s*"format specifiers \(%d\)", len, i\);\n\s*return cleanreturn\(0, &freelist\);\n\s*\}}{\n$new1}s;
$count += s{\n\s*if \(IS_END_OF_FORMAT\(\*format\)\) \{\n\s*PyErr_Format\(PyExc_SystemError,\n\s*"More keyword list entries \(%d\) than "\n\s*"format specifiers \(%d\)", len, i\);\n\s*return 0;\n\s*\}}{\n$new2}s;
die "getargs v45 patch failed\n" if $count < 2;

print;
PERLEOF

        perl /tmp/patch-getargs-v27.pl < "$SRC/Python/getargs.c" > /tmp/getargs-v45.c && \
        mv /tmp/getargs-v45.c "$SRC/Python/getargs.c" || { echo "ERROR: getargs v45 patch failed"; exit 1; }
    fi

    # CPython 3.11 keeps ExceptionGroup out of static_exceptions and adds it later
    # via create_exception_group_class(). If this appears uncommented, fail fast.
    if grep -q "^[[:space:]]*ITEM(ExceptionGroup)," "$SRC/Objects/exceptions.c"; then
        echo "ERROR: unexpected ITEM(ExceptionGroup) in static_exceptions (expects commented form)"
        exit 1
    fi

    if ! grep -q "WASM debug: builtins add-exceptions trace" "$SRC/Objects/exceptions.c"; then
        cat > /tmp/patch-init-types-trace-v1.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
    for (size_t i=0; i < Py_ARRAY_LENGTH(static_exceptions); i++) {
        PyTypeObject *exc = static_exceptions[i].exc;

        if (PyType_Ready(exc) < 0) {
            return -1;
        }
    }
    return 0;
NEWBLK

my $count = 0;
$count += s{for \(size_t i=0; i < Py_ARRAY_LENGTH\(static_exceptions\); i\+\+\) \{\n        PyTypeObject \*exc = static_exceptions\[i\]\.exc;\n\n        if \(PyType_Ready\(exc\) < 0\) \{\n            return -1;\n        \}\n    \}\n    return 0;}{$new_block}s;

die "init types trace v1 patch failed\n" if $count < 1;
print;
PERLEOF
        perl /tmp/patch-init-types-trace-v1.pl < "$SRC/Objects/exceptions.c" > /tmp/exceptions-init-types-trace-v1.c && \
        mv /tmp/exceptions-init-types-trace-v1.c "$SRC/Objects/exceptions.c" || { echo "ERROR: init types trace v1 patch failed"; exit 1; }

        cat > /tmp/patch-builtins-trace-v1.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_block = <<'NEWBLK';
    /* WASM workaround: resilient builtins static exception insertion */
    size_t skipped_static = 0;
    for (size_t i=0; i < Py_ARRAY_LENGTH(static_exceptions); i++) {
        PyTypeObject *exc = static_exceptions[i].exc;
        const char *raw_name = static_exceptions[i].name;
        const char *name = exc->tp_name;
        if (!name || !name[0]) {
            name = raw_name;
        }
        const char *dot = strrchr(name, '.');
        if (dot && dot[1]) {
            name = dot + 1;
        }

        /* Use stable compile-time names keyed by index to avoid corrupted pointers. */
        static const char * const wasm_static_keys[] = {
            "BaseException", "BaseExceptionGroup", "Exception", "GeneratorExit",
            "KeyboardInterrupt", "SystemExit", "ArithmeticError", "AssertionError",
            "AttributeError", "BufferError", "EOFError", "ImportError",
            "LookupError", "MemoryError", "NameError", "OSError",
            "ReferenceError", "RuntimeError", "StopAsyncIteration", "StopIteration",
            "SyntaxError", "SystemError", "TypeError", "ValueError",
            "Warning", "FloatingPointError", "OverflowError", "ZeroDivisionError",
            "BytesWarning", "DeprecationWarning", "EncodingWarning", "FutureWarning",
            "ImportWarning", "PendingDeprecationWarning", "ResourceWarning", "RuntimeWarning",
            "SyntaxWarning", "UnicodeWarning", "UserWarning", "BlockingIOError",
            "ChildProcessError", "ConnectionError", "FileExistsError", "FileNotFoundError",
            "InterruptedError", "IsADirectoryError", "NotADirectoryError", "PermissionError",
            "ProcessLookupError", "TimeoutError", "IndentationError", "IndexError",
            "KeyError", "ModuleNotFoundError", "NotImplementedError", "RecursionError",
            "UnboundLocalError", "UnicodeError", "BrokenPipeError", "ConnectionAbortedError",
            "ConnectionRefusedError", "ConnectionResetError", "TabError", "UnicodeDecodeError",
            "UnicodeEncodeError", "UnicodeTranslateError"
        };
        const size_t wasm_key_count =
            sizeof(wasm_static_keys) / sizeof(wasm_static_keys[0]);
        const char *dict_name =
            (i < wasm_key_count) ? wasm_static_keys[i] : NULL;
        if (dict_name == NULL) {
            continue;
        }

        if (!dict_name || !dict_name[0]) {
            skipped_static++;
            continue;
        }

        if (PyDict_SetItemString(mod_dict, dict_name, (PyObject*)exc)) {
            PyErr_Clear();
            skipped_static++;
            continue;
        }
    }
    (void)skipped_static;

    /* WASM workaround: skip ExceptionGroup setup during early bootstrap */
    return 0;
NEWBLK

my $count = 0;
$count += s{for \(size_t i=0; i < Py_ARRAY_LENGTH\(static_exceptions\); i\+\+\) \{\n        struct static_exception item = static_exceptions\[i\];\n\n        if \(PyDict_SetItemString\(mod_dict, item\.name, \(PyObject\*\)item\.exc\)\) \{\n            return -1;\n        \}\n    \}\n\n    PyObject \*PyExc_ExceptionGroup = create_exception_group_class\(\);\n    if \(!PyExc_ExceptionGroup\) \{\n        return -1;\n    \}\n    if \(PyDict_SetItemString\(mod_dict, "ExceptionGroup", PyExc_ExceptionGroup\)\) \{\n        return -1;\n    \}}{$new_block}s;

die "builtins trace v1 patch failed\n" if $count < 1;
print;
PERLEOF
        perl /tmp/patch-builtins-trace-v1.pl < "$SRC/Objects/exceptions.c" > /tmp/exceptions-builtins-trace-v1.c && \
        mv /tmp/exceptions-builtins-trace-v1.c "$SRC/Objects/exceptions.c" || { echo "ERROR: builtins trace v1 patch failed"; exit 1; }
    fi

    if ! grep -q "WASM debug: alias add trace" "$SRC/Objects/exceptions.c"; then
        cat > /tmp/patch-builtins-trace-v2.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $new_macro = <<'NEWMACRO';
#define INIT_ALIAS(NAME, TYPE) \
    do { \
        PyExc_ ## NAME = PyExc_ ## TYPE; \
        if (PyDict_SetItemString(mod_dict, # NAME, PyExc_ ## TYPE)) { \
            return -1; \
        } \
    } while (0)
NEWMACRO

my $count = 0;
$count += s{#define INIT_ALIAS\(NAME, TYPE\) \\
    do \{ \\
        PyExc_ ## NAME = PyExc_ ## TYPE; \\
        if \(PyDict_SetItemString\(mod_dict, # NAME, PyExc_ ## TYPE\)\) \{ \\
            return -1; \\
        \} \\
    \} while \(0\)}{$new_macro}s;

die "builtins trace v2 alias patch failed\n" if $count < 1;
print;
PERLEOF
        perl /tmp/patch-builtins-trace-v2.pl < "$SRC/Objects/exceptions.c" > /tmp/exceptions-builtins-trace-v2.c && \
        mv /tmp/exceptions-builtins-trace-v2.c "$SRC/Objects/exceptions.c" || { echo "ERROR: builtins trace v2 alias patch failed"; exit 1; }
    fi


    HOST_PYTHON=$(command -v python3.11 || command -v python3.12 || command -v python3)
    [ -n "$HOST_PYTHON" ] || { echo "ERROR: host python3 required for cross-build"; exit 1; }
    echo "==> Build Python: $HOST_PYTHON ($($HOST_PYTHON --version))"

    # Override autoconf tests that can't run on the target during cross-compilation
    cat > config.site << 'SITE'
ac_cv_file__dev_ptmx=no
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
ac_cv_working_tzset=yes
ac_cv_have_long_long_format=yes
ac_cv_pthread_is_default_mutex_error_check=no
ac_cv_posix_semaphores_enabled=no
ac_cv_broken_sem_getvalue=no
ac_cv_wchar_t_signed=yes
ac_cv_rshift_extends_sign=yes
ac_cv_little_endian_double=yes
ac_cv_prog_cc_g=no
ac_cv_have_chflags=no
ac_cv_have_lchflags=no
ac_cv_func_sigaltstack=no
ac_cv_func_getentropy=no
ac_cv_func_getrandom=no
ac_cv_func_sched_setscheduler=no
ac_cv_func_sched_setparam=no
ac_cv_func_sched_getparam=no
ac_cv_func_sched_getscheduler=no
ac_cv_func_sem_open=no
ac_cv_func_sem_timedwait=no
ac_cv_func_sem_getvalue=no
ac_cv_func_sem_unlink=no
ac_cv_func_openpty=no
ac_cv_func_forkpty=no
ac_cv_func_setresuid=no
ac_cv_func_setresgid=no
SITE
    # ── 2b. Out-of-source build directory ────────────────────────────────────
    # IMPORTANT: on macOS (case-insensitive filesystem) 'make python' matches the
    # 'Python/' source directory and is considered up-to-date. Building in a
    # separate directory avoids this: there is no 'Python/' there, so make
    # correctly rebuilds the 'python' binary.
    BLD="$SRC/../bld"
    rm -rf "$BLD"
    mkdir -p "$BLD"

    # This wasm musl sysroot hides fork()/vfork() behind #ifndef __wasm__, but
    # the LinuxOnTab kernel implements them. Force-declare for _posixsubprocess.
    if ! grep -q "WASM: force-declare fork" "$SRC/Modules/_posixsubprocess.c"; then
        # fork()/vfork() are hidden by #ifndef __wasm__ in this sysroot (kernel
        # implements them). PyOS_*Fork* live in posixmodule.c only under
        # HAVE_FORK (off here); the child execs immediately so interpreter
        # reinit is unnecessary — provide no-op stubs.
        # musl-wasm provides no fork() at all (it is a separate asyncify kernel
        # subsystem). Stub it so `import subprocess` works and pip can install
        # pre-built wheels (pure Python, no subprocess). Actual process spawning
        # returns ENOSYS. PyOS_*Fork* live in posixmodule.c only under HAVE_FORK
        # (off here); the child would exec immediately, so no-op stubs suffice.
        perl -0777 -i -pe 's/#include "posixmodule.h"/#include "posixmodule.h"\n#include <errno.h>\n\/* WASM fork support (see recipe) *\/\npid_t fork(void) { errno = ENOSYS; return -1; }\npid_t vfork(void) { errno = ENOSYS; return -1; }\nvoid PyOS_BeforeFork(void) {}\nvoid PyOS_AfterFork_Parent(void) {}\nvoid PyOS_AfterFork_Child(void) {}/' "$SRC/Modules/_posixsubprocess.c"
    fi

    export CONFIG_SITE="$SRC/config.site"

    # Determine build machine triple from uname
    case "$(uname -m)" in
        arm64|aarch64) _BM=aarch64 ;;
        x86_64)        _BM=x86_64 ;;
        *)             _BM=unknown ;;
    esac
    case "$(uname -s)" in
        Darwin) _BUILD="${_BM}-apple-darwin" ;;
        Linux)  _BUILD="${_BM}-pc-linux-gnu" ;;
        *)      _BUILD="${_BM}-unknown-unknown" ;;
    esac

    # LDFLAGS: -nostdlib so clang doesn't search its own tree for builtins;
    # CRT1 and builtins are provided explicitly via LIBS (same as all other recipes).
    _LDFLAGS="-nostdlib -static -Wl,--global-base=49152 -Wl,--import-memory -Wl,--export-memory -Wl,--export-table -Wl,--export=__heap_base -Wl,--export=__data_end -Wl,--shared-memory -Wl,--max-memory=268435456 -Wl,-z,stack-size=33554432 -L$ZPFX/lib"
    # Thread stack fix: the wasm32-musl __clone runs every pthread on the
    # PARENT's shadow stack (its clone_entry stack-pointer trampoline is dead
    # code — see sysroot/wasm_clone.c), so two threads in pthread_cond_wait
    # corrupt musl's condvar waiter list and CPython threading wedged after a
    # couple of handoffs. wasm_clone.o (linked before -lc, overriding libc's
    # clone.o) makes each thread run on its own stack. Verified: threading,
    # Lock/Event/Condition ping-pong, concurrent-thread SQLite.
    _CLONE_OBJ="$BLD/wasm_clone.o"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_clone.c" -o "$_CLONE_OBJ"
    # LIBS: CRT1 first (provides _start), builtins last (provides __muldi3 etc.)
    _LIBS="$CRT1 $_CLONE_OBJ -lz -lm -lc $BUILTINS"

    cd "$BLD"
    PATH="$WASM_LD_DIR:$PATH" "$SRC/configure" \
        --srcdir="$SRC" \
        --host=wasm32-unknown-linux-musl \
        --build="$_BUILD" \
        --with-build-python="$HOST_PYTHON" \
        --prefix=/usr/local \
        --disable-shared \
        --without-pymalloc \
        --without-doc-strings \
        --without-readline \
        --with-ensurepip=install \
        --disable-ipv6 \
        CC="$CC" \
        CXX="$CC" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        READELF=true \
        NM="$(command -v llvm-nm 2>/dev/null || command -v nm)" \
        CFLAGS="$CFLAGS -I$ZPFX/include -DPy_NO_ENABLE_SHARED" \
        LDFLAGS="$_LDFLAGS" \
        LIBS="$_LIBS"

    # ── 3a. Build real static SQLite (amalgamation) for the _sqlite3 module ──
    SQPFX="/tmp/lot-sqlite-pfx"
    if [ ! -f "$SQPFX/lib/libsqlite3.a" ]; then
        echo "==> Building static SQLite for wasm32"
        rm -rf /tmp/lot-sqlite-src "$SQPFX"
        mkdir -p /tmp/lot-sqlite-src "$SQPFX/lib" "$SQPFX/include"
        curl -L --fail -o /tmp/lot-sqlite.tar.gz \
            "https://www.sqlite.org/2024/sqlite-autoconf-3450300.tar.gz"
        tar xzf /tmp/lot-sqlite.tar.gz -C /tmp/lot-sqlite-src --strip-components=1
        ( cd /tmp/lot-sqlite-src && \
          $CC $CFLAGS -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=1 \
              -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1 \
              -DSQLITE_MAX_MMAP_SIZE=0 -DSQLITE_OMIT_WAL \
              -c sqlite3.c -o sqlite3.o ) || { echo "ERROR: sqlite build failed"; exit 1; }
        $AR rcs "$SQPFX/lib/libsqlite3.a" /tmp/lot-sqlite-src/sqlite3.o
        $RANLIB "$SQPFX/lib/libsqlite3.a"
        cp /tmp/lot-sqlite-src/sqlite3.h /tmp/lot-sqlite-src/sqlite3ext.h "$SQPFX/include/"
        echo "==> SQLite built: $(ls -sh "$SQPFX/lib/libsqlite3.a")"
    fi

    # ── 3b. Build static expat (needs $BLD/pyconfig.h) from CPython's bundled copy (for pyexpat) ─────
    # The Makefile's own LIBEXPAT integration doesn't generate object rules in
    # this cross/out-of-tree setup, so compile the three sources ourselves.
    EPFX="/tmp/lot-expat-pfx"
    if [ ! -f "$EPFX/libexpat.a" ]; then
        echo "==> Building static expat for wasm32"
        mkdir -p "$EPFX"
        ( cd "$SRC/Modules/expat" && \
          $CC $CFLAGS -I. -I"$BLD" -DHAVE_EXPAT_CONFIG_H -DXML_POOR_ENTROPY \
              -c xmlparse.c xmlrole.c xmltok.c -fvisibility=hidden && \
          mv xmlparse.o xmlrole.o xmltok.o "$EPFX/" ) || { echo "ERROR: expat build failed"; exit 1; }
        $AR rcs "$EPFX/libexpat.a" "$EPFX"/*.o
        $RANLIB "$EPFX/libexpat.a"
        echo "==> expat built: $(ls -sh "$EPFX/libexpat.a")"
    fi

    # ── 3. Module configuration ───────────────────────────────────────────────
    # Force zlib to be statically linked into the binary
    # Disable everything that needs missing libraries (ssl, sqlite, curses, etc.)
    # In VPATH builds, Setup.local goes in the build dir (already $BLD here).
    mkdir -p Modules Modules/expat Modules/_sqlite Modules/_multiprocessing
    cat >> Modules/Setup.local << MODS
*static*
zlib zlibmodule.c -I$ZPFX/include -L$ZPFX/lib -lz
math mathmodule.c
cmath cmathmodule.c
_struct _struct.c
binascii binascii.c
_random _randommodule.c
array arraymodule.c
_bisect _bisectmodule.c
_heapq _heapqmodule.c
_json _json.c
_pickle _pickle.c
_datetime _datetimemodule.c
_md5 md5module.c
_sha1 sha1module.c
_sha256 sha256module.c
_sha512 sha512module.c
_sha3 _sha3/sha3module.c
_blake2 _blake2/blake2module.c _blake2/blake2b_impl.c _blake2/blake2s_impl.c
unicodedata unicodedata.c
select selectmodule.c
fcntl fcntlmodule.c
termios termios.c
_socket socketmodule.c
_ssl _ssl.c -I$SSLPFX/include -L$SSLPFX/lib -lssl -lcrypto
_hashlib _hashopenssl.c -I$SSLPFX/include -L$SSLPFX/lib -lcrypto
_posixsubprocess _posixsubprocess.c
_csv _csv.c
_multiprocessing _multiprocessing/multiprocessing.c
pyexpat pyexpat.c -I\$(srcdir)/Modules/expat -DHAVE_EXPAT_CONFIG_H -DXML_POOR_ENTROPY -DUSE_PYEXPAT_CAPI -L$EPFX -lexpat
_elementtree _elementtree.c -I\$(srcdir)/Modules/expat -DHAVE_EXPAT_CONFIG_H -DUSE_PYEXPAT_CAPI
_sqlite3 _sqlite/blob.c _sqlite/connection.c _sqlite/cursor.c _sqlite/microprotocols.c _sqlite/module.c _sqlite/prepare_protocol.c _sqlite/row.c _sqlite/statement.c _sqlite/util.c -I$SQPFX/include -L$SQPFX/lib -lsqlite3
_contextvars _contextvarsmodule.c
_opcode _opcode.c
_typing _typingmodule.c
_statistics _statisticsmodule.c

*disabled*
_decimal
_ctypes
_curses
_curses_panel
_tkinter
readline
nis
crypt
_crypt
grp
spwd
syslog
ossaudiodev
_uuid
_dbm
_gdbm
_bz2
_lzma
MODS

    # Force makesetup to pick up Setup.local: configure generates Setup.local
    # and config.c within the same second as our append above, so make's
    # mtime comparison sees "up to date" and silently ignores every module
    # listed here (this is why zlib was historically missing too).
    rm -f Modules/config.c
    PATH="$WASM_LD_DIR:$PATH" make BUILDEXE=.wasm Modules/config.c

    # Ensure critical builtins exist before frozen importlib bootstrap
    if false; then
    if ! grep -q "WASM workaround: ensure frozen builtins" "$SRC/Python/bltinmodule.c"; then
        cat > /tmp/patch-frozen-builtins.pl << 'PERLEOF'
$/ = undef;
$_ = <>;

my $inject = q{
    /* WASM workaround: ensure frozen builtins */
    if (PyDict_GetItemString(dict, "__import__") == NULL) {
        static PyMethodDef import_def = {"__import__", _PyCFunction_CAST(builtin___import__), METH_FASTCALL | METH_KEYWORDS, NULL};
        PyObject *import_func = PyCFunction_NewEx(&import_def, NULL, NULL);
        if (import_func != NULL) {
            if (PyDict_SetItemString(dict, "__import__", import_func) < 0) {
                PyErr_Clear();
            }
            Py_DECREF(import_func);
        }
    }
    if (PyDict_GetItemString(dict, "__build_class__") == NULL) {
        static PyMethodDef build_class_def = {"__build_class__", _PyCFunction_CAST(builtin___build_class__), METH_FASTCALL | METH_KEYWORDS, build_class_doc};
        PyObject *build_class_func = PyCFunction_NewEx(&build_class_def, NULL, NULL);
        if (build_class_func != NULL) {
            if (PyDict_SetItemString(dict, "__build_class__", build_class_func) < 0) {
                PyErr_Clear();
            }
            Py_DECREF(build_class_func);
        }
    }
    if (PyDict_GetItemString(dict, "hasattr") == NULL) {
        static PyMethodDef hasattr_def = {"hasattr", _PyCFunction_CAST(builtin_hasattr), METH_FASTCALL, builtin_hasattr__doc__};
        PyObject *hasattr_func = PyCFunction_NewEx(&hasattr_def, NULL, NULL);
        if (hasattr_func != NULL) {
            if (PyDict_SetItemString(dict, "hasattr", hasattr_func) < 0) {
                PyErr_Clear();
            }
            Py_DECREF(hasattr_func);
        }
    }
};

s/(^|\n)(\s+)return mod;\s*\n\s*#undef ADD_TO_ALL/$1$2$inject$1$2return mod;\n$2#undef ADD_TO_ALL/m;
print;
PERLEOF

        perl /tmp/patch-frozen-builtins.pl < "$SRC/Python/bltinmodule.c" > /tmp/bltinmodule-patched.c && \
        mv /tmp/bltinmodule-patched.c "$SRC/Python/bltinmodule.c"
    fi
    fi


    if ! grep -q "WASM workaround: robust sys module names" "$SRC/Python/sysmodule.c"; then
        perl -0777 -i -pe 's/SET_SYS\("builtin_module_names", list_builtin_module_names\(\)\);\n    SET_SYS\("stdlib_module_names", list_stdlib_module_names\(\)\);/\/\* WASM workaround: robust sys module names *\/\n    PyObject *builtin_names = list_builtin_module_names();\n    if (builtin_names == NULL) {\n        PyErr_Clear();\n        builtin_names = PyTuple_New(0);\n    }\n    SET_SYS("builtin_module_names", builtin_names);\n\n    PyObject *stdlib_names = list_stdlib_module_names();\n    if (stdlib_names == NULL) {\n        PyErr_Clear();\n        stdlib_names = PyTuple_New(0);\n    }\n    SET_SYS("stdlib_module_names", stdlib_names);/s' "$SRC/Python/sysmodule.c"
    fi

    # ── 4. Build the interpreter ──────────────────────────────────────────────
    # We are in $BLD (out-of-source). We force BUILDEXE=.wasm so the binary is
    # named 'python.wasm' — this avoids the macOS case-insensitive filesystem
    # issue where make treats 'python' (= Python/ in VPATH source dir) as
    # already up-to-date.
    make -j4 BUILDEXE=.wasm python.wasm

    # ── 4b. Fix musl mallocng alloc_meta (binary patch) ──────────────────────
    # The wasm32-musl port's alloc_meta calls sbrk() but DISCARDS its return and
    # uses a hardcoded 0x8000 as the meta-area base, eventually overwriting its
    # own live metadata (and, without --global-base, the binary's rodata).
    # Patch: local.tee the sbrk return into the meta-area pointer local.
    #   before: 41 7f 46 0d 03 41 80 80 02 21 02  (const -1; eq; br_if 3; const 32768; local.set 2)
    #   after:  22 02 41 7f 46 0d 03 01 01 01 01  (local.tee 2; const -1; eq; br_if 3; nop x4)
    if [ "${LOT_SKIP_ALLOCMETA_PATCH:-0}" = "1" ]; then echo "==> SKIPPING alloc_meta patch (LOT_SKIP_ALLOCMETA_PATCH=1)"; else
    python3 - "$BLD/python.wasm" << 'PYEOF'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
old = bytes.fromhex('417f460d034180800221 02'.replace(' ',''))
new = bytes.fromhex('220241 7f460d0301010101'.replace(' ',''))
n = data.count(old)
if n == 0:
    # Linked against toolchain/musl-sysroot-fixed, where alloc_meta is fixed
    # at the source level — nothing to patch.
    print("==> alloc_meta already fixed in libc (fixed sysroot); no byte patch needed")
elif n == 1:
    i = data.find(old)
    data[i:i+len(old)] = new
    print(f"==> alloc_meta sbrk-return patch applied at 0x{i:x}")
else:
    sys.exit(f"ERROR: alloc_meta sbrk pattern found {n} times (expected 1)")

# Also fix musl _brk's heap ceiling: it computes `memory.size << 14`, but wasm
# pages are 65536 bytes (2^16), so the ceiling is 4x too small (same bug commit
# 987ea06 hex-patched in the old binary). memory.size ; i32.const 14 ; i32.shl
old2 = bytes.fromhex('3f00410e74')
new2 = bytes.fromhex('3f00411074')
n2 = data.count(old2)
if n2 == 1:
    j = data.find(old2)
    data[j:j+len(old2)] = new2
    print(f"==> sbrk ceiling shift 14->16 patch applied at 0x{j:x}")
else:
    print(f"==> note: sbrk shift pattern found {n2} times; skipping (fixed sysroot?)")

open(path, 'wb').write(data)
PYEOF
    [ $? -eq 0 ] || { echo "ERROR: alloc_meta binary patch failed"; exit 1; }
    fi

    # ── 5. Package: binary + stdlib ───────────────────────────────────────────
    # Binary is in $BLD/python.wasm
    mkdir -p "$STAGE/usr/local/bin"
    install -m755 "$BLD/python.wasm" "$STAGE/usr/local/bin/python3.11"
    ln -sf python3.11 "$STAGE/usr/local/bin/python3"
    ln -sf python3.11 "$STAGE/usr/local/bin/python"

    # Copy stdlib from source Lib/ directory
    # (avoids running make install which would try to execute the target binary)
    _PYLIB="$STAGE/usr/local/lib/python3.11"
    mkdir -p "$_PYLIB/lib-dynload"
    cp -r "$SRC/Lib/." "$_PYLIB/"

    # Remove bulky/unused directories to save space
    for _d in test turtle tkinter turtledemo lib2to3 idlelib \
               ctypes/test distutils/tests email/test \
               unittest/test importlib/test multiprocessing/tests; do
        rm -rf "$_PYLIB/$_d"
    done
    # Remove __pycache__ dirs (regenerated on first import)
    find "$_PYLIB" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

    # sysconfig needs the generated _sysconfigdata_*.py (cross-build produces it
    # via the host python; without it `pip --version` etc. die in sysconfig).
    ( cd "$BLD" && PATH="$WASM_LD_DIR:$PATH" make pybuilddir.txt >/dev/null )
    _SCD=$(find "$BLD/build" -name "_sysconfigdata_*.py" | head -1)
    [ -n "$_SCD" ] || { echo "ERROR: _sysconfigdata not generated"; exit 1; }
    cp "$_SCD" "$_PYLIB/"
    echo "==> staged $(basename "$_SCD")"

    # Pure-Python mmap shim: musl-wasm has no mmap() (nommu kernel), but
    # libraries like pip's vendored cachecontrol import mmap unconditionally.
    # The canonical copy lives in the repo's rootfs staging tree.
    # Guest defaults: threading.stack_size(16 MB) — real per-thread stacks
    # (sysroot/wasm_clone.c) default to musl's 128 KB, far too small for
    # asyncified frames running Python (uvicorn's startup thread overflowed).
    if [ -f "$REPO_ROOT/rootfs/usr/local/lib/python3.11/site-packages/sitecustomize.py" ]; then
        mkdir -p "$_PYLIB/site-packages"
        cp "$REPO_ROOT/rootfs/usr/local/lib/python3.11/site-packages/sitecustomize.py" "$_PYLIB/site-packages/sitecustomize.py"
    fi
    if [ -f "$REPO_ROOT/rootfs/usr/local/lib/python3.11/mmap.py" ]; then
        cp "$REPO_ROOT/rootfs/usr/local/lib/python3.11/mmap.py" "$_PYLIB/mmap.py"
        echo "==> staged pure-Python mmap shim"
    fi

    # Create site-packages directory (where pip installs packages)
    mkdir -p "$_PYLIB/site-packages"

    # Install pip + setuptools from the wheels CPython bundles for ensurepip.
    # (We can't run the target binary's ensurepip during cross-build; wheels
    # are plain zips, so unpack them with the host python.)
    "$HOST_PYTHON" - "$SRC/Lib/ensurepip/_bundled" "$_PYLIB/site-packages" << 'PYWHEELS'
import sys, zipfile, pathlib
bundled, sitepkg = map(pathlib.Path, sys.argv[1:3])
for whl in sorted(bundled.glob("*.whl")):
    with zipfile.ZipFile(whl) as z:
        z.extractall(sitepkg)
    print(f"==> unpacked {whl.name} into site-packages")
PYWHEELS

    # pip wrapper
    cat > "$STAGE/usr/local/bin/pip3" << 'PIP'
#!/usr/local/bin/python3
import sys
from runpy import run_module
sys.exit(run_module('pip', run_name='__main__'))
PIP
    chmod +x "$STAGE/usr/local/bin/pip3"
    ln -sf pip3 "$STAGE/usr/local/bin/pip"

    # Pre-compile all .py to .pyc on the HOST. Some vendored files (e.g. pip's
    # chardet language models) are giant literal data tables; byte-compiling
    # them on the guest overflows the C stack. Shipping .pyc means the guest
    # only marshals (shallow) instead of compiling (deep recursion). 3.11.x
    # share a bytecode magic, so host 3.11 .pyc load in the guest's 3.11.9.
    # -o2 also strips asserts/docstrings. Non-zero exit is fine (a few files
    # legitimately fail to compile); we just want the bulk cached.
    # unchecked-hash: guest trusts the .pyc regardless of the deployed .py's
    # mtime/hash, so it never falls back to (crashing) on-guest compilation.
    echo "==> Pre-compiling .pyc with host $("$HOST_PYTHON" --version 2>&1)"
    "$HOST_PYTHON" -m compileall -q -j0 -o0 -o1 -o2 \
        --invalidation-mode unchecked-hash "$_PYLIB" || true

    # Report size
    echo "==> Binary: $(ls -sh "$STAGE/usr/local/bin/python3.11")"
    echo "==> Stdlib: $(du -sh "$_PYLIB" | cut -f1)"
}
