# Build rules + sources for Linux on wasm32 beyond configure.ac (run in the
# container from the source root): python3 /lot/spike/edit-tree.py
import shutil
R='/work/libreoffice-26.8.1.1/'
def edit(path, pairs):
    s=open(R+path).read()
    for old,new in pairs:
        if new in s: continue                   # already applied
        assert old in s, (path, old[:70])
        s=s.replace(old,new,1)
    open(R+path,'w').write(s)

# UNO C++ bridge: the wasm one, for CPUNAME=WASM32 too
edit('bridges/Library_cpp_uno.mk', [("""else ifeq ($(CPUNAME),M68K)
""","""else ifeq ($(CPUNAME),WASM32)

# Linux on wasm32 (LinuxOnTab): the Emscripten wasm bridge, with RTTI found
# through a generated table instead of JavaScript (see make-rtti-table.sh)
bridges_SELECTED_BRIDGE := gcc3_wasm
bridge_exception_objects := abi cpp2uno uno2cpp
$(eval $(call gb_Library_add_generated_asmobjects,$(CPPU_ENV)_uno, \\
    CustomTarget/bridges/gcc3_wasm/generated-asm \\
))
$(eval $(call gb_Library_add_generated_exception_objects,$(CPPU_ENV)_uno, \\
    CustomTarget/bridges/gcc3_wasm/generated-cxx \\
    CustomTarget/bridges/gcc3_wasm/rtti-table \\
))
$(eval $(call gb_Library_use_static_libraries,$(CPPU_ENV)_uno, \\
    emscriptencxxabi \\
))

else ifeq ($(CPUNAME),M68K)
""")])
edit('bridges/Module_bridges.mk', [("""	$(if $(filter EMSCRIPTEN,$(OS)), \\
	    CustomTarget_gcc3_wasm \\""","""	$(if $(or $(filter EMSCRIPTEN,$(OS)),$(filter WASM32,$(CPUNAME))), \\
	    CustomTarget_gcc3_wasm \\""")])
edit('bridges/CustomTarget_gcc3_wasm.mk', [("""    exports \\
))
""","""    exports \\
    rtti-table.cxx \\
))

$(gb_CustomTarget_workdir)/bridges/gcc3_wasm/rtti-table.cxx: \\
        $(gb_CustomTarget_workdir)/bridges/gcc3_wasm/exports \\
        $(SRCDIR)/bridges/source/cpp_uno/gcc3_wasm/make-rtti-table.sh
	sh $(SRCDIR)/bridges/source/cpp_uno/gcc3_wasm/make-rtti-table.sh $< > $@
""")])
shutil.copy('/lot/spike/make-rtti-table.sh', R+'bridges/source/cpp_uno/gcc3_wasm/make-rtti-table.sh')
edit('bridges/source/cpp_uno/gcc3_wasm/cpp2uno.cxx', [
("""#include <emscripten.h>
""","""#if defined __EMSCRIPTEN__
#include <emscripten.h>
#endif
"""),
("""EM_JS(void*, jsGetExportedSymbol, (char const* name),""","""#if !defined __EMSCRIPTEN__
// Linux on wasm32: a table generated from wasmbridgegen's exports list
extern "C" void* lo_wasm_getExportedSymbol(char const* name);
static void* jsGetExportedSymbol(char const* name) { return lo_wasm_getExportedSymbol(name); }
#else
EM_JS(void*, jsGetExportedSymbol, (char const* name),"""),
("""      // clang-format on
);
""","""      // clang-format on
);
#endif
""")])

