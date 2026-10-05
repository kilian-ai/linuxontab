/* x11_im_compat.c — input-method and UTF-8 text-property entry points our
 * reduced libX11 omits (packages/recipes/libX11.sh drops xlibi18n). There is
 * no input method on the guest, which is what these report: XOpenIM and
 * XCreateIC fail, so clients take their plain XLookupString path (st, the
 * terminal Xfe embeds, does exactly that). XmbLookupString is still
 * answered correctly for callers that don't check, and UTF-8 text
 * properties are written as UTF8_STRING. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <stdlib.h>
#include <string.h>

XIM XOpenIM(Display *d, struct _XrmHashBucketRec *db, char *res_name, char *res_class)
{ (void)d; (void)db; (void)res_name; (void)res_class; return NULL; }
Status XCloseIM(XIM im) { (void)im; return 1; }
XIC XCreateIC(XIM im, ...) { (void)im; return NULL; }
void XDestroyIC(XIC ic) { (void)ic; }
void XSetICFocus(XIC ic) { (void)ic; }
void XUnsetICFocus(XIC ic) { (void)ic; }
char *XSetICValues(XIC ic, ...) { (void)ic; return NULL; }
char *XGetICValues(XIC ic, ...) { (void)ic; return NULL; }
char *XSetIMValues(XIM im, ...) { (void)im; return NULL; }
char *XGetIMValues(XIM im, ...) { (void)im; return NULL; }
XVaNestedList XVaCreateNestedList(int unused, ...) { (void)unused; return NULL; }
Bool XRegisterIMInstantiateCallback(Display *d, struct _XrmHashBucketRec *db, char *n, char *c,
                                    XIDProc cb, XPointer data)
{ (void)d; (void)db; (void)n; (void)c; (void)cb; (void)data; return False; }
Bool XUnregisterIMInstantiateCallback(Display *d, struct _XrmHashBucketRec *db, char *n, char *c,
                                      XIDProc cb, XPointer data)
{ (void)d; (void)db; (void)n; (void)c; (void)cb; (void)data; return False; }

static int lookup(XKeyPressedEvent *ev, char *buf, int n, KeySym *ks, Status *st)
{
    KeySym k = NoSymbol;
    int len = XLookupString(ev, buf, n, &k, NULL);
    if (ks) *ks = k;
    if (st) *st = len > 0 ? (k != NoSymbol ? XLookupBoth : XLookupChars)
                          : (k != NoSymbol ? XLookupKeySym : XLookupNone);
    return len;
}
int XmbLookupString(XIC ic, XKeyPressedEvent *ev, char *buf, int n, KeySym *ks, Status *st)
{ (void)ic; return lookup(ev, buf, n, ks, st); }
int Xutf8LookupString(XIC ic, XKeyPressedEvent *ev, char *buf, int n, KeySym *ks, Status *st)
{ (void)ic; return lookup(ev, buf, n, ks, st); }

int Xutf8TextListToTextProperty(Display *d, char **list, int count, XICCEncodingStyle style,
                                XTextProperty *tp)
{
    size_t total = 1, off = 0;
    for (int i = 0; i < count; i++) total += strlen(list[i] ? list[i] : "") + 1;
    unsigned char *buf = malloc(total);
    if (!buf) return XNoMemory;
    for (int i = 0; i < count; i++) {
        size_t len = strlen(list[i] ? list[i] : "");
        memcpy(buf + off, list[i] ? list[i] : "", len);
        off += len;
        buf[off++] = 0;
    }
    if (!off) buf[off++] = 0;
    tp->value = buf;
    tp->encoding = style == XStringStyle ? XA_STRING : XInternAtom(d, "UTF8_STRING", False);
    tp->format = 8;
    tp->nitems = off - 1;
    return Success;
}

/* ── XKB: the guest's X server (xtiny) has no XKEYBOARD extension, and our
 * libX11 is built without XKB. Report it absent; keysym lookup falls back to
 * the core keyboard mapping. ─────────────────────────────────────────────── */
#include <X11/XKBlib.h>

Bool XkbLibraryVersion(int *major, int *minor)
{ if (major) *major = XkbMajorVersion; if (minor) *minor = XkbMinorVersion; return False; }
Bool XkbQueryExtension(Display *d, int *opcode, int *event, int *error, int *major, int *minor)
{ (void)d; (void)opcode; (void)event; (void)error; (void)major; (void)minor; return False; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
KeySym XkbKeycodeToKeysym(Display *d, unsigned int kc, int group, int level)   /* wide prototype */
{
    (void)group;
    KeySym ks = XKeycodeToKeysym(d, kc, level);
    return ks != NoSymbol || level == 0 ? ks : XKeycodeToKeysym(d, kc, 0);
}
#pragma clang diagnostic pop
Bool XkbSelectEventDetails(Display *d, unsigned int spec, unsigned int type,
                           unsigned long affect, unsigned long details)
{ (void)d; (void)spec; (void)type; (void)affect; (void)details; return False; }
Status XkbGetIndicatorState(Display *d, unsigned int spec, unsigned int *state)
{ (void)d; (void)spec; if (state) *state = 0; return BadImplementation; }
Bool XkbLockModifiers(Display *d, unsigned int spec, unsigned int affect, unsigned int values)
{ (void)d; (void)spec; (void)affect; (void)values; return False; }
Status XkbGetState(Display *d, unsigned int spec, XkbStatePtr state)
{ (void)d; (void)spec; if (state) memset(state, 0, sizeof *state); return BadImplementation; }

/* more of the input-method surface: no input method exists */
Display *XDisplayOfIM(XIM im) { (void)im; return NULL; }
char *XLocaleOfIM(XIM im) { (void)im; return NULL; }
XIM XIMOfIC(XIC ic) { (void)ic; return NULL; }

/* STRING/UTF8_STRING properties back into a list of strings (the inverse of
 * Xutf8TextListToTextProperty above): NUL-separated items. */
int XmbTextPropertyToTextList(Display *d, const XTextProperty *tp, char ***list_return, int *count_return)
{
    (void)d;
    if (!tp || tp->format != 8 || !list_return || !count_return) return XConverterNotFound;
    unsigned long n = tp->nitems;
    int count = 1;
    for (unsigned long i = 0; i < n; i++) if (!tp->value[i]) count++;
    if (n && !tp->value[n - 1]) count--;
    char **list = malloc(sizeof(char *) * (size_t)(count + 1));
    char *buf = malloc(n + 1);
    if (!list || !buf) { free(list); free(buf); return XNoMemory; }
    memcpy(buf, tp->value, n);
    buf[n] = 0;
    int k = 0;
    for (unsigned long i = 0; k < count; k++) {
        list[k] = buf + i;
        while (i < n && buf[i]) i++;
        i++;
    }
    list[count] = NULL;
    *list_return = list;
    *count_return = count;
    return Success;
}
int Xutf8TextPropertyToTextList(Display *d, const XTextProperty *tp, char ***l, int *c)
{ return XmbTextPropertyToTextList(d, tp, l, c); }
