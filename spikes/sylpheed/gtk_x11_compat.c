/* gtk_x11_compat.c — the xlibi18n calls GDK 2 makes that our reduced libX11
 * (no xlibi18n, no XKB; see spikes/libreoffice/xfe/x11_compat.c for the rest)
 * does not have. GDK draws text with pango/cairo, so the fontset drawing
 * calls are dead code here; the window properties are real. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>

void XmbSetWMProperties(Display *dpy, Window w, const char *window_name,
                        const char *icon_name, char **argv, int argc,
                        XSizeHints *normal_hints, XWMHints *wm_hints,
                        XClassHint *class_hints) {
  XTextProperty wname, iname;
  XTextProperty *pw = 0, *pi = 0;
  if (window_name && XStringListToTextProperty((char **)&window_name, 1, &wname)) pw = &wname;
  if (icon_name && XStringListToTextProperty((char **)&icon_name, 1, &iname)) pi = &iname;
  XSetWMProperties(dpy, w, pw, pi, argv, argc, normal_hints, wm_hints, class_hints);
  if (pw) XFree(wname.value);
  if (pi) XFree(iname.value);
}

void XmbDrawString(Display *dpy, Drawable d, XFontSet fs, GC gc, int x, int y,
                   const char *text, int len) {
  (void)dpy; (void)d; (void)fs; (void)gc; (void)x; (void)y; (void)text; (void)len;
}

void XwcDrawString(Display *dpy, Drawable d, XFontSet fs, GC gc, int x, int y,
                   const wchar_t *text, int len) {
  (void)dpy; (void)d; (void)fs; (void)gc; (void)x; (void)y; (void)text; (void)len;
}

char *XmbResetIC(XIC ic) { (void)ic; return 0; }