# build side: wasmbridgegen is needed for this host as well
edit('static/Module_static.mk', [("""ifneq ($(filter EMSCRIPTEN,$(BUILD_TYPE_FOR_HOST)),)""","""ifneq ($(filter EMSCRIPTEN WASM32_LINUX,$(BUILD_TYPE_FOR_HOST)),)""")])
edit('Repository.mk', [("""	$(if $(or $(filter EMSCRIPTEN,$(BUILD_TYPE_FOR_HOST)),$(filter EMSCRIPTEN,$(OS))),embindmaker wasmbridgegen) \\""","""	$(if $(or $(filter EMSCRIPTEN WASM32_LINUX,$(BUILD_TYPE_FOR_HOST)),$(filter EMSCRIPTEN,$(OS)),$(filter WASM32,$(CPUNAME))),embindmaker wasmbridgegen) \\""")])
edit('RepositoryModule_build.mk', [("""	$(if $(filter EMSCRIPTEN,$(BUILD_TYPE_FOR_HOST)),static) \\""","""	$(if $(filter EMSCRIPTEN WASM32_LINUX,$(BUILD_TYPE_FOR_HOST)),static) \\""")])
edit('solenv/gbuild/extensions/pre_BuildTools.mk', [("""		$(if $(filter EMSCRIPTEN,$(BUILD_TYPE_FOR_HOST)),embindmaker wasmbridgegen) \\""","""		$(if $(filter EMSCRIPTEN WASM32_LINUX,$(BUILD_TYPE_FOR_HOST)),embindmaker wasmbridgegen) \\""")])
# OpenSSL: wasm32 falls through to linux-generic32; no command-line apps (they
# fork), no assembly, no mlock'ed secure heap
edit('external/openssl/ExternalProject_openssl.mk', [("""        $(if $(filter TRUE, $(ENABLE_DBGUTIL)), debug-linux-generic32, linux-generic32)\\
""","""        $(if $(filter TRUE, $(ENABLE_DBGUTIL)), debug-linux-generic32, linux-generic32)\\
        $(if $(filter WASM32,$(CPUNAME)), no-apps no-asm no-secure-memory no-afalgeng)\\
""")])
# ICU: genccode emits x86/ELF assembly for every *-linux* host; on wasm32
# let it write C (as for Emscripten)
shutil.copy('/lot/spike/icu4c-wasm32-linux.patch.1', R+'external/icu/icu4c-wasm32-linux.patch.1')
edit('external/icu/UnpackedTarball_icu.mk', [("""	external/icu/icu4c-use-pkgdata-single-ccode-file-mode.patch.1 \\
""","""	external/icu/icu4c-use-pkgdata-single-ccode-file-mode.patch.1 \\
	external/icu/icu4c-wasm32-linux.patch.1 \\
""")])
# Bundled libraries: wasm32 has no shared libraries, so every place that asks
# for a shared-only build on Linux builds static instead (other platforms
# unchanged)
import glob, re
WASM_STATIC = '$(if $(filter WASM32,$(CPUNAME)),--disable-shared --enable-static,--disable-static)'
for mk in glob.glob(R + 'external/*/ExternalProject_*.mk'):
    t = open(mk).read()
    if WASM_STATIC in t: continue
    t2 = re.sub(r'(?<![\w-])--disable-static(?![\w-])', WASM_STATIC.replace('\\', '\\\\'), t)
    if t2 != t: open(mk, 'w').write(t2)
# fontconfig: its va_copy probe runs a test program; musl has C99 va_copy
edit('external/fontconfig/ExternalProject_fontconfig.mk', [("""			$(if $(filter EMSCRIPTEN,$(OS)), \\
				--disable-shared \\""","""			$(if $(filter WASM32,$(CPUNAME)),ac_cv_va_copy=C99) \\
			$(if $(filter EMSCRIPTEN,$(OS)), \\
				--disable-shared \\""")])
# sal: wasm32 musl hides fork(); the link provides one that fails with ENOSYS
# (LibreOffice is not asyncified, so a real fork is not possible)
edit('sal/osl/unx/process.cxx', [("""#include <sal/config.h>
""","""#include <sal/config.h>
#if defined __wasm__
#include <sys/types.h>
extern "C" pid_t fork(void);   // wasm32: fails with ENOSYS (no asyncify)
#endif
""")])
# bridges: the double-mmap'ed (write + exec views) vtable code area is an
# ELF/MMU thing; the wasm bridge has no generated code and implements the
# single-view addLocalFunctions
edit('bridges/inc/vtablefactory.hxx', [("""    || defined(HAIKU)
#define USE_DOUBLE_MMAP""","""    || defined(HAIKU)
#if !defined __wasm__
#define USE_DOUBLE_MMAP
#endif""")])
print("tree: ok")
