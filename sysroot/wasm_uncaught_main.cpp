// Report C++ exceptions that escape main() on the wasm kernel.
//
// With wasm exception handling a throw nothing catches does not reach
// std::terminate: the wasm exception unwinds straight out of _start into the
// page's worker, which only sees "[object WebAssembly.Exception]". Link with
// -Wl,--wrap=__main_argc_argv (what clang names a wasm `main(int, char **)`)
// and this object, in an archive so main(void) programs don't pull it, to get
// the type (and, for UNO exceptions, the Message) on stderr, then abort()
// like a native uncaught throw.
#include <cxxabi.h>
#include <exception>
#include <typeinfo>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern "C" int __real___main_argc_argv(int argc, char **argv);

// LibreOffice's css::uno::Exception (and every UNO exception deriving from
// it) starts with `OUString Message`, an rtl_uString* = {refCount, length,
// UTF-16 buffer}. Print it when the object looks like one.
static void print_uno_message(const char *type, void *obj) {
    if (!obj || !strstr(type, "com::sun::star::")) return;
    struct rtl_uString { int refCount; int length; unsigned short buffer[1]; };
    rtl_uString *s = *(rtl_uString **)obj;
    if (!s || (unsigned long)s & 3 || s->length < 0 || s->length > 4096) return;
    fputs("  Message: ", stderr);
    for (int i = 0; i < s->length; i++) {
        unsigned c = s->buffer[i];
        fputc(c < 0x80 ? (int)c : '?', stderr);
    }
    fputc('\n', stderr);
}

extern "C" int __wrap___main_argc_argv(int argc, char **argv) {
    try {
        return __real___main_argc_argv(argc, argv);
    } catch (...) {
        std::type_info *t = abi::__cxa_current_exception_type();
        int status = 0;
        char *name = t ? abi::__cxa_demangle(t->name(), nullptr, nullptr, &status) : nullptr;
        const char *shown = name ? name : t ? t->name() : "(unknown type)";
        fprintf(stderr, "%s: terminate called after throwing an instance of '%s'\n",
                argc > 0 ? argv[0] : "?", shown);
        std::exception_ptr p = std::current_exception();
        void *obj = *(void **)&p;   // libc++: exception_ptr holds the thrown object
        try {
            std::rethrow_exception(p);
        } catch (const std::exception &e) {
            fprintf(stderr, "  what(): %s\n", e.what());
        } catch (...) {
            print_uno_message(shown, obj);
        }
        fflush(stderr);
        abort();
    }
}
