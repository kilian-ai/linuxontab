/* ui.h — the little toolkit shared by the xtiny desktop apps (lot-textedit,
 * lot-calc, lot-calendar). Plain Xlib, core protocol only, because that is
 * all xtiny speaks: one TrueColor visual, the "fixed" 8x16 font, pixmaps,
 * filled rectangles and arcs. Everything is drawn into a back-buffer pixmap
 * and copied to the window in one request, so redraws never flicker.
 * Colours follow the xtiny theme (dark, warm grey, orange accent). */
#ifndef XAPPS_UI_H
#define XAPPS_UI_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>

#define C_BG        0x201D1A
#define C_PANEL     0x2A2623
#define C_BTN       0x35312D
#define C_BTN_HOV   0x433E39
#define C_BTN_DOWN  0x504A44
#define C_TEXT      0xE6E2DE
#define C_DIM       0x948E88
#define C_FAINT     0x5C5650
#define C_ACCENT    0xFF9F5A
#define C_ON_ACCENT 0x1D1A17
#define C_SEL       0x5C4433
#define C_LINE      0x3A3632

typedef struct {
    Display *d;
    int scr;
    Window win;
    Pixmap buf;                 /* back buffer, w x h */
    GC gc;
    XFontStruct *font;
    int w, h;
    int cw, ch, asc;            /* font cell width/height, ascent */
    Atom wm_protocols, wm_delete;
    int want_close;             /* WM_DELETE_WINDOW arrived */
    int mx, my;                 /* last pointer position */
} Ui;

typedef struct { int x, y, w, h; } Rect;

