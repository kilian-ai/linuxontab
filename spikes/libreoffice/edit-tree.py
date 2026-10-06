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
# ICU: the build-side pkgdata (native Linux, ELF support compiled in) would
# write the Unicode data straight into an ELF object (genccode --match-arch);
# for wasm32 make it write C (-w = without assembly) for our compiler
edit('external/icu/ExternalProject_icu.mk', [("""		&& $(MAKE) $(if $(CROSS_COMPILING),DATASUBDIR=data) $(if $(verbose),VERBOSE=1) \\
		$(if $(filter MACOSX,$(OS)), \\""","""		&& $(MAKE) $(if $(CROSS_COMPILING),DATASUBDIR=data) $(if $(verbose),VERBOSE=1) \\
			$(if $(filter WASM32,$(CPUNAME)),'PKGDATA_OPTS=-O $$(top_builddir)/data/icupkg.inc -w') \\
		$(if $(filter MACOSX,$(OS)), \\""")])
# Calc: wasm has no floating-point exception flags (like Emscripten, which
# this already skips)
edit('sc/source/core/tool/math.cxx', [("""#ifndef __EMSCRIPTEN__
        || (((math_errhandling & MATH_ERREXCEPT) != 0)""","""#if !defined __EMSCRIPTEN__ && !defined __wasm__
        || (((math_errhandling & MATH_ERREXCEPT) != 0)""")])
# argon2's Makefile archives with a hardcoded `ar` (GNU binutils), which
# can't read wasm objects and writes no symbol index; wasm-ld then never
# pulls ref.o and silently binds core.o's fill_segment call to function 0 (a
# module V8 rejects: "Exec format error" in the guest). Index it afterwards.
edit('external/argon2/ExternalProject_argon2.mk', [("""			OPTTARGET=$(if $(filter X86_64,$(CPUNAME)),x86-64,forcefail) \\
""","""			OPTTARGET=$(if $(filter X86_64,$(CPUNAME)),x86-64,forcefail) \\
		$(if $(filter WASM32,$(CPUNAME)),&& llvm-ranlib libargon2.a) \\
""")])
# No dladdr in a static wasm module: every address is the executable's, so
# the module URL (cppuhelper's get_this_libpath -> unorc, fundamentalrc)
# is /proc/self/exe; otherwise bootstrap throws "URI  is expected to
# contain a slash"
edit('sal/osl/unx/module.cxx', [("""    bool result = false;
#if HAVE_UNIX_DLAPI
    Dl_info dl_info;""","""    bool result = false;
#if defined __wasm__
    (void) address;
    char buf[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
    if (n > 0)
    {
        buf[n] = '\\0';
        rtl_string_newFromStr(path, buf);
        result = true;
    }
#elif HAVE_UNIX_DLAPI
    Dl_info dl_info;"""), ('''#include <limits.h>
#include "file_url.hxx"''', '''#include <limits.h>
#include <unistd.h>
#include "file_url.hxx"''')])
# Thread stacks: release Linux builds keep the libc default, which is 8 MB
# with glibc but 128 KB with musl, and wasm has no guard pages to catch an
# overflow. Ask for 4 MB on wasm, as OpenBSD/macOS ask for theirs. (The
# AutoCorrect crash once blamed on this — pthread_getspecific returning zip
# data in a new thread — was musl's wasm pthread_create handing threads
# unzeroed TSD/TLS memory: toolchain/patches/musl-wasm-pthread-create-zero-tls.patch.)
edit('sal/osl/unx/thread.cxx', [('''#if defined OPENBSD || defined MACOSX || (defined LINUX && !ENABLE_RUNTIME_OPTIMIZATIONS)
    if (pthread_attr_init(&attr) != 0)
        return nullptr;

#if defined OPENBSD
    stacksize = 262144;''', '''#if defined OPENBSD || defined MACOSX || (defined LINUX && !ENABLE_RUNTIME_OPTIMIZATIONS) || defined __wasm__
    if (pthread_attr_init(&attr) != 0)
        return nullptr;

#if defined OPENBSD
    stacksize = 262144;
#elif defined __wasm__
    stacksize = 4 * 1024 * 1024;''')])
# ...and the attr declaration, the pthread_create argument and the destroy
# carry the same condition
_p = R + 'sal/osl/unx/thread.cxx'
_s = open(_p).read().replace(
    '#if defined OPENBSD || defined MACOSX || (defined LINUX && !ENABLE_RUNTIME_OPTIMIZATIONS)\n',
    '#if defined OPENBSD || defined MACOSX || (defined LINUX && !ENABLE_RUNTIME_OPTIMIZATIONS) || defined __wasm__\n')
open(_p, 'w').write(_s)
print("tree: ok")
