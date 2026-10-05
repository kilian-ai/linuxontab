/* x11_compat.c — the symbols our reduced libX11 build leaves undefined.
 * packages/recipes/libX11.sh skips libX11's xlibi18n directory (its objects
 * break wasm section limits), but core files still reference a few of its
 * entry points. Same set as the xeyes recipe's libX11compat: no locales
 * (the C locale only), STRING text properties. The apps never call
 * XLookupString (see ui_key in ui.h), so the stubbed XKB keysym lookup is
 * not on their path. */
#include <stdarg.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef void *XlcArgList;
void *_Xi18n_lock = 0;
void *_conv_lock = 0;

int XSupportsLocale(void) { return 0; }
char *XSetLocaleModifiers(const char *mod) { return (char *)mod; }
void *_XOpenLC(char *name) { (void)name; return 0; }
void _XCloseLC(void *lc) { (void)lc; }
void *_XlcCurrentLC(void) { return 0; }
int _XlcNCompareISOLatin1(const char *a, const char *b, int n) {
    return strncmp(a ? a : "", b ? b : "", (size_t)(n < 0 ? 0 : n));
}
void _XlcCountVaList(va_list var, int *count_return) { (void)var; if (count_return) *count_return = 0; }
void _XlcVaToArgList(va_list var, int count, XlcArgList *args_return) {
    (void)var; (void)count;
    if (args_return) *args_return = 0;
}
void *_XrmInitParseInfo(void *statep) { if (statep) *(void **)statep = 0; return 0; }
int XkbLookupKeySym(void *dpy, unsigned int kc, unsigned int state, unsigned int *mods, unsigned int *sym) {
    (void)dpy; (void)kc; (void)state;
    if (mods) *mods = 0;
    if (sym) *sym = 0;
    return 0;
}

/* A real STRING implementation (XStoreName/XSetWMName paths and toolkits
 * XFree() the value afterwards, so it must be a malloc'd copy). */
struct text_prop { unsigned char *value; unsigned long encoding; int format; unsigned long nitems; };
int XmbTextListToTextProperty(void *dpy, char **list, int count, int style, void *out) {
    struct text_prop *tp = out;
    unsigned long total = 1, off = 0;
    (void)dpy; (void)style;
    for (int i = 0; i < count; i++) total += strlen(list[i] ? list[i] : "") + 1;
    unsigned char *buf = malloc(total);
    if (!buf) return -1;
    for (int i = 0; i < count; i++) {
        size_t n = strlen(list[i] ? list[i] : "");
        memcpy(buf + off, list[i] ? list[i] : "", n);
        off += n;
        buf[off++] = 0;
    }
    if (!off) buf[off++] = 0;
    tp->value = buf; tp->encoding = 31; tp->format = 8; tp->nitems = off - 1;
    return 0;
}