static inline int rect_has(Rect r, int x, int y) {
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

static inline void ui_color(Ui *u, unsigned long rgb) { XSetForeground(u->d, u->gc, rgb); }

static inline void ui_make_buffer(Ui *u) {
    if (u->buf) XFreePixmap(u->d, u->buf);
    u->buf = XCreatePixmap(u->d, u->win, (unsigned)u->w, (unsigned)u->h,
                           (unsigned)DefaultDepth(u->d, u->scr));
}

/* x/y < 0: let the window manager place it; otherwise ask for exactly that
 * position (USPosition — xtiny honours it). */
static inline int ui_open(Ui *u, const char *title, const char *res_name,
                   int w, int h, int x, int y, int min_w, int min_h) {
    memset(u, 0, sizeof *u);
    u->d = XOpenDisplay(NULL);
    if (!u->d) {
        fprintf(stderr, "%s: cannot open display %s (start xtiny first)\n",
                res_name, getenv("DISPLAY") ? getenv("DISPLAY") : "(DISPLAY unset)");
        return -1;
    }
    u->scr = DefaultScreen(u->d);
    int sw = DisplayWidth(u->d, u->scr), sh = DisplayHeight(u->d, u->scr);
    if (w > sw) w = sw;
    if (h > sh) h = sh;
    u->w = w; u->h = h;
    XSetWindowAttributes a;
    a.background_pixel = C_BG;
    a.event_mask = ExposureMask | KeyPressMask | ButtonPressMask | ButtonReleaseMask |
                   PointerMotionMask | StructureNotifyMask | LeaveWindowMask;
    u->win = XCreateWindow(u->d, RootWindow(u->d, u->scr), x < 0 ? 0 : x, y < 0 ? 0 : y,
                           (unsigned)w, (unsigned)h, 0, CopyFromParent, InputOutput,
                           CopyFromParent, CWBackPixel | CWEventMask, &a);
    XStoreName(u->d, u->win, title);
    XClassHint ch = { (char *)res_name, (char *)"XtinyApps" };
    XSetClassHint(u->d, u->win, &ch);
    XSizeHints sz;
    memset(&sz, 0, sizeof sz);
    sz.flags = PMinSize;
    sz.min_width = min_w; sz.min_height = min_h;
    if (x >= 0 && y >= 0) { sz.flags |= USPosition; sz.x = x; sz.y = y; }
    XSetWMNormalHints(u->d, u->win, &sz);
    u->wm_protocols = XInternAtom(u->d, "WM_PROTOCOLS", False);
    u->wm_delete = XInternAtom(u->d, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(u->d, u->win, &u->wm_delete, 1);
    u->gc = XCreateGC(u->d, u->win, 0, NULL);
    u->font = XLoadQueryFont(u->d, "fixed");
    if (u->font) {
        XSetFont(u->d, u->gc, u->font->fid);
        u->cw = u->font->max_bounds.width;
        u->asc = u->font->ascent;
        u->ch = u->font->ascent + u->font->descent;
    }
    if (u->cw <= 0) u->cw = 8;
    if (u->ch <= 0) { u->ch = 16; u->asc = 12; }
    ui_make_buffer(u);
    XMapWindow(u->d, u->win);
    XFlush(u->d);
    return 0;
}

static inline void ui_close(Ui *u) {
    if (!u->d) return;
    if (u->buf) XFreePixmap(u->d, u->buf);
    XDestroyWindow(u->d, u->win);
    XCloseDisplay(u->d);
    u->d = NULL;
}

static inline void ui_present(Ui *u) {
    XCopyArea(u->d, u->buf, u->win, u->gc, 0, 0, (unsigned)u->w, (unsigned)u->h, 0, 0);
    XFlush(u->d);
}

static inline void ui_fill(Ui *u, int x, int y, int w, int h, unsigned long c) {
    if (w <= 0 || h <= 0) return;
    ui_color(u, c);
    XFillRectangle(u->d, u->buf, u->gc, x, y, (unsigned)w, (unsigned)h);
}

static inline void ui_rrect(Ui *u, int x, int y, int w, int h, int r, unsigned long c) {
    if (w <= 0 || h <= 0) return;
    if (r * 2 > w) r = w / 2;
    if (r * 2 > h) r = h / 2;
    ui_color(u, c);
    if (r < 2) { XFillRectangle(u->d, u->buf, u->gc, x, y, (unsigned)w, (unsigned)h); return; }
    int d = 2 * r;
    XFillRectangle(u->d, u->buf, u->gc, x + r, y, (unsigned)(w - d), (unsigned)h);
    XFillRectangle(u->d, u->buf, u->gc, x, y + r, (unsigned)w, (unsigned)(h - d));
    XFillArc(u->d, u->buf, u->gc, x, y, (unsigned)d, (unsigned)d, 90 * 64, 90 * 64);
    XFillArc(u->d, u->buf, u->gc, x + w - d - 1, y, (unsigned)d, (unsigned)d, 0, 90 * 64);
    XFillArc(u->d, u->buf, u->gc, x, y + h - d - 1, (unsigned)d, (unsigned)d, 180 * 64, 90 * 64);
    XFillArc(u->d, u->buf, u->gc, x + w - d - 1, y + h - d - 1, (unsigned)d, (unsigned)d, 270 * 64, 90 * 64);
}

static inline void ui_circle(Ui *u, int cx, int cy, int r, unsigned long c) {
    ui_color(u, c);
    XFillArc(u->d, u->buf, u->gc, cx - r, cy - r, (unsigned)(2 * r), (unsigned)(2 * r), 0, 360 * 64);
}

static inline int ui_text_w(Ui *u, const char *s, int n) {
    if (n < 0) n = (int)strlen(s);
    return n * u->cw;
}

/* y is the top of the text cell */
static inline void ui_text(Ui *u, int x, int y, const char *s, int n, unsigned long c) {
    if (n < 0) n = (int)strlen(s);
    if (n <= 0) return;
    ui_color(u, c);
    XDrawString(u->d, u->buf, u->gc, x, y + u->asc, s, n);
}

static inline void ui_text_center(Ui *u, Rect r, const char *s, unsigned long c) {
    int tw = ui_text_w(u, s, -1);
    ui_text(u, r.x + (r.w - tw) / 2, r.y + (r.h - u->ch) / 2, s, -1, c);
}

/* A push button: rounded, hover/pressed shades, centred label. */
static inline void ui_button(Ui *u, Rect r, const char *label, int hover, int down,
                      unsigned long base, unsigned long fg) {
    unsigned long c = base;
    if (base == C_BTN) c = down ? C_BTN_DOWN : hover ? C_BTN_HOV : C_BTN;
    else if (hover || down) {                 /* lighten a coloured button */
        int k = down ? 28 : 16;
        int rr = (int)((base >> 16) & 255) + k, gg = (int)((base >> 8) & 255) + k, bb = (int)(base & 255) + k;
        c = (unsigned long)((rr > 255 ? 255 : rr) << 16 | (gg > 255 ? 255 : gg) << 8 | (bb > 255 ? 255 : bb));
    }
    ui_rrect(u, r.x, r.y, r.w, r.h, 6, c);
    ui_text_center(u, r, label, fg);
}

/* ── big digits ─────────────────────────────────────────────────────────────
 * The only server font is 8x16, too small for a calculator display or a
 * clock, so numbers are drawn from a 5x7 bitmap font scaled with filled
 * rectangles. Covers what those two need. */
static const struct { char c; unsigned char rows[7]; } BIG_GLYPHS[] = {
    {'0',{0x0E,0x11,0x13,0x15,0x19,0x11,0x0E}}, {'1',{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E}},
    {'2',{0x0E,0x11,0x01,0x02,0x04,0x08,0x1F}}, {'3',{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E}},
    {'4',{0x02,0x06,0x0A,0x12,0x1F,0x02,0x02}}, {'5',{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E}},
    {'6',{0x06,0x08,0x10,0x1E,0x11,0x11,0x0E}}, {'7',{0x1F,0x01,0x02,0x04,0x08,0x08,0x08}},
    {'8',{0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E}}, {'9',{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C}},
    {'.',{0x00,0x00,0x00,0x00,0x00,0x0C,0x0C}}, {'-',{0x00,0x00,0x00,0x1F,0x00,0x00,0x00}},
    {'+',{0x00,0x04,0x04,0x1F,0x04,0x04,0x00}}, {':',{0x00,0x0C,0x0C,0x00,0x0C,0x0C,0x00}},
    {'e',{0x00,0x00,0x0E,0x11,0x1F,0x10,0x0E}}, {'E',{0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F}},
    {'r',{0x00,0x00,0x16,0x19,0x10,0x10,0x10}}, {'o',{0x00,0x00,0x0E,0x11,0x11,0x11,0x0E}},
    {',',{0x00,0x00,0x00,0x00,0x0C,0x04,0x08}}, {' ',{0,0,0,0,0,0,0}},
};

static inline const unsigned char *big_glyph(char c) {
    for (size_t i = 0; i < sizeof BIG_GLYPHS / sizeof BIG_GLYPHS[0]; i++)
        if (BIG_GLYPHS[i].c == c) return BIG_GLYPHS[i].rows;
    return BIG_GLYPHS[sizeof BIG_GLYPHS / sizeof BIG_GLYPHS[0] - 1].rows;
}

/* Advance of one big glyph at scale s (narrow punctuation). */
static inline int big_adv(char c, int s) {
    return (c == '.' || c == ':' || c == ',') ? 3 * s : 6 * s;
}

static inline int big_width(const char *str, int s) {
    int w = 0;
    for (const char *p = str; *p; p++) w += big_adv(*p, s);
    return w ? w - s : 0;
}

static inline void big_text(Ui *u, int x, int y, const char *str, int s, unsigned long c) {
    ui_color(u, c);
    XRectangle rs[64];
    for (const char *p = str; *p; p++) {
        const unsigned char *g = big_glyph(*p);
        int off = (*p == '.' || *p == ':' || *p == ',') ? -s : 0;   /* centre narrow ones */
        int n = 0;
        for (int row = 0; row < 7; row++)
            for (int col = 0; col < 5; col++)
                if (g[row] & (0x10 >> col) && n < 64) {
                    rs[n].x = (short)(x + off + col * s); rs[n].y = (short)(y + row * s);
                    rs[n].width = (unsigned short)s; rs[n].height = (unsigned short)s;
                    n++;
                }
        if (n) XFillRectangles(u->d, u->buf, u->gc, rs, n);
        x += big_adv(*p, s);
    }
}

/* ── events ───────────────────────────────────────────────────────────────── */
/* Wait up to timeout_ms (<0: forever) for the next event. Returns 1 with
 * *ev filled, 0 on timeout. Handles resize (new back buffer) and the
 * WM_DELETE_WINDOW handshake (sets u->want_close) itself, but still hands
 * those events to the caller. */
static inline int ui_next_event(Ui *u, XEvent *ev, int timeout_ms) {
    if (!XPending(u->d)) {
        if (timeout_ms == 0) return 0;
        int fd = ConnectionNumber(u->d);
        fd_set rf;
        FD_ZERO(&rf);
        FD_SET(fd, &rf);
        struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
        XFlush(u->d);
        if (select(fd + 1, &rf, NULL, NULL, timeout_ms < 0 ? NULL : &tv) <= 0 && !XPending(u->d))
            return 0;
    }
    XNextEvent(u->d, ev);
    if (getenv("LOT_UI_DEBUG") && ev->type != MotionNotify)
        fprintf(stderr, "[ui] event %d win=%#lx\n", ev->type, (unsigned long)ev->xany.window);
    if (ev->type == ConfigureNotify &&
        (ev->xconfigure.width != u->w || ev->xconfigure.height != u->h) &&
        ev->xconfigure.width > 0 && ev->xconfigure.height > 0) {
        u->w = ev->xconfigure.width;
        u->h = ev->xconfigure.height;
        ui_make_buffer(u);
    }
    if (ev->type == ClientMessage && ev->xclient.message_type == u->wm_protocols &&
        (Atom)ev->xclient.data.l[0] == u->wm_delete)
        u->want_close = 1;
    if (ev->type == MotionNotify) { u->mx = ev->xmotion.x; u->my = ev->xmotion.y; }
    if (ev->type == ButtonPress || ev->type == ButtonRelease) { u->mx = ev->xbutton.x; u->my = ev->xbutton.y; }
    if (ev->type == LeaveNotify) { u->mx = -1; u->my = -1; }
    return 1;
}

/* Key -> keysym + typed text (empty for function keys). Decoded from the
 * keymap directly (XLookupKeysym, shift-aware) rather than XLookupString:
 * our reduced libX11 has no i18n/XKB lookup behind that. Latin-1 only. */
static inline KeySym ui_key(XEvent *ev, char *text, int *len) {
    int shift = (ev->xkey.state & ShiftMask) != 0;
    int caps = (ev->xkey.state & LockMask) != 0;
    KeySym ks = XLookupKeysym(&ev->xkey, shift ? 1 : 0);
    if (ks == NoSymbol && shift) ks = XLookupKeysym(&ev->xkey, 0);
    if (caps && ks >= XK_a && ks <= XK_z) ks -= XK_a - XK_A;
    else if (caps && ks >= XK_A && ks <= XK_Z && shift) ks += XK_a - XK_A;
    int n = 0;
    char c = 0;
    if (ks >= 0x20 && ks <= 0x7e) c = (char)ks;
    else if (ks >= 0xa0 && ks <= 0xff) c = (char)ks;
    else if (ks >= XK_KP_0 && ks <= XK_KP_9) c = (char)('0' + (ks - XK_KP_0));
    if (c && (ev->xkey.state & ControlMask)) {
        /* Ctrl+letter: report the letter's keysym, no text */
        if (ks >= XK_A && ks <= XK_Z) ks += XK_a - XK_A;
        c = 0;
    }
    if (c) n = 1;
    if (getenv("LOT_UI_DEBUG"))
        fprintf(stderr, "[ui] key code=%u state=%#x keysym=%#lx text=%d\n",
                ev->xkey.keycode, ev->xkey.state, (unsigned long)ks, n ? c : 0);
    if (text) { if (n) text[0] = c; text[n] = 0; }
    if (len) *len = n;
    return ks;
}

#endif
