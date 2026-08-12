/*
 * xfonttest.c — minimal real-Xlib client to verify xtiny's core font
 * support end-to-end: XLoadQueryFont("fixed") → QueryFont reply,
 * XDrawImageString → ImageText8, XDrawString → PolyText8.
 *
 * Build (host, needs the staged X libs from the xeyes recipe):
 *   ./build-xfonttest.sh
 * Run (guest):
 *   xtiny &
 *   DISPLAY=:1 xfonttest </dev/null &
 */
#include <X11/Xlib.h>
#include <stdio.h>

int main(void) {
    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "xfonttest: cannot open display\n"); return 1; }
    int s = DefaultScreen(d);
    Window w = XCreateSimpleWindow(d, RootWindow(d, s), 0, 0, 400, 116, 0,
                                   BlackPixel(d, s), WhitePixel(d, s));
    XStoreName(d, w, "xfonttest");
    XSelectInput(d, w, ExposureMask | KeyPressMask);

    XFontStruct *f = XLoadQueryFont(d, "fixed");
    if (!f) { fprintf(stderr, "xfonttest: no 'fixed' font\n"); return 1; }
    printf("xfonttest: font ascent=%d descent=%d width=%d\n",
           f->ascent, f->descent, f->max_bounds.width);

    GC gc = XCreateGC(d, w, 0, NULL);
    XSetFont(d, gc, f->fid);
    XSetForeground(d, gc, BlackPixel(d, s));
    XSetBackground(d, gc, WhitePixel(d, s));
    XMapWindow(d, w);

    for (;;) {
        XEvent e;
        XNextEvent(d, &e);
        if (e.type == Expose && e.xexpose.count == 0) {
            XDrawImageString(d, w, gc, 12, 28,
                             "The quick brown fox jumps", 25);
            XDrawString(d, w, gc, 12, 58,
                        "over the lazy dog 0123456789", 28);
            XDrawImageString(d, w, gc, 12, 88,
                             "xtiny core fonts (VGA 8x16)", 27);
            XFlush(d);
        }
        if (e.type == KeyPress) break;
    }
    XCloseDisplay(d);
    return 0;
}
