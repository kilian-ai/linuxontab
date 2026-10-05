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
