/*
 * xtiny.c — a tiny X11 server on librfb, for the LinuxOnTab WASM kernel.
 *
 * Speaks enough of the core X11 protocol to run the real, unmodified
 * xeyes (libxcb + libX11 + libXt stack, shipped in /usr/bin/xeyes) and
 * composites X windows onto the librfb desktop: every top-level window
 * gets the draggable rfb_winframe chrome, drawing lands in per-window
 * backing buffers, and RFB pointer/keyboard input is delivered as X
 * events. No extensions (every QueryExtension answers "absent" — clients
 * fall back to core paths, e.g. xeyes drops XInput/Render and polls the
 * pointer with QueryPointer). TrueColor 24-bit only, which matches the
 * librfb BGRA framebuffer byte-for-byte.
 *
 * Listens on /tmp/.X11-unix/X1 (DISPLAY=:1). X clients are serviced from
 * librfb's on_idle hook, so one single-threaded process runs the whole
 * desktop: RFB out, X in.
 *
 *   xtiny &            # the display server (also the RFB desktop)
 *   DISPLAY=:1 xeyes </dev/null &
 *
 * Build + install: ./build-vnc-demos.sh
 */
#include "librfb.h"
#include "xtiny_font.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>

/* musl hides fork() for wasm32; the kernel provides it via asyncify
 * (sysroot/wasm_fork.c, linked into this binary). */
pid_t fork(void);

#define FB_W 800
#define FB_H 600

/* The taskbar owns the bottom strip; windows live above it. */
#define TASKBAR_H 26
#define WORK_H    (FB_H - TASKBAR_H)

#define MAX_XCLIENTS 8
#define MAX_WINDOWS  64
#define MAX_PIXMAPS  64
#define MAX_GCS      64
#define MAX_DYNATOMS 256
#define MAX_PROPS    12

#define ROOT_ID   1u
#define CMAP_ID   2u
#define VISUAL_ID 0x21u

/* ── wire helpers ─────────────────────────────────────────────────────────── */
static uint32_t g32(const uint8_t *b, int o) {
    return (uint32_t)b[o] | ((uint32_t)b[o+1]<<8) |
           ((uint32_t)b[o+2]<<16) | ((uint32_t)b[o+3]<<24);
}
static uint16_t g16(const uint8_t *b, int o) {
    return (uint16_t)(b[o] | (b[o+1]<<8));
}
static int16_t gs16(const uint8_t *b, int o) { return (int16_t)g16(b, o); }
static void p32(uint8_t *b, int o, uint32_t v) {
    b[o]=v; b[o+1]=v>>8; b[o+2]=v>>16; b[o+3]=v>>24;
}
static void p16(uint8_t *b, int o, uint32_t v) { b[o]=v; b[o+1]=v>>8; }
static int pad4(int n) { return (n + 3) & ~3; }

/* ── X resources ──────────────────────────────────────────────────────────── */
typedef struct {
    uint32_t id;                /* 0 = free */
    uint32_t parent;
    int x, y;                   /* relative to parent (child) — top-levels
                                   are positioned by their frame instead */
    int w, h, border;
    int class_;                 /* 1 InputOutput, 2 InputOnly */
    int mapped;
    int minimized;              /* hidden but still listed in the taskbar */
    int maxed;                  /* geometry below is the pre-maximise one */
    int save_x, save_y, save_w, save_h;
    uint32_t evmask;
    uint32_t bg; int has_bg;
    int cursor;                 /* RFB_CUR_*, -1 = inherit from parent */
    uint32_t *px;               /* backing, w*h X pixels (0x00RRGGBB) */
    int toplevel;
    rfb_winframe frame;
    char title[64];
    int creator;
    struct { uint32_t atom, type; uint8_t fmt; uint32_t n;
             uint8_t data[512]; } props[MAX_PROPS];
    int nprops;
} XWindow;

typedef struct {
    uint32_t id;                /* 0 = free */
    int w, h;
    uint32_t *px;
    int creator;
} XPixmap;

typedef struct {
    uint32_t id;                /* 0 = free */
    uint32_t fg, bg;
    int creator;
} XGC;

typedef struct {
    int fd;                     /* -1 = free */
    int state;                  /* 1 handshake, 2 running */
    uint8_t inbuf[65536];
    int inlen;
    uint16_t seq;
    uint32_t root_evmask;
} XClient;

static struct {
    int lfd;
    XClient cl[MAX_XCLIENTS];
    XWindow win[MAX_WINDOWS];
    XPixmap pix[MAX_PIXMAPS];
    XGC gc[MAX_GCS];
    char dynatoms[MAX_DYNATOMS][64];
    int ndynatoms;
    int ptr_x, ptr_y;           /* fb coords */
    uint16_t btn_state;         /* X state bitmask (Button1Mask..) */
    uint16_t mod_state;         /* ShiftMask|LockMask|ControlMask|Mod1Mask */
    int ntoplevel;              /* cascade counter for frame placement */
    rfb_server *srv;            /* set once rfb_run calls us */

    /* Explicit stacking: top-level window ids, FRONT first. Creation order
     * is not z-order — without this, a newly mapped window could never be
     * raised above an older one, and hit-testing picked whichever window
     * happened to sit later in the array. */
    uint32_t stack[MAX_WINDOWS];
    int nstack;

    /* Click-to-focus. Keyboard input used to go to the window under the
     * POINTER, so typing into xterm meant parking the mouse over it. The
     * focus window owns the keyboard until another window is clicked. */
    uint32_t focus;      /* focused TOP-LEVEL: raise + chrome + ownership  */
    uint32_t xfocus;     /* exact window from SetInputFocus, if any — a
                          * toolkit app focuses its inner widget (xterm
                          * focuses its VT child, which is where the key
                          * actions live; the shell window above it
                          * selects for keys but ignores them). */

    int cursor_shape;           /* current RFB_CUR_* for the pointer window */
} X;

/* ── predefined atoms (X11 standard, ids 1..68) ───────────────────────────── */
static const char *PREATOMS[] = { "",
    "PRIMARY","SECONDARY","ARC","ATOM","BITMAP","CARDINAL","COLORMAP",
    "CURSOR","CUT_BUFFER0","CUT_BUFFER1","CUT_BUFFER2","CUT_BUFFER3",
    "CUT_BUFFER4","CUT_BUFFER5","CUT_BUFFER6","CUT_BUFFER7","DRAWABLE",
    "FONT","INTEGER","PIXMAP","POINT","RECTANGLE","RESOURCE_MANAGER",
    "RGB_COLOR_MAP","RGB_BEST_MAP","RGB_BLUE_MAP","RGB_DEFAULT_MAP",
    "RGB_GRAY_MAP","RGB_GREEN_MAP","RGB_RED_MAP","STRING","VISUALID",
    "WINDOW","WM_COMMAND","WM_HINTS","WM_CLIENT_MACHINE","WM_ICON_NAME",
    "WM_ICON_SIZE","WM_NAME","WM_NORMAL_HINTS","WM_SIZE_HINTS",
    "WM_ZOOM_HINTS","MIN_SPACE","NORM_SPACE","MAX_SPACE","END_SPACE",
    "SUPERSCRIPT_X","SUPERSCRIPT_Y","SUBSCRIPT_X","SUBSCRIPT_Y",
    "UNDERLINE_POSITION","UNDERLINE_THICKNESS","STRIKEOUT_ASCENT",
    "STRIKEOUT_DESCENT","ITALIC_ANGLE","X_HEIGHT","QUAD_WIDTH","WEIGHT",
    "POINT_SIZE","RESOLUTION","COPYRIGHT","NOTICE","FONT_NAME",
    "FAMILY_NAME","FULL_NAME","CAP_HEIGHT","WM_CLASS","WM_TRANSIENT_FOR",
};
#define NPREATOMS 68

/* ── named colors (AllocNamedColor/LookupColor) ───────────────────────────── */
static const struct { const char *name; uint32_t rgb; } COLORS[] = {
    {"black",0x000000},{"white",0xffffff},{"red",0xff0000},
    {"green",0x00ff00},{"blue",0x0000ff},{"yellow",0xffff00},
    {"cyan",0x00ffff},{"magenta",0xff00ff},{"gray",0xbebebe},
    {"grey",0xbebebe},{"dark gray",0xa9a9a9},{"dark grey",0xa9a9a9},
    {"light gray",0xd3d3d3},{"light grey",0xd3d3d3},{"brown",0xa52a2a},
    {"orange",0xffa500},{"pink",0xffc0cb},{"purple",0xa020f0},
    {"navy",0x000080},{"navy blue",0x000080},
};

static int color_lookup(const char *name, int len, uint32_t *rgb) {
    for (unsigned i = 0; i < sizeof COLORS / sizeof COLORS[0]; i++) {
        const char *c = COLORS[i].name;
        if ((int)strlen(c) != len) continue;
        int ok = 1;
        for (int j = 0; j < len; j++) {
            char a = name[j], b = c[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (a != b) { ok = 0; break; }
        }
        if (ok) { *rgb = COLORS[i].rgb; return 1; }
    }
    return 0;
}

/* ── keycode mapping (RFB keysyms ⇄ X keycodes) ──────────────────────────── */
static const struct { uint32_t ks; uint8_t code; } SPECIALS[] = {
    {0xff08,105},{0xff09,106},{0xff0d,107},{0xff1b,108},{0xff50,109},
    {0xff51,110},{0xff52,111},{0xff53,112},{0xff54,113},{0xff55,114},
    {0xff56,115},{0xff57,116},{0xff63,117},{0xffff,118},{0xffe1,119},
    {0xffe3,120},{0xffe9,121},{0xffe7,122},{0xffe5,123},
};

static uint8_t keysym_to_keycode(uint32_t ks) {
    if (ks >= 0x20 && ks <= 0x7e) return (uint8_t)(ks - 0x20 + 10);
    for (unsigned i = 0; i < sizeof SPECIALS / sizeof SPECIALS[0]; i++)
        if (SPECIALS[i].ks == ks) return SPECIALS[i].code;
    return 0;
}
static uint32_t keycode_to_keysym(uint8_t code) {
    if (code >= 10 && code <= 104) return (uint32_t)(code - 10 + 0x20);
    for (unsigned i = 0; i < sizeof SPECIALS / sizeof SPECIALS[0]; i++)
        if (SPECIALS[i].code == code) return SPECIALS[i].ks;
    return 0;
}

/* ── resource lookup ──────────────────────────────────────────────────────── */
static XWindow *find_win(uint32_t id) {
    if (!id) return NULL;
    for (int i = 0; i < MAX_WINDOWS; i++)
        if (X.win[i].id == id) return &X.win[i];
    return NULL;
}
static XPixmap *find_pix(uint32_t id) {
    for (int i = 0; i < MAX_PIXMAPS; i++)
        if (X.pix[i].id == id) return &X.pix[i];
    return NULL;
}
static XGC *find_gc(uint32_t id) {
    for (int i = 0; i < MAX_GCS; i++)
        if (X.gc[i].id == id) return &X.gc[i];
    return NULL;
}

/* Screen origin of a window's content area. */
static void win_origin(XWindow *w, int *ox, int *oy) {
    if (w->id == ROOT_ID) { *ox = 0; *oy = 0; return; }
    if (w->toplevel) {
        *ox = rfb_winframe_cx(&w->frame);
        *oy = rfb_winframe_cy(&w->frame);
        return;
    }
    XWindow *p = find_win(w->parent);
    int px = 0, py = 0;
    if (p) win_origin(p, &px, &py);
    *ox = px + w->x;
    *oy = py + w->y;
}

static int win_visible(XWindow *w) {
    while (w && w->id != ROOT_ID) {
        if (!w->mapped) return 0;
        w = find_win(w->parent);
    }
    return w != NULL;
}

static void damage_window(XWindow *w) {
    if (!X.srv || !win_visible(w)) return;
    int ox, oy;
    win_origin(w, &ox, &oy);
    rfb_damage(X.srv, ox, oy, w->w, w->h);
}

/* ── drawables ────────────────────────────────────────────────────────────── */
typedef struct { uint32_t *px; int w, h; XWindow *win; } Drawable;

static int resolve_drawable(uint32_t id, Drawable *d) {
    XWindow *w = find_win(id);
    if (w) {
        d->px = w->px; d->w = w->w; d->h = w->h; d->win = w;
        return 1;
    }
    XPixmap *p = find_pix(id);
    if (p && p->id) {
        d->px = p->px; d->w = p->w; d->h = p->h; d->win = NULL;
        return 1;
    }
    return 0;
}

/* ── drawing primitives (into drawable buffers, X pixel = 0x00RRGGBB) ────── */
static void dput(Drawable *d, int x, int y, uint32_t pix) {
    if (!d->px || (unsigned)x >= (unsigned)d->w || (unsigned)y >= (unsigned)d->h)
        return;
    d->px[y * d->w + x] = pix;
}
static void dfill_rect(Drawable *d, int x, int y, int w, int h, uint32_t pix) {
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++)
            dput(d, x + i, y + j, pix);
}
static void dline(Drawable *d, int x0, int y0, int x1, int y1, uint32_t pix) {
    int dx = abs(x1-x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1-y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        dput(d, x0, y0, pix);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2*err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}
/* Filled ellipse in the bbox; if a full-circle arc, this is exact for
 * PolyFillArc (all xeyes ever draws). Pie slices get an angle test. */
static void dfill_arc(Drawable *d, int x, int y, int w, int h,
                      int a1, int a2, uint32_t pix) {
    if (w <= 0 || h <= 0) return;
    double cx = x + w / 2.0, cy = y + h / 2.0;
    double rx = w / 2.0, ry = h / 2.0;
    int full = (a2 >= 360*64 || a2 <= -360*64);
    double s = a1 * M_PI / (180.0 * 64.0);
    double span = a2 * M_PI / (180.0 * 64.0);
    for (int j = y; j < y + h; j++) {
        for (int i = x; i < x + w; i++) {
            double nx = (i + 0.5 - cx) / rx;
            double ny = (cy - (j + 0.5)) / ry;    /* y up for angles */
            if (nx*nx + ny*ny > 1.0) continue;
            if (!full) {
                double ang = atan2(ny, nx);
                double rel = ang - s;
                double sp = span;
                if (sp < 0) { rel = -rel; sp = -sp; }
                while (rel < 0) rel += 2*M_PI;
                while (rel >= 2*M_PI) rel -= 2*M_PI;
                if (rel > sp) continue;
            }
            dput(d, i, j, pix);
        }
    }
}
static void darc_outline(Drawable *d, int x, int y, int w, int h,
                         int a1, int a2, uint32_t pix) {
    double cx = x + w / 2.0, cy = y + h / 2.0;
    double rx = w / 2.0, ry = h / 2.0;
    double s = a1 * M_PI / (180.0*64.0), span = a2 * M_PI / (180.0*64.0);
    int steps = 128;
    int px_ = -1, py_ = -1;
    for (int i = 0; i <= steps; i++) {
        double a = s + span * i / steps;
        int ix = (int)(cx + rx * cos(a));
        int iy = (int)(cy - ry * sin(a));
        if (px_ >= 0) dline(d, px_, py_, ix, iy, pix);
        px_ = ix; py_ = iy;
    }
}
/* Draw one glyph with its baseline at (x,y). with_bg fills the whole cell
 * (ImageText semantics); PolyText paints foreground pixels only. */
static void dchar(Drawable *d, int x, int y, unsigned char ch,
                  uint32_t fg, int with_bg, uint32_t bg) {
    for (int row = 0; row < XFONT_H; row++) {
        int py = y - XFONT_ASCENT + row;
        unsigned bits = XFONT[ch][row];
        for (int col = 0; col < XFONT_W; col++) {
            if (bits & (0x80u >> col)) dput(d, x + col, py, fg);
            else if (with_bg)          dput(d, x + col, py, bg);
        }
    }
}

static void dfill_poly(Drawable *d, const int *xs, const int *ys, int n,
                       uint32_t pix) {
    if (n < 3) return;
    int miny = ys[0], maxy = ys[0];
    for (int i = 1; i < n; i++) {
        if (ys[i] < miny) miny = ys[i];
        if (ys[i] > maxy) maxy = ys[i];
    }
    for (int y = miny; y <= maxy; y++) {
        double xi[64]; int k = 0;
        for (int i = 0; i < n && k < 64; i++) {
            int j = (i + 1) % n;
            int y0 = ys[i], y1 = ys[j];
            if ((y0 <= y && y1 > y) || (y1 <= y && y0 > y)) {
                double t = (double)(y - y0) / (double)(y1 - y0);
                xi[k++] = xs[i] + t * (xs[j] - xs[i]);
            }
        }
        /* insertion sort */
        for (int a = 1; a < k; a++) {
            double v = xi[a]; int b = a - 1;
            while (b >= 0 && xi[b] > v) { xi[b+1] = xi[b]; b--; }
            xi[b+1] = v;
        }
        for (int a = 0; a + 1 < k; a += 2)
            for (int x = (int)ceil(xi[a]); x < (int)ceil(xi[a+1]); x++)
                dput(d, x, y, pix);
    }
}

/* ── client I/O ───────────────────────────────────────────────────────────── */
static void drop_client(XClient *c);

static void cwrite(XClient *c, const void *buf, size_t n) {
    const char *p = buf;
    long stalled = 0;
    while (n && c->fd >= 0) {
        ssize_t r = write(c->fd, p, n);
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if ((stalled += 2000) > 5 * 1000 * 1000) { drop_client(c); return; }
            usleep(2000);
            continue;
        }
        if (r <= 0) { if (errno == EINTR) continue; drop_client(c); return; }
        p += r; n -= r;
    }
}

static void send_reply(XClient *c, uint8_t detail, const uint8_t *body24,
                       const uint8_t *extra, int extralen) {
    uint8_t h[32];
    memset(h, 0, sizeof h);
    h[0] = 1; h[1] = detail;
    p16(h, 2, c->seq);
    p32(h, 4, (uint32_t)(pad4(extralen) / 4));
    if (body24) memcpy(h + 8, body24, 24);
    cwrite(c, h, 32);
    if (extralen > 0) {
        static const uint8_t z[4] = {0};
        cwrite(c, extra, extralen);
        if (pad4(extralen) != extralen)
            cwrite(c, z, pad4(extralen) - extralen);
    }
}

static void send_error(XClient *c, uint8_t code, uint32_t value,
                       uint8_t major) {
    uint8_t e[32];
    memset(e, 0, sizeof e);
    e[0] = 0; e[1] = code;
    p16(e, 2, c->seq);
    p32(e, 4, value);
    e[10] = major;
    cwrite(c, e, 32);
}

/* Deliver a 32-byte event; ev[2..3] filled with the client's sequence. */
static void send_event(XClient *c, uint8_t *ev) {
    p16(ev, 2, c->seq);
    cwrite(c, ev, 32);
}

/* Event to whichever client selected `mask` on window w. */
static XClient *win_client(XWindow *w) {
    if (w->creator < 0 || w->creator >= MAX_XCLIENTS) return NULL;
    XClient *c = &X.cl[w->creator];
    return (c->fd >= 0 && c->state == 2) ? c : NULL;
}

static void ev_expose(XWindow *w) {
    XClient *c = win_client(w);
    if (!c || !(w->evmask & 0x8000)) return;
    uint8_t ev[32]; memset(ev, 0, sizeof ev);
    ev[0] = 12;
    p32(ev, 4, w->id);
    p16(ev, 8, 0); p16(ev, 10, 0);
    p16(ev, 12, w->w); p16(ev, 14, w->h);
    p16(ev, 16, 0);
    send_event(c, ev);
}

static void ev_map_notify(XWindow *w) {
    XClient *c = win_client(w);
    if (!c || !(w->evmask & 0x20000)) return;   /* StructureNotify */
    uint8_t ev[32]; memset(ev, 0, sizeof ev);
    ev[0] = 19;
    p32(ev, 4, w->id);
    p32(ev, 8, w->id);
    send_event(c, ev);
}

static void ev_configure_notify(XWindow *w) {
    XClient *c = win_client(w);
    if (!c || !(w->evmask & 0x20000)) return;
    uint8_t ev[32]; memset(ev, 0, sizeof ev);
    ev[0] = 22;
    p32(ev, 4, w->id);
    p32(ev, 8, w->id);
    p32(ev, 12, 0);                             /* above-sibling */
    int ox, oy; win_origin(w, &ox, &oy);
    p16(ev, 16, (uint16_t)ox); p16(ev, 18, (uint16_t)oy);
    p16(ev, 20, w->w); p16(ev, 22, w->h);
    p16(ev, 24, w->border);
    send_event(c, ev);
}

/* ── window helpers ───────────────────────────────────────────────────────── */
static void win_fill_bg(XWindow *w) {
    if (!w->px) return;
    uint32_t bg = w->has_bg ? w->bg : 0xffffff;
    for (int i = 0; i < w->w * w->h; i++) w->px[i] = bg;
}

/* ── cursors ──────────────────────────────────────────────────────────────── */
/* X clients request stock shapes with CreateGlyphCursor against the cursor
 * font; the glyph index IS the shape (X11/cursorfont.h). Map the ones real
 * apps use onto the viewer's native cursors; anything unknown becomes an
 * arrow, which is what an unstyled window gets anyway. */
static int cursorfont_to_shape(unsigned glyph) {
    switch (glyph) {
    case 152:                          /* XC_xterm              */
        return RFB_CUR_TEXT;
    case 58: case 60:                  /* XC_hand1, XC_hand2    */
        return RFB_CUR_POINTER;
    case 30: case 32: case 34: case 90: case 130:
        return RFB_CUR_CROSSHAIR;      /* cross/crosshair/plus/tcross */
    case 26: case 150:                 /* XC_clock, XC_watch    */
        return RFB_CUR_WAIT;
    case 52: case 120:                 /* XC_fleur, XC_sizing   */
        return RFB_CUR_MOVE;
    case 16: case 116: case 138:       /* bottom_side, sb_v_double_arrow,
                                        * top_side              */
        return RFB_CUR_NS_RESIZE;
    case 70: case 96: case 108:        /* left_side, right_side,
                                        * sb_h_double_arrow     */
        return RFB_CUR_EW_RESIZE;
    case 14: case 134:                 /* bottom_right/top_left corner */
        return RFB_CUR_NWSE_RESIZE;
    case 12: case 136:                 /* bottom_left/top_right corner */
        return RFB_CUR_NESW_RESIZE;
    default:                           /* XC_left_ptr(68), XC_arrow(2), … */
        return RFB_CUR_DEFAULT;
    }
}

/* Cursor XID → shape. Clients name cursors by XID in window attributes, so
 * remember what each created cursor meant. */
#define MAX_CURSORS 64
static struct { uint32_t id; int shape; } cursors[MAX_CURSORS];

static void cursor_define(uint32_t id, int shape) {
    for (int i = 0; i < MAX_CURSORS; i++)
        if (cursors[i].id == id || !cursors[i].id) {
            cursors[i].id = id;
            cursors[i].shape = shape;
            return;
        }
}

static int cursor_id_shape(uint32_t id) {
    if (!id) return RFB_CUR_DEFAULT;            /* CopyFromParent/None */
    for (int i = 0; i < MAX_CURSORS; i++)
        if (cursors[i].id == id) return cursors[i].shape;
    return RFB_CUR_DEFAULT;
}

/* Cursor of the window under the pointer, inherited from its ancestors the
 * way X does it (a window with no cursor of its own shows its parent's). */
static int cursor_for(XWindow *w) {
    while (w) {
        if (w->cursor >= 0) return w->cursor;
        if (w->id == ROOT_ID) break;
        w = find_win(w->parent);
    }
    return RFB_CUR_DEFAULT;
}

/* ── stacking ─────────────────────────────────────────────────────────────── */
static int stack_index(uint32_t id) {
    for (int i = 0; i < X.nstack; i++) if (X.stack[i] == id) return i;
    return -1;
}

static void stack_add(uint32_t id) {          /* new windows arrive on top */
    if (stack_index(id) >= 0 || X.nstack >= MAX_WINDOWS) return;
    memmove(X.stack + 1, X.stack, (size_t)X.nstack * sizeof X.stack[0]);
    X.stack[0] = id;
    X.nstack++;
}

static void stack_remove(uint32_t id) {
    int i = stack_index(id);
    if (i < 0) return;
    memmove(X.stack + i, X.stack + i + 1,
            (size_t)(X.nstack - i - 1) * sizeof X.stack[0]);
    X.nstack--;
}

static int stack_raise(uint32_t id) {         /* returns 1 if order changed */
    int i = stack_index(id);
    if (i <= 0) return 0;                     /* absent, or already front */
    memmove(X.stack + 1, X.stack, (size_t)i * sizeof X.stack[0]);
    X.stack[0] = id;
    return 1;
}

static int stack_lower(uint32_t id) {
    int i = stack_index(id);
    if (i < 0 || i == X.nstack - 1) return 0;
    memmove(X.stack + i, X.stack + i + 1,
            (size_t)(X.nstack - i - 1) * sizeof X.stack[0]);
    X.stack[X.nstack - 1] = id;
    return 1;
}

/* The top-level whose FRAME (chrome included) covers the point, front-most
 * first. NULL when the point is on bare desktop. */
static XWindow *toplevel_at(int fx, int fy) {
    if (fy >= WORK_H) return NULL;          /* the taskbar is not a window */
    for (int i = 0; i < X.nstack; i++) {
        XWindow *w = find_win(X.stack[i]);
        if (!w || !w->mapped || w->minimized) continue;
        int fw = w->w + 2*RFB_BORDER;
        int fh = RFB_TITLE_H + w->h + RFB_BORDER;
        if (fx >= w->frame.x && fx < w->frame.x + fw &&
            fy >= w->frame.y && fy < w->frame.y + fh)
            return w;
    }
    return NULL;
}

/* Deepest mapped window at the point, respecting stacking: search
 * top-levels front-to-back, then descend into children (later children
 * are drawn on top, so scan them in reverse). */
static XWindow *descend_at(XWindow *w, int fx, int fy) {
    XWindow *best = NULL;
    for (int i = MAX_WINDOWS - 1; i >= 0; i--) {
        XWindow *ch = &X.win[i];
        if (!ch->id || ch->parent != w->id || !ch->mapped) continue;
        int ox, oy;
        win_origin(ch, &ox, &oy);
        if (fx >= ox && fx < ox + ch->w && fy >= oy && fy < oy + ch->h) {
            best = descend_at(ch, fx, fy);
            if (!best) best = ch;
            break;
        }
    }
    return best;
}

static XWindow *deepest_at(int fx, int fy) {
    XWindow *top = toplevel_at(fx, fy);
    if (!top) return NULL;
    int ox, oy;
    win_origin(top, &ox, &oy);
    if (fx < ox || fx >= ox + top->w || fy < oy || fy >= oy + top->h)
        return top;                            /* on the chrome, not content */
    XWindow *child = descend_at(top, fx, fy);
    return child ? child : top;
}

/* ── focus ────────────────────────────────────────────────────────────────── */
/* The top-level that owns the keyboard. Children of the focus window count
 * as focused too — xterm puts its VT in a child of its shell window. */
static int in_focus_tree(XWindow *w) {
    while (w && w->id != ROOT_ID) {
        if (w->id == X.focus) return 1;
        w = find_win(w->parent);
    }
    return 0;
}

static void ev_focus(XWindow *w, int in) {
    XClient *c = win_client(w);
    if (!c || !(w->evmask & 0x200000)) return;   /* FocusChangeMask */
    uint8_t ev[32]; memset(ev, 0, sizeof ev);
    ev[0] = in ? 9 : 10;                          /* FocusIn / FocusOut */
    ev[1] = 0;                                    /* detail: Ancestor */
    p32(ev, 4, w->id);
    ev[8] = 0;                                    /* mode: Normal */
    send_event(c, ev);
}

static void set_focus(uint32_t id) {
    if (X.focus == id) return;
    XWindow *old = find_win(X.focus);
    if (old) ev_focus(old, 0);
    X.focus = id;
    XWindow *neu = find_win(id);
    if (neu) ev_focus(neu, 1);
    if (X.srv) rfb_damage_full(X.srv);            /* title bars restyle */
}

static void free_window(XWindow *w) {
    if (w->id == X.focus)  X.focus = 0;
    if (w->id == X.xfocus) X.xfocus = 0;
    stack_remove(w->id);
    free(w->px);
    memset(w, 0, sizeof *w);
}

static void destroy_children(uint32_t parent) {
    for (int i = 0; i < MAX_WINDOWS; i++)
        if (X.win[i].id && X.win[i].parent == parent && X.win[i].id != ROOT_ID) {
            destroy_children(X.win[i].id);
            free_window(&X.win[i]);
        }
}

/* ── property helpers ─────────────────────────────────────────────────────── */
static void set_prop(XWindow *w, uint32_t atom, uint32_t type, uint8_t fmt,
                     int mode, const uint8_t *data, uint32_t nunits) {
    int unit = fmt / 8;
    if (unit <= 0) return;      /* fmt 0 would div-by-zero (wasm traps) */
    uint32_t bytes = nunits * unit;
    for (int i = 0; i < w->nprops; i++) {
        if (w->props[i].atom == atom) {
            if (mode == 2 || mode == 1) {           /* prepend/append */
                uint32_t old = w->props[i].n * unit;
                if (old + bytes > sizeof w->props[i].data) return;
                if (mode == 1) {                    /* append */
                    memcpy(w->props[i].data + old, data, bytes);
                } else {
                    memmove(w->props[i].data + bytes, w->props[i].data, old);
                    memcpy(w->props[i].data, data, bytes);
                }
                w->props[i].n += nunits;
            } else {                                /* replace */
                if (bytes > sizeof w->props[i].data)
                    bytes = sizeof w->props[i].data;
                memcpy(w->props[i].data, data, bytes);
                w->props[i].n = bytes / unit;
                w->props[i].type = type;
                w->props[i].fmt = fmt;
            }
            return;
        }
    }
    if (w->nprops >= MAX_PROPS) return;
    if (bytes > sizeof w->props[0].data) bytes = sizeof w->props[0].data;
    w->props[w->nprops].atom = atom;
    w->props[w->nprops].type = type;
    w->props[w->nprops].fmt = fmt;
    w->props[w->nprops].n = bytes / unit;
    memcpy(w->props[w->nprops].data, data, bytes);
    w->nprops++;
}

/* ── request processing ───────────────────────────────────────────────────── */
static int xtrace = 0;   /* set by XTINY_TRACE=1 in the environment */

static void process_request(XClient *c, const uint8_t *r, int len) {
    uint8_t op = r[0];
    c->seq++;
    if (xtrace && op != 38) {   /* QueryPointer floods — logged on change */
        printf("[xtiny] op %u len %d seq %u\n", op, len, c->seq);
        fflush(stdout);
    }

    switch (op) {

    case 1: { /* CreateWindow */
        uint32_t wid = g32(r, 4), parent = g32(r, 8);
        int x = gs16(r, 12), y = gs16(r, 14);
        int w = g16(r, 16), h = g16(r, 18), border = g16(r, 20);
        int class_ = g16(r, 22);
        uint32_t vmask = g32(r, 28);
        XWindow *slot = NULL;
        for (int i = 0; i < MAX_WINDOWS; i++)
            if (!X.win[i].id) { slot = &X.win[i]; break; }
        if (!slot) { send_error(c, 11, wid, op); return; }  /* Alloc */
        memset(slot, 0, sizeof *slot);
        slot->cursor = -1;                    /* inherit until told otherwise */
        slot->id = wid; slot->parent = parent;
        slot->x = x; slot->y = y;
        slot->w = w > 0 ? w : 1; slot->h = h > 0 ? h : 1;
        slot->border = border;
        slot->class_ = class_ ? class_ : 1;
        slot->creator = (int)(c - X.cl);
        XWindow *pw = find_win(parent);
        slot->toplevel = (parent == ROOT_ID);
        /* parse the values we honour */
        int vo = 32;
        for (int bit = 0; bit < 15; bit++) {
            if (!(vmask & (1u << bit))) continue;
            uint32_t v = g32(r, vo); vo += 4;
            if (bit == 1) { slot->bg = v & 0xffffff; slot->has_bg = 1; }
            if (bit == 11) slot->evmask = v;
            if (bit == 14) slot->cursor = cursor_id_shape(v);   /* CWCursor */
        }
        if (slot->class_ == 1) {
            slot->px = malloc((size_t)slot->w * slot->h * 4);
            if (slot->px) win_fill_bg(slot);
        }
        if (slot->toplevel) {
            slot->frame.x = 100 + (X.ntoplevel % 5) * 40;
            slot->frame.y = 40 + (X.ntoplevel % 5) * 30;
            slot->frame.w = slot->w;
            slot->frame.h = slot->h;
            snprintf(slot->title, sizeof slot->title, "x11");
            slot->frame.title = slot->title;
            X.ntoplevel++;
        }
        (void)pw;
        printf("[xtiny] CreateWindow id=%#x parent=%#x %dx%d%s\n",
               wid, parent, slot->w, slot->h, slot->toplevel ? " (top)" : "");
        fflush(stdout);
        break;
    }

    case 2: { /* ChangeWindowAttributes */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        uint32_t vmask = g32(r, 8);
        int vo = 12;
        for (int bit = 0; bit < 15; bit++) {
            if (!(vmask & (1u << bit))) continue;
            uint32_t v = g32(r, vo); vo += 4;
            if (bit == 1) { w->bg = v & 0xffffff; w->has_bg = 1; }
            if (bit == 11) {
                if (w->id == ROOT_ID) c->root_evmask = v;
                else w->evmask = v;
            }
            if (bit == 14) {                                   /* CWCursor */
                w->cursor = cursor_id_shape(v);
                if (X.srv && deepest_at(X.ptr_x, X.ptr_y) == w)
                    rfb_set_cursor(X.srv, cursor_for(w));
            }
        }
        break;
    }

    case 3: { /* GetWindowAttributes */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        uint8_t b[24]; memset(b, 0, sizeof b);
        uint8_t extra[12]; memset(extra, 0, sizeof extra);
        p32(b, 0, VISUAL_ID);
        p16(b, 4, (uint16_t)w->class_);
        b[6] = 0; b[7] = 0;
        p32(b, 8, 0); p32(b, 12, 0);
        b[16] = 0;                     /* save_under */
        b[17] = 1;                     /* map_is_installed */
        b[18] = win_visible(w) ? 2 : 0;
        b[19] = 0;                     /* override */
        p32(b, 20, CMAP_ID);
        p32(extra, 0, w->evmask);      /* all event masks */
        p32(extra, 4, w->evmask);      /* your event mask */
        send_reply(c, 0, b, extra, 12);
        break;
    }

    case 4: { /* DestroyWindow */
        XWindow *w = find_win(g32(r, 4));
        if (w && w->id != ROOT_ID) {
            destroy_children(w->id);
            free_window(w);
            if (X.srv) rfb_damage_full(X.srv);
        }
        break;
    }
    case 5: { /* DestroySubwindows */
        destroy_children(g32(r, 4));
        if (X.srv) rfb_damage_full(X.srv);
        break;
    }

    case 8: { /* MapWindow */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        if (!w->mapped) {
            w->mapped = 1;
            if (w->toplevel) {           /* newly shown windows come to front
                                          * and take the keyboard */
                stack_add(w->id);
                stack_raise(w->id);
                set_focus(w->id);
            }
            ev_map_notify(w);
            ev_expose(w);
            if (X.srv) rfb_damage_full(X.srv);
            printf("[xtiny] MapWindow %#x\n", w->id); fflush(stdout);
        }
        break;
    }
    case 9: { /* MapSubwindows */
        uint32_t parent = g32(r, 4);
        for (int i = 0; i < MAX_WINDOWS; i++) {
            XWindow *w = &X.win[i];
            if (w->id && w->parent == parent && !w->mapped) {
                w->mapped = 1;
                ev_map_notify(w);
                ev_expose(w);
            }
        }
        if (X.srv) rfb_damage_full(X.srv);
        break;
    }
    case 10: { /* UnmapWindow */
        XWindow *w = find_win(g32(r, 4));
        if (w && w->mapped) {
            w->mapped = 0;
            if (w->toplevel && w->id == X.focus) {
                /* hand the keyboard to the next visible window down */
                X.focus = 0;
                for (int i = 0; i < X.nstack; i++) {
                    XWindow *n = find_win(X.stack[i]);
                    if (n && n->mapped) { set_focus(n->id); break; }
                }
            }
            if (X.srv) rfb_damage_full(X.srv);
        }
        break;
    }

    case 12: { /* ConfigureWindow */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        uint16_t vmask = g16(r, 8);
        int vo = 12;
        int nw = w->w, nh = w->h;
        for (int bit = 0; bit < 7; bit++) {
            if (!(vmask & (1u << bit))) continue;
            uint32_t v = g32(r, vo); vo += 4;
            if (bit == 0 && !w->toplevel) w->x = (int16_t)v;
            if (bit == 1 && !w->toplevel) w->y = (int16_t)v;
            if (bit == 2) nw = (int)v;
            if (bit == 3) nh = (int)v;
            if (bit == 4) w->border = (int)v;
            if (bit == 6 && w->toplevel) {        /* CWStackMode */
                if ((v & 0xff) == 0) stack_raise(w->id);   /* Above */
                else if ((v & 0xff) == 1) stack_lower(w->id); /* Below */
                if (X.srv) rfb_damage_full(X.srv);
            }
        }
        if ((nw != w->w || nh != w->h) && nw > 0 && nh > 0) {
            free(w->px);
            w->w = nw; w->h = nh;
            w->px = w->class_ == 1 ? malloc((size_t)nw * nh * 4) : NULL;
            if (w->px) win_fill_bg(w);
            if (w->toplevel) { w->frame.w = nw; w->frame.h = nh; }
            ev_configure_notify(w);
            ev_expose(w);
        } else {
            ev_configure_notify(w);
        }
        if (X.srv) rfb_damage_full(X.srv);
        break;
    }

    case 14: { /* GetGeometry */
        Drawable d;
        uint32_t id = g32(r, 4);
        if (!resolve_drawable(id, &d)) { send_error(c, 9, id, op); return; }
        uint8_t b[24]; memset(b, 0, sizeof b);
        p32(b, 0, ROOT_ID);
        if (d.win) {
            p16(b, 4, (uint16_t)d.win->x); p16(b, 6, (uint16_t)d.win->y);
        }
        p16(b, 8, (uint16_t)d.w); p16(b, 10, (uint16_t)d.h);
        p16(b, 12, d.win ? (uint16_t)d.win->border : 0);
        send_reply(c, 24, b, NULL, 0);
        break;
    }

    case 15: { /* QueryTree */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        uint32_t kids[MAX_WINDOWS]; int nk = 0;
        for (int i = 0; i < MAX_WINDOWS; i++)
            if (X.win[i].id && X.win[i].parent == w->id &&
                X.win[i].id != ROOT_ID)
                kids[nk++] = X.win[i].id;
        uint8_t b[24]; memset(b, 0, sizeof b);
        p32(b, 0, ROOT_ID);
        p32(b, 4, w->id == ROOT_ID ? 0 : w->parent);
        p16(b, 8, (uint16_t)nk);
        uint8_t extra[MAX_WINDOWS * 4];
        for (int i = 0; i < nk; i++) p32(extra, i * 4, kids[i]);
        send_reply(c, 0, b, extra, nk * 4);
        break;
    }

    case 16: { /* InternAtom */
        int only = r[1];
        int n = g16(r, 4);
        const char *name = (const char *)r + 8;
        uint32_t atom = 0;
        for (int i = 1; i <= NPREATOMS; i++)
            if ((int)strlen(PREATOMS[i]) == n && !memcmp(PREATOMS[i], name, n))
                { atom = (uint32_t)i; break; }
        if (!atom) {
            for (int i = 0; i < X.ndynatoms; i++)
                if ((int)strlen(X.dynatoms[i]) == n &&
                    !memcmp(X.dynatoms[i], name, n))
                    { atom = 100u + i; break; }
        }
        if (!atom && !only && X.ndynatoms < MAX_DYNATOMS && n < 63) {
            memcpy(X.dynatoms[X.ndynatoms], name, n);
            X.dynatoms[X.ndynatoms][n] = 0;
            atom = 100u + X.ndynatoms;
            X.ndynatoms++;
        }
        if (xtrace) {
            printf("[xtiny]   InternAtom '%.*s' -> %u\n", n, name, atom);
            fflush(stdout);
        }
        uint8_t b[24]; memset(b, 0, sizeof b);
        p32(b, 0, atom);
        send_reply(c, 0, b, NULL, 0);
        break;
    }

    case 17: { /* GetAtomName */
        uint32_t atom = g32(r, 4);
        const char *name = "";
        if (atom >= 1 && atom <= NPREATOMS) name = PREATOMS[atom];
        else if (atom >= 100 && atom < 100u + X.ndynatoms)
            name = X.dynatoms[atom - 100];
        uint8_t b[24]; memset(b, 0, sizeof b);
        p16(b, 0, (uint16_t)strlen(name));
        send_reply(c, 0, b, (const uint8_t *)name, (int)strlen(name));
        break;
    }

    case 18: { /* ChangeProperty */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        uint32_t prop = g32(r, 8), type = g32(r, 12);
        uint8_t fmt = r[16];
        uint32_t n = g32(r, 20);
        set_prop(w, prop, type, fmt, r[1], r + 24, n);
        if (prop == 39 && w->toplevel) {          /* WM_NAME → frame title */
            uint32_t bytes = n * (fmt / 8);
            if (bytes > sizeof w->title - 1) bytes = sizeof w->title - 1;
            memcpy(w->title, r + 24, bytes);
            w->title[bytes] = 0;
            if (X.srv) rfb_damage_full(X.srv);
        }
        break;
    }
    case 19: break; /* DeleteProperty — ignore */

    case 20: { /* GetProperty */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        uint32_t prop = g32(r, 8);
        for (int i = 0; i < w->nprops; i++) {
            if (w->props[i].atom == prop) {
                int unit = w->props[i].fmt / 8;
                int bytes = (int)w->props[i].n * unit;
                uint8_t b[24]; memset(b, 0, sizeof b);
                p32(b, 0, w->props[i].type);
                p32(b, 4, 0);                     /* bytes_after */
                p32(b, 8, w->props[i].n);
                send_reply(c, w->props[i].fmt, b, w->props[i].data, bytes);
                return;
            }
        }
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);             /* None */
        break;
    }

    case 21: { /* ListProperties */
        XWindow *w = find_win(g32(r, 4));
        uint8_t b[24]; memset(b, 0, sizeof b);
        uint8_t extra[MAX_PROPS * 4];
        int n = 0;
        if (w) for (int i = 0; i < w->nprops; i++) p32(extra, n++ * 4, w->props[i].atom);
        p16(b, 0, (uint16_t)n);
        send_reply(c, 0, b, extra, n * 4);
        break;
    }

    case 23: { /* GetSelectionOwner */
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);             /* owner = None */
        break;
    }

    case 26: case 31: { /* GrabPointer / GrabKeyboard — always granted */
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);             /* status = Success */
        break;
    }

    /* The void half of the grab family: UngrabPointer(27), GrabButton(28),
     * UngrabButton(29), ChangeActivePointerGrab(30), UngrabKeyboard(32),
     * GrabKey(33), UngrabKey(34), AllowEvents(35). Nothing to do — this
     * server delivers events to the window under the pointer and has no
     * grab state — but they must be accepted silently: erroring on a
     * void request makes Xlib's default handler abort the client. */
    case 27: case 28: case 29: case 30:
    case 32: case 33: case 34: case 35:
        break;

    case 39: { /* GetMotionEvents — no motion history is kept */
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);             /* n events = 0 */
        break;
    }

    case 36: case 37: break;   /* GrabServer / UngrabServer */

    case 42: { /* SetInputFocus — honour it; clients move focus themselves
                * (xterm does on click), and ignoring it would strand the
                * keyboard on the wrong window. */
        uint32_t id = g32(r, 4);
        XWindow *w = find_win(id);
        if (w) {
            X.xfocus = w->id;                    /* remember the EXACT window */
            while (w && w->id != ROOT_ID && !w->toplevel)
                w = find_win(w->parent);         /* …and its top-level */
            if (w && w->toplevel) set_focus(w->id);
        }
        break;
    }

    case 38: { /* QueryPointer */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        int ox = 0, oy = 0;
        win_origin(w, &ox, &oy);
        if (xtrace) {
            static int lx = -1, ly = -1;
            if (X.ptr_x != lx || X.ptr_y != ly) {
                lx = X.ptr_x; ly = X.ptr_y;
                printf("[xtiny]   QueryPointer win=%#x root=(%d,%d) rel=(%d,%d)\n",
                       w->id, X.ptr_x, X.ptr_y, X.ptr_x - ox, X.ptr_y - oy);
                fflush(stdout);
            }
        }
        uint8_t b[24]; memset(b, 0, sizeof b);
        p32(b, 0, ROOT_ID);                       /* root */
        p32(b, 4, 0);                             /* child = None */
        p16(b, 8, (uint16_t)X.ptr_x); p16(b, 10, (uint16_t)X.ptr_y);
        p16(b, 12, (uint16_t)(X.ptr_x - ox));
        p16(b, 14, (uint16_t)(X.ptr_y - oy));
        p16(b, 16, X.btn_state);
        send_reply(c, 1, b, NULL, 0);             /* same_screen */
        break;
    }

    case 40: { /* TranslateCoordinates */
        XWindow *src = find_win(g32(r, 4));
        XWindow *dst = find_win(g32(r, 8));
        if (!src || !dst) { send_error(c, 3, 0, op); return; }
        int sx, sy, dx, dy;
        win_origin(src, &sx, &sy);
        win_origin(dst, &dx, &dy);
        int x = gs16(r, 12), y = gs16(r, 14);
        uint8_t b[24]; memset(b, 0, sizeof b);
        p32(b, 0, 0);                             /* child = None */
        p16(b, 4, (uint16_t)(sx + x - dx));
        p16(b, 6, (uint16_t)(sy + y - dy));
        send_reply(c, 1, b, NULL, 0);
        break;
    }

    case 43: { /* GetInputFocus — also xcb's sync vehicle */
        uint8_t b[24]; memset(b, 0, sizeof b);
        p32(b, 0, X.focus ? X.focus : 1);         /* focus, else PointerRoot */
        send_reply(c, 1, b, NULL, 0);             /* revert-to: PointerRoot */
        break;
    }
    case 44: { /* QueryKeymap */
        uint8_t keys[32]; memset(keys, 0, sizeof keys);
        uint8_t b[24]; memset(b, 0, sizeof b);
        memcpy(b, keys, 24);
        send_reply(c, 0, b, keys + 24, 8);
        break;
    }

    /* ── fonts: one built-in bitmap font (the kernel's VGA 8×16) serves
     * every name; monospace metrics let QueryFont return zero per-char
     * infos (clients then use min/max bounds, the fixed-width fast path).
     * This is what unlocks xterm-class clients. ── */

    case 45: case 46: break;   /* OpenFont / CloseFont — every fid works */

    case 47: { /* QueryFont */
        uint8_t rep[60];
        memset(rep, 0, sizeof rep);
        rep[0] = 1;
        p16(rep, 2, c->seq);
        p32(rep, 4, (60 - 32) / 4);
        /* min_bounds / max_bounds: lb, rb, width, ascent, descent, attrs */
        for (int off = 8; off <= 24; off += 16) {
            p16(rep, off + 0, 0);
            p16(rep, off + 2, XFONT_W);
            p16(rep, off + 4, XFONT_W);
            p16(rep, off + 6, XFONT_ASCENT);
            p16(rep, off + 8, XFONT_DESCENT);
            p16(rep, off + 10, 0);
        }
        p16(rep, 40, 0);            /* min_char_or_byte2 */
        p16(rep, 42, 255);          /* max_char_or_byte2 */
        p16(rep, 44, 32);           /* default_char */
        p16(rep, 46, 0);            /* n font properties */
        rep[48] = 0;                /* draw direction LTR */
        rep[51] = 1;                /* all_chars_exist */
        p16(rep, 52, XFONT_ASCENT);
        p16(rep, 54, XFONT_DESCENT);
        p32(rep, 56, 0);            /* n charinfos = 0 → use bounds */
        cwrite(c, rep, 60);
        break;
    }

    case 48: { /* QueryTextExtents */
        int odd = r[1];
        int n = (len - 8) / 2 - (odd ? 1 : 0);
        if (n < 0) n = 0;
        uint8_t b[24]; memset(b, 0, sizeof b);
        p16(b, 0, XFONT_ASCENT); p16(b, 2, XFONT_DESCENT);
        p16(b, 4, XFONT_ASCENT); p16(b, 6, XFONT_DESCENT);
        p32(b, 8, (uint32_t)(n * XFONT_W));   /* overall width */
        p32(b, 12, 0);                        /* overall left  */
        p32(b, 16, (uint32_t)(n * XFONT_W));  /* overall right */
        send_reply(c, 0, b, NULL, 0);
        break;
    }

    case 49: { /* ListFonts */
        static const char *names[] = { "fixed", "8x16" };
        uint8_t extra[32]; int elen = 0;
        for (int i = 0; i < 2; i++) {
            int n = (int)strlen(names[i]);
            extra[elen++] = (uint8_t)n;
            memcpy(extra + elen, names[i], n);
            elen += n;
        }
        uint8_t b[24]; memset(b, 0, sizeof b);
        p16(b, 0, 2);               /* number of names */
        send_reply(c, 0, b, extra, elen);
        break;
    }

    case 50: { /* ListFontsWithInfo — reply the series terminator only */
        uint8_t rep[60];
        memset(rep, 0, sizeof rep);
        rep[0] = 1;
        rep[1] = 0;                 /* name length 0 = last in series */
        p16(rep, 2, c->seq);
        p32(rep, 4, (60 - 32) / 4);
        cwrite(c, rep, 60);
        break;
    }

    case 51: break;            /* SetFontPath — ignore */
    case 52: { /* GetFontPath */
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);   /* zero path elements */
        break;
    }

    case 53: { /* CreatePixmap */
        uint32_t pid = g32(r, 4);
        int w = g16(r, 12), h = g16(r, 14);
        XPixmap *slot = NULL;
        for (int i = 0; i < MAX_PIXMAPS; i++)
            if (!X.pix[i].id) { slot = &X.pix[i]; break; }
        if (!slot) { send_error(c, 11, pid, op); return; }
        slot->id = pid; slot->w = w > 0 ? w : 1; slot->h = h > 0 ? h : 1;
        slot->px = calloc((size_t)slot->w * slot->h, 4);
        slot->creator = (int)(c - X.cl);
        break;
    }
    case 54: { /* FreePixmap */
        XPixmap *p = find_pix(g32(r, 4));
        if (p && p->id) { free(p->px); memset(p, 0, sizeof *p); }
        break;
    }

    case 55: { /* CreateGC */
        uint32_t gid = g32(r, 4);
        XGC *slot = NULL;
        for (int i = 0; i < MAX_GCS; i++)
            if (!X.gc[i].id) { slot = &X.gc[i]; break; }
        if (!slot) { send_error(c, 11, gid, op); return; }
        slot->id = gid; slot->fg = 0; slot->bg = 0xffffff;
        slot->creator = (int)(c - X.cl);
        uint32_t vmask = g32(r, 12);
        int vo = 16;
        for (int bit = 0; bit < 23; bit++) {
            if (!(vmask & (1u << bit))) continue;
            uint32_t v = g32(r, vo); vo += 4;
            if (bit == 2) slot->fg = v & 0xffffff;
            if (bit == 3) slot->bg = v & 0xffffff;
        }
        break;
    }
    case 56: { /* ChangeGC */
        XGC *gc = find_gc(g32(r, 4));
        if (!gc) { send_error(c, 13, g32(r, 4), op); return; }
        uint32_t vmask = g32(r, 8);
        int vo = 12;
        for (int bit = 0; bit < 23; bit++) {
            if (!(vmask & (1u << bit))) continue;
            uint32_t v = g32(r, vo); vo += 4;
            if (bit == 2) gc->fg = v & 0xffffff;
            if (bit == 3) gc->bg = v & 0xffffff;
        }
        break;
    }
    case 57: { /* CopyGC */
        XGC *src = find_gc(g32(r, 4)), *dst = find_gc(g32(r, 8));
        if (src && dst) { dst->fg = src->fg; dst->bg = src->bg; }
        break;
    }
    case 59: break; /* SetClipRectangles — ignore */
    case 60: { /* FreeGC */
        XGC *gc = find_gc(g32(r, 4));
        if (gc) memset(gc, 0, sizeof *gc);
        break;
    }

    case 61: { /* ClearArea */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        int x = gs16(r, 8), y = gs16(r, 10);
        int cw = g16(r, 12), ch = g16(r, 14);
        if (cw == 0) cw = w->w - x;
        if (ch == 0) ch = w->h - y;
        Drawable d = { w->px, w->w, w->h, w };
        dfill_rect(&d, x, y, cw, ch, w->has_bg ? w->bg : 0xffffff);
        damage_window(w);
        if (r[1]) {                                /* exposures wanted */
            XClient *cc = win_client(w);
            if (cc && (w->evmask & 0x8000)) {
                uint8_t ev[32]; memset(ev, 0, sizeof ev);
                ev[0] = 12;
                p32(ev, 4, w->id);
                p16(ev, 8, (uint16_t)x); p16(ev, 10, (uint16_t)y);
                p16(ev, 12, (uint16_t)cw); p16(ev, 14, (uint16_t)ch);
                send_event(cc, ev);
            }
        }
        break;
    }

    case 62: { /* CopyArea */
        Drawable src, dst;
        if (!resolve_drawable(g32(r, 4), &src) ||
            !resolve_drawable(g32(r, 8), &dst)) { send_error(c, 9, 0, op); return; }
        int sx = gs16(r, 16), sy = gs16(r, 18);
        int dx = gs16(r, 20), dy = gs16(r, 22);
        int w = g16(r, 24), h = g16(r, 26);
        /* Stage through a temp buffer: src and dst are routinely the SAME
         * drawable with overlapping regions (xterm scrolls this way), and
         * a direct forward copy corrupts downward moves. */
        if (src.px && w > 0 && h > 0) {
            uint32_t *tmp = malloc((size_t)w * h * 4);
            if (tmp) {
                for (int j = 0; j < h; j++)
                    for (int i = 0; i < w; i++) {
                        int fx = sx + i, fy = sy + j;
                        tmp[j * w + i] =
                            ((unsigned)fx < (unsigned)src.w &&
                             (unsigned)fy < (unsigned)src.h)
                                ? src.px[fy * src.w + fx] : 0;
                    }
                for (int j = 0; j < h; j++)
                    for (int i = 0; i < w; i++)
                        dput(&dst, dx + i, dy + j, tmp[j * w + i]);
                free(tmp);
            }
        }
        if (dst.win) damage_window(dst.win);
        /* graphics-exposures: report none */
        uint8_t ev[32]; memset(ev, 0, sizeof ev);
        ev[0] = 14;                                /* NoExpose */
        p32(ev, 4, g32(r, 8));
        ev[10] = 62;
        send_event(c, ev);
        break;
    }

    case 64: { /* PolyPoint */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = (len - 12) / 4;
        int px = 0, py = 0;
        for (int i = 0; i < n; i++) {
            int x = gs16(r, 12 + i*4), y = gs16(r, 14 + i*4);
            if (r[1] && i > 0) { x += px; y += py; }
            dput(&d, x, y, gc->fg);
            px = x; py = y;
        }
        if (d.win) damage_window(d.win);
        break;
    }
    case 65: { /* PolyLine */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = (len - 12) / 4;
        int px = 0, py = 0;
        for (int i = 0; i < n; i++) {
            int x = gs16(r, 12 + i*4), y = gs16(r, 14 + i*4);
            if (r[1] && i > 0) { x += px; y += py; }
            if (i > 0) dline(&d, px, py, x, y, gc->fg);
            px = x; py = y;
        }
        if (d.win) damage_window(d.win);
        break;
    }
    case 66: { /* PolySegment */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = (len - 12) / 8;
        for (int i = 0; i < n; i++)
            dline(&d, gs16(r, 12 + i*8), gs16(r, 14 + i*8),
                  gs16(r, 16 + i*8), gs16(r, 18 + i*8), gc->fg);
        if (d.win) damage_window(d.win);
        break;
    }
    case 67: { /* PolyRectangle */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = (len - 12) / 8;
        for (int i = 0; i < n; i++) {
            int x = gs16(r, 12+i*8), y = gs16(r, 14+i*8);
            int w = g16(r, 16+i*8), h = g16(r, 18+i*8);
            dline(&d, x, y, x+w, y, gc->fg);
            dline(&d, x, y+h, x+w, y+h, gc->fg);
            dline(&d, x, y, x, y+h, gc->fg);
            dline(&d, x+w, y, x+w, y+h, gc->fg);
        }
        if (d.win) damage_window(d.win);
        break;
    }
    case 68: { /* PolyArc */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = (len - 12) / 12;
        for (int i = 0; i < n; i++)
            darc_outline(&d, gs16(r, 12+i*12), gs16(r, 14+i*12),
                         g16(r, 16+i*12), g16(r, 18+i*12),
                         gs16(r, 20+i*12), gs16(r, 22+i*12), gc->fg);
        if (d.win) damage_window(d.win);
        break;
    }
    case 69: { /* FillPoly */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = (len - 16) / 4;
        if (n > 64) n = 64;
        int xs[64], ys[64];
        int px = 0, py = 0;
        for (int i = 0; i < n; i++) {
            int x = gs16(r, 16 + i*4), y = gs16(r, 18 + i*4);
            if (r[13] == 1 && i > 0) { x += px; y += py; }  /* Previous mode */
            xs[i] = x; ys[i] = y;
            px = x; py = y;
        }
        dfill_poly(&d, xs, ys, n, gc->fg);
        if (d.win) damage_window(d.win);
        break;
    }
    case 70: { /* PolyFillRectangle */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = (len - 12) / 8;
        for (int i = 0; i < n; i++)
            dfill_rect(&d, gs16(r, 12+i*8), gs16(r, 14+i*8),
                       g16(r, 16+i*8), g16(r, 18+i*8), gc->fg);
        if (d.win) damage_window(d.win);
        break;
    }
    case 71: { /* PolyFillArc — xeyes' bread and butter */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = (len - 12) / 12;
        for (int i = 0; i < n; i++)
            dfill_arc(&d, gs16(r, 12+i*12), gs16(r, 14+i*12),
                      g16(r, 16+i*12), g16(r, 18+i*12),
                      gs16(r, 20+i*12), gs16(r, 22+i*12), gc->fg);
        if (d.win) damage_window(d.win);
        break;
    }

    case 72: { /* PutImage — ZPixmap 24/32bpp only */
        Drawable d;
        if (!resolve_drawable(g32(r, 4), &d)) return;
        int format = r[1];
        int w = g16(r, 12), h = g16(r, 14);
        int dx = gs16(r, 16), dy = gs16(r, 18);
        int depth = r[21];
        if (format == 2 && (depth == 24 || depth == 32)) {
            int stride = w * 4;
            for (int j = 0; j < h; j++)
                for (int i = 0; i < w; i++)
                    dput(&d, dx + i, dy + j,
                         g32(r, 24 + j * stride + i * 4) & 0xffffff);
            if (d.win) damage_window(d.win);
        } else {
            printf("[xtiny] PutImage format=%d depth=%d ignored\n",
                   format, depth);
            fflush(stdout);
        }
        break;
    }

    case 73: { /* GetImage */
        Drawable d;
        if (!resolve_drawable(g32(r, 4), &d) || !d.px) {
            send_error(c, 9, g32(r, 4), op); return;
        }
        int x = gs16(r, 8), y = gs16(r, 10);
        int w = g16(r, 12), h = g16(r, 14);
        uint8_t *buf = malloc((size_t)w * h * 4);
        if (!buf) { send_error(c, 11, 0, op); return; }
        for (int j = 0; j < h; j++)
            for (int i = 0; i < w; i++) {
                int fx = x + i, fy = y + j;
                uint32_t v = 0;
                if ((unsigned)fx < (unsigned)d.w && (unsigned)fy < (unsigned)d.h)
                    v = d.px[fy * d.w + fx];
                p32(buf, (j * w + i) * 4, v);
            }
        uint8_t b[24]; memset(b, 0, sizeof b);
        p32(b, 0, VISUAL_ID);
        send_reply(c, 24, b, buf, w * h * 4);
        free(buf);
        break;
    }

    case 74: { /* PolyText8 — text items with deltas + font-shift items */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int x = gs16(r, 12), y = gs16(r, 14);
        int pos = 16;
        while (pos + 2 <= len) {
            uint8_t l = r[pos];
            if (l == 255) { pos += 5; continue; }     /* font item — one font */
            x += (int8_t)r[pos + 1];
            for (int i = 0; i < l && pos + 2 + i < len; i++) {
                dchar(&d, x, y, r[pos + 2 + i], gc->fg, 0, 0);
                x += XFONT_W;
            }
            pos += 2 + l;
        }
        if (d.win) damage_window(d.win);
        break;
    }
    case 75: { /* PolyText16 */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int x = gs16(r, 12), y = gs16(r, 14);
        int pos = 16;
        while (pos + 2 <= len) {
            uint8_t l = r[pos];
            if (l == 255) { pos += 5; continue; }
            x += (int8_t)r[pos + 1];
            for (int i = 0; i < l && pos + 2 + i*2 + 1 < len; i++) {
                /* CHAR2B big-endian; low page maps to the font directly */
                unsigned ch = r[pos + 2 + i*2] ? '?' : r[pos + 2 + i*2 + 1];
                dchar(&d, x, y, (unsigned char)ch, gc->fg, 0, 0);
                x += XFONT_W;
            }
            pos += 2 + l * 2;
        }
        if (d.win) damage_window(d.win);
        break;
    }
    case 76: { /* ImageText8 — bg cell + glyph */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = r[1];
        int x = gs16(r, 12), y = gs16(r, 14);
        for (int i = 0; i < n; i++) {
            dchar(&d, x, y, r[16 + i], gc->fg, 1, gc->bg);
            x += XFONT_W;
        }
        if (d.win) damage_window(d.win);
        break;
    }
    case 77: { /* ImageText16 */
        Drawable d; XGC *gc = find_gc(g32(r, 8));
        if (!resolve_drawable(g32(r, 4), &d) || !gc) return;
        int n = r[1];
        int x = gs16(r, 12), y = gs16(r, 14);
        for (int i = 0; i < n; i++) {
            unsigned ch = r[16 + i*2] ? '?' : r[16 + i*2 + 1];
            dchar(&d, x, y, (unsigned char)ch, gc->fg, 1, gc->bg);
            x += XFONT_W;
        }
        if (d.win) damage_window(d.win);
        break;
    }

    case 78: case 79: case 80: case 81: case 82:
        break;  /* colormap create/free/install — one static TrueColor map */

    case 83: { /* ListInstalledColormaps — always exactly ours */
        uint8_t b[24]; memset(b, 0, sizeof b);
        p16(b, 0, 1);                       /* number of colormaps */
        uint8_t extra[4];
        p32(extra, 0, CMAP_ID);
        send_reply(c, 0, b, extra, 4);
        break;
    }

    case 84: { /* AllocColor */
        uint32_t red = g16(r, 8), green = g16(r, 10), blue = g16(r, 12);
        uint8_t b[24]; memset(b, 0, sizeof b);
        p16(b, 0, red); p16(b, 2, green); p16(b, 4, blue);
        p32(b, 8, ((red >> 8) << 16) | ((green >> 8) << 8) | (blue >> 8));
        send_reply(c, 0, b, NULL, 0);
        break;
    }
    case 85: { /* AllocNamedColor */
        int n = g16(r, 8);
        uint32_t rgb = 0xbebebe;
        if (!color_lookup((const char *)r + 12, n, &rgb))
            printf("[xtiny] unknown color '%.*s'\n", n, r + 12);
        uint8_t b[24]; memset(b, 0, sizeof b);
        p32(b, 0, rgb);
        uint32_t rr = ((rgb >> 16) & 0xff) * 0x101;
        uint32_t gg = ((rgb >> 8) & 0xff) * 0x101;
        uint32_t bb = (rgb & 0xff) * 0x101;
        p16(b, 4, rr); p16(b, 6, gg); p16(b, 8, bb);
        p16(b, 10, rr); p16(b, 12, gg); p16(b, 14, bb);
        send_reply(c, 0, b, NULL, 0);
        break;
    }
    case 91: { /* QueryColors — 8 bytes of RGB per requested pixel.
                * TrueColor, so each pixel IS its color: expand the 8-bit
                * channels to 16-bit by replication (0xff → 0xffff). */
        int n = (len - 8) / 4;
        if (n < 0) n = 0;
        uint8_t *extra = malloc((size_t)n * 8 + 8);
        if (!extra) { send_error(c, 11, 0, op); return; }
        memset(extra, 0, (size_t)n * 8 + 8);
        for (int i = 0; i < n; i++) {
            uint32_t px = g32(r, 8 + i * 4);
            p16(extra, i*8 + 0, ((px >> 16) & 0xff) * 0x101);
            p16(extra, i*8 + 2, ((px >> 8)  & 0xff) * 0x101);
            p16(extra, i*8 + 4, ( px        & 0xff) * 0x101);
        }
        uint8_t b[24]; memset(b, 0, sizeof b);
        p16(b, 0, (uint16_t)n);             /* number of RGBs */
        send_reply(c, 0, b, extra, n * 8);
        free(extra);
        break;
    }

    case 92: { /* LookupColor */
        int n = g16(r, 8);
        uint32_t rgb = 0xbebebe;
        if (!color_lookup((const char *)r + 12, n, &rgb))
            printf("[xtiny] unknown color '%.*s'\n", n, r + 12);
        uint8_t b[24]; memset(b, 0, sizeof b);
        uint32_t rr = ((rgb >> 16) & 0xff) * 0x101;
        uint32_t gg = ((rgb >> 8) & 0xff) * 0x101;
        uint32_t bb = (rgb & 0xff) * 0x101;
        p16(b, 0, rr); p16(b, 2, gg); p16(b, 4, bb);   /* exact  */
        p16(b, 6, rr); p16(b, 8, gg); p16(b, 10, bb);  /* visual */
        send_reply(c, 0, b, NULL, 0);
        break;
    }

    case 93: { /* CreateCursor — from a bitmap we can't interpret; arrow */
        cursor_define(g32(r, 4), RFB_CUR_DEFAULT);
        break;
    }
    case 94: { /* CreateGlyphCursor — the cursor-font glyph names the shape */
        int shape = cursorfont_to_shape(g16(r, 16));
        cursor_define(g32(r, 4), shape);
        if (xtrace) {
            printf("[xtiny] CreateGlyphCursor id=%#x glyph=%u -> shape=%d\n",
                   g32(r, 4), g16(r, 16), shape);
            fflush(stdout);
        }
        break;
    }
    case 95: { /* FreeCursor */
        uint32_t id = g32(r, 4);
        for (int i = 0; i < MAX_CURSORS; i++)
            if (cursors[i].id == id) { cursors[i].id = 0; break; }
        break;
    }
    case 96: break;  /* RecolorCursor — shape is what matters here */

    case 97: { /* QueryBestSize */
        uint8_t b[24]; memset(b, 0, sizeof b);
        p16(b, 0, g16(r, 8)); p16(b, 2, g16(r, 10));
        send_reply(c, 0, b, NULL, 0);
        break;
    }

    case 98: { /* QueryExtension — nothing is present */
        if (xtrace) {
            int n = g16(r, 4);
            printf("[xtiny]   QueryExtension '%.*s'\n", n, (const char *)r + 8);
            fflush(stdout);
        }
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);
        break;
    }
    case 99: { /* ListExtensions */
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);
        break;
    }

    case 101: { /* GetKeyboardMapping */
        uint8_t first = r[4], count = r[5];
        uint8_t *extra = malloc((size_t)count * 4);
        if (!extra) { send_error(c, 11, 0, op); return; }
        for (int i = 0; i < count; i++)
            p32(extra, i * 4, keycode_to_keysym((uint8_t)(first + i)));
        send_reply(c, 1, NULL, extra, count * 4);   /* 1 keysym/keycode */
        free(extra);
        break;
    }
    case 119: { /* GetModifierMapping */
        uint8_t mods[8] = {119, 123, 120, 121, 0, 0, 0, 0};
        send_reply(c, 1, NULL, mods, 8);            /* 1 keycode/mod */
        break;
    }

    case 102: case 104: case 105: case 113: case 115:
        break;  /* Change{Keyboard,Pointer}Control, Bell, KillClient, … */

    case 103: { /* GetKeyboardControl — 52-byte reply (auto-repeat map) */
        uint8_t rep[52];
        memset(rep, 0, sizeof rep);
        rep[0] = 1;
        rep[1] = 1;                       /* global auto-repeat = On */
        p16(rep, 2, c->seq);
        p32(rep, 4, (52 - 32) / 4);
        p32(rep, 8, 0);                   /* led-mask */
        rep[12] = 50;                     /* key-click-percent */
        rep[13] = 50;                     /* bell-percent */
        p16(rep, 14, 400);                /* bell-pitch */
        p16(rep, 16, 100);                /* bell-duration */
        memset(rep + 20, 0xff, 32);       /* auto-repeats: all keys */
        cwrite(c, rep, 52);
        break;
    }

    case 106: { /* GetPointerControl */
        uint8_t b[24]; memset(b, 0, sizeof b);
        p16(b, 0, 2);                     /* acceleration numerator */
        p16(b, 2, 1);                     /* denominator */
        p16(b, 4, 4);                     /* threshold */
        send_reply(c, 0, b, NULL, 0);
        break;
    }

    case 107: { /* GetScreenSaver */
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);     /* all zero = disabled */
        break;
    }

    case 108: { /* ListHosts */
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 1, b, NULL, 0);     /* access control disabled, 0 hosts */
        break;
    }

    case 116: case 118: { /* Set{Pointer,Modifier}Mapping */
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);     /* status = Success */
        break;
    }

    case 117: { /* GetPointerMapping — identity for 3 buttons */
        uint8_t map[3] = {1, 2, 3};
        send_reply(c, 3, NULL, map, 3);
        break;
    }

    case 127: break; /* NoOperation */

    default: {
        /* Every core opcode is handled above, so this is an extension
         * request (impossible — QueryExtension reports everything
         * absent) or garbage. Answer with an error rather than silence:
         * a request that carries a reply would otherwise hang the client
         * forever, and a hang is far harder to diagnose than an error. */
        printf("[xtiny] unhandled opcode %d (len %d) — BadImplementation\n",
               op, len);
        fflush(stdout);
        send_error(c, 17, 0, op);   /* BadImplementation */
        break;
    }
    }
}

/* ── connection handling ──────────────────────────────────────────────────── */
static void drop_client(XClient *c) {
    if (c->fd < 0) return;
    printf("[xtiny] client %d disconnected\n", (int)(c - X.cl));
    fflush(stdout);
    close(c->fd);
    c->fd = -1;
    c->state = 0;
    int slot = (int)(c - X.cl);
    for (int i = 0; i < MAX_WINDOWS; i++)
        if (X.win[i].id && X.win[i].id != ROOT_ID && X.win[i].creator == slot)
            free_window(&X.win[i]);
    for (int i = 0; i < MAX_PIXMAPS; i++)
        if (X.pix[i].id && X.pix[i].creator == slot) {
            free(X.pix[i].px);
            memset(&X.pix[i], 0, sizeof X.pix[i]);
        }
    for (int i = 0; i < MAX_GCS; i++)
        if (X.gc[i].id && X.gc[i].creator == slot)
            memset(&X.gc[i], 0, sizeof X.gc[i]);
    if (X.srv) rfb_damage_full(X.srv);
}

static void send_setup_reply(XClient *c) {
    uint8_t buf[512];
    memset(buf, 0, sizeof buf);
    const char *vendor = "LinuxOnTab xtiny";
    int vlen = (int)strlen(vendor);
    int nformats = 2;
    int o = 40;                                   /* fixed head is 40 bytes */
    memcpy(buf + o, vendor, vlen);
    o += pad4(vlen);
    /* pixmap formats: depth,bpp,scanline-pad + 5 pad */
    buf[o+0] = 1;  buf[o+1] = 1;  buf[o+2] = 32; o += 8;
    buf[o+0] = 24; buf[o+1] = 32; buf[o+2] = 32; o += 8;
    /* screen */
    int so = o;
    p32(buf, so+0, ROOT_ID);
    p32(buf, so+4, CMAP_ID);
    p32(buf, so+8, 0xffffff);                     /* white */
    p32(buf, so+12, 0x000000);                    /* black */
    p32(buf, so+16, 0);                           /* current input masks */
    p16(buf, so+20, FB_W); p16(buf, so+22, FB_H);
    p16(buf, so+24, FB_W * 254 / 960);            /* mm, ~96 dpi */
    p16(buf, so+26, FB_H * 254 / 960);
    p16(buf, so+28, 1); p16(buf, so+30, 1);       /* installed maps */
    p32(buf, so+32, VISUAL_ID);
    buf[so+36] = 0;                               /* backing: Never */
    buf[so+37] = 0;                               /* save-unders */
    buf[so+38] = 24;                              /* root depth */
    buf[so+39] = 1;                               /* 1 depth */
    o = so + 40;
    /* depth 24, 1 visual */
    buf[o+0] = 24;
    p16(buf, o+2, 1);
    o += 8;
    p32(buf, o+0, VISUAL_ID);
    buf[o+4] = 4;                                 /* TrueColor */
    buf[o+5] = 8;                                 /* bits per rgb */
    p16(buf, o+6, 256);
    p32(buf, o+8, 0xff0000);
    p32(buf, o+12, 0x00ff00);
    p32(buf, o+16, 0x0000ff);
    o += 24;

    buf[0] = 1;                                   /* success */
    p16(buf, 2, 11); p16(buf, 4, 0);
    p16(buf, 6, (uint16_t)((o - 8) / 4));
    p32(buf, 8, 1);                               /* release */
    p32(buf, 12, ((uint32_t)(c - X.cl) + 1u) << 21); /* rid base */
    p32(buf, 16, 0x1fffff);                       /* rid mask */
    p32(buf, 20, 256);                            /* motion buffer */
    p16(buf, 24, (uint16_t)vlen);
    p16(buf, 26, 0xffff);                         /* max request len */
    buf[28] = 1;                                  /* screens */
    buf[29] = (uint8_t)nformats;
    buf[30] = 0;                                  /* LSB first */
    buf[31] = 0;                                  /* bitmap LSB */
    buf[32] = 32; buf[33] = 32;                   /* scanline unit/pad */
    buf[34] = 8; buf[35] = (uint8_t)255;          /* keycodes */
    cwrite(c, buf, o);
}

static void service_client(XClient *c) {
    /* pull available bytes */
    for (;;) {
        if (c->inlen >= (int)sizeof c->inbuf) break;
        ssize_t r = read(c->fd, c->inbuf + c->inlen,
                         sizeof c->inbuf - c->inlen);
        if (r > 0) { c->inlen += (int)r; continue; }
        if (r == 0) { drop_client(c); return; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        drop_client(c);
        return;
    }

    /* handshake */
    if (c->state == 1) {
        if (c->inlen < 12) return;
        int n = g16(c->inbuf, 6), d = g16(c->inbuf, 8);
        int need = 12 + pad4(n) + pad4(d);
        if (c->inlen < need) return;
        memmove(c->inbuf, c->inbuf + need, c->inlen - need);
        c->inlen -= need;
        send_setup_reply(c);
        c->state = 2;
        printf("[xtiny] client %d connected\n", (int)(c - X.cl));
        fflush(stdout);
    }

    /* requests */
    while (c->state == 2 && c->fd >= 0 && c->inlen >= 4) {
        int len = g16(c->inbuf, 2) * 4;
        if (len < 4 || len > (int)sizeof c->inbuf) {
            printf("[xtiny] bad request length %d — dropping client\n", len);
            drop_client(c);
            return;
        }
        if (c->inlen < len) return;
        process_request(c, c->inbuf, len);
        if (c->fd < 0) return;
        memmove(c->inbuf, c->inbuf + len, c->inlen - len);
        c->inlen -= len;
    }
}

/* ── window actions (the title-bar buttons and taskbar drive these) ───────── */
static uint32_t atom_by_name(const char *name) {
    for (int i = 1; i <= NPREATOMS; i++)
        if (!strcmp(PREATOMS[i], name)) return (uint32_t)i;
    for (int i = 0; i < X.ndynatoms; i++)
        if (!strcmp(X.dynatoms[i], name)) return 100u + (uint32_t)i;
    return 0;
}

/* Give the keyboard to the front-most window that is actually visible. */
static void focus_topmost(void) {
    X.focus = 0;
    for (int i = 0; i < X.nstack; i++) {
        XWindow *n = find_win(X.stack[i]);
        if (n && n->mapped && !n->minimized) { set_focus(n->id); return; }
    }
}

/* Politely ask a client to close: the WM_DELETE_WINDOW handshake, which is
 * what lets an app exit cleanly (xterm kills its shell and tears down). A
 * client that never asked for the protocol gets its connection dropped —
 * the same "kill" a real WM falls back to. */
static void close_window(XWindow *w) {
    uint32_t a_prot = atom_by_name("WM_PROTOCOLS");
    uint32_t a_del  = atom_by_name("WM_DELETE_WINDOW");
    int supports = 0;
    if (a_prot && a_del) {
        for (int i = 0; i < w->nprops; i++) {
            if (w->props[i].atom != a_prot || w->props[i].fmt != 32) continue;
            for (uint32_t k = 0; k < w->props[i].n; k++)
                if (g32(w->props[i].data, (int)k * 4) == a_del) supports = 1;
        }
    }
    XClient *c = win_client(w);
    if (supports && c) {
        uint8_t ev[32]; memset(ev, 0, sizeof ev);
        ev[0] = 33;                       /* ClientMessage */
        ev[1] = 32;                       /* format */
        p32(ev, 4, w->id);
        p32(ev, 8, a_prot);
        p32(ev, 12, a_del);
        p32(ev, 16, (uint32_t)rfb_now_ms());
        send_event(c, ev);
        printf("[xtiny] close %#x via WM_DELETE_WINDOW\n", w->id);
    } else if (c) {
        printf("[xtiny] close %#x by dropping the client\n", w->id);
        drop_client(c);
    }
    fflush(stdout);
}

static void resize_window(XWindow *w, int nw, int nh) {
    if (nw < 1) nw = 1;
    if (nh < 1) nh = 1;
    free(w->px);
    w->w = nw; w->h = nh;
    w->px = w->class_ == 1 ? malloc((size_t)nw * nh * 4) : NULL;
    if (w->px) win_fill_bg(w);
    w->frame.w = nw; w->frame.h = nh;
    ev_configure_notify(w);
    ev_expose(w);
}

static void toggle_maximize(XWindow *w) {
    if (w->maxed) {
        w->frame.x = w->save_x; w->frame.y = w->save_y;
        w->maxed = 0;
        resize_window(w, w->save_w, w->save_h);
    } else {
        w->save_x = w->frame.x; w->save_y = w->frame.y;
        w->save_w = w->w;       w->save_h = w->h;
        w->maxed = 1;
        w->frame.x = 0; w->frame.y = 0;
        resize_window(w, FB_W - 2*RFB_BORDER,
                      WORK_H - RFB_TITLE_H - RFB_BORDER);
    }
    if (X.srv) rfb_damage_full(X.srv);
}

static void minimize_window(XWindow *w) {
    w->minimized = 1;
    if (w->id == X.focus) focus_topmost();
    if (X.srv) rfb_damage_full(X.srv);
}

static void restore_window(XWindow *w) {
    w->minimized = 0;
    stack_raise(w->id);
    set_focus(w->id);
    ev_expose(w);
    if (X.srv) rfb_damage_full(X.srv);
}

/* ── launcher ─────────────────────────────────────────────────────────────── */
static const struct {
    const char *label;
    const char *path;
    const char *argv[6];
} LAUNCH[] = {
    { "xterm", "/usr/bin/xterm",
      { "xterm", "-fn", "fixed", "-e", "/bin/sh", NULL } },
    { "eyes",  "/usr/bin/xeyes", { "xeyes", NULL } },
};
#define NLAUNCH ((int)(sizeof LAUNCH / sizeof LAUNCH[0]))

static void spawn(int idx) {
    if (idx < 0 || idx >= NLAUNCH) return;
    pid_t p = fork();
    if (p != 0) {                         /* parent (or fork failure) */
        if (p < 0) perror("[xtiny] fork");
        return;
    }
    /* Child. stdin MUST come from /dev/null: an X client left on the guest
     * console busy-reads it one byte at a time and pegs the single CPU
     * (the documented Xvfb spin). Sockets are CLOEXEC, so exec drops them. */
    setenv("DISPLAY", ":1", 1);
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, 0);
        if (devnull > 2) close(devnull);
    }
    execv(LAUNCH[idx].path, (char *const *)LAUNCH[idx].argv);
    _exit(127);
}

/* ── taskbar ──────────────────────────────────────────────────────────────── */
/* One layout routine feeds both drawing and hit-testing, so a button can
 * never be drawn somewhere it cannot be clicked. */
enum { TB_NONE = 0, TB_LAUNCH, TB_WINDOW };
typedef struct { int x, w, kind, arg; uint32_t win; } TbItem;

static int taskbar_layout(TbItem *it, int max) {
    int n = 0, x = 6;
    for (int i = 0; i < NLAUNCH && n < max; i++) {
        int bw = 12 * (int)strlen(LAUNCH[i].label) + 16;
        it[n].x = x; it[n].w = bw; it[n].kind = TB_LAUNCH;
        it[n].arg = i; it[n].win = 0;
        x += bw + 4;
        n++;
    }
    x += 10;                              /* gap between launchers and list */
    for (int i = 0; i < X.nstack && n < max; i++) {
        XWindow *w = find_win(X.stack[i]);
        if (!w || !w->mapped) continue;
        int bw = 120;
        if (x + bw > FB_W - 70) break;    /* leave room for the clock */
        it[n].x = x; it[n].w = bw; it[n].kind = TB_WINDOW;
        it[n].arg = 0; it[n].win = w->id;
        x += bw + 4;
        n++;
    }
    return n;
}

static void draw_taskbar(rfb_server *s) {
    int y = WORK_H;
    rfb_fill_rect(s, 0, y, FB_W, TASKBAR_H, 0x1E,0x1C,0x1A);
    rfb_fill_rect(s, 0, y, FB_W, 1, 0x50,0x4C,0x48);

    TbItem it[24];
    int n = taskbar_layout(it, 24);
    for (int i = 0; i < n; i++) {
        if (it[i].kind == TB_LAUNCH) {
            rfb_fill_rect(s, it[i].x, y+4, it[i].w, TASKBAR_H-8, 0x3C,0x38,0x34);
            rfb_draw_text(s, it[i].x+8, y+(TASKBAR_H-10)/2,
                          LAUNCH[it[i].arg].label, 0xD8,0xD8,0xD8);
        } else {
            XWindow *w = find_win(it[i].win);
            if (!w) continue;
            int focused = (w->id == X.focus) && !w->minimized;
            uint8_t bg = focused ? 0x50 : 0x2E;
            rfb_fill_rect(s, it[i].x, y+4, it[i].w, TASKBAR_H-8,
                          bg, (uint8_t)(bg-4), (uint8_t)(bg-8));
            const char *t = w->title[0] ? w->title : "x11";
            /* clip the label to the button */
            char lbl[12];
            int max = (it[i].w - 12) / 12;
            if (max > (int)sizeof lbl - 1) max = (int)sizeof lbl - 1;
            int k = 0;
            for (; t[k] && k < max; k++) lbl[k] = t[k];
            lbl[k] = 0;
            uint8_t fg = w->minimized ? 0x88 : 0xE0;
            rfb_draw_text(s, it[i].x+6, y+(TASKBAR_H-10)/2, lbl, fg, fg, fg);
        }
    }

    /* clock, right-aligned */
    time_t now = time(NULL);
    struct tm tmv;
    if (localtime_r(&now, &tmv)) {
        char buf[8];
        snprintf(buf, sizeof buf, "%02d:%02d", tmv.tm_hour, tmv.tm_min);
        rfb_draw_text(s, FB_W - 62, y+(TASKBAR_H-10)/2, buf, 0xC0,0xC0,0xC0);
    }
}

/* Returns 1 if the click was consumed by the taskbar. */
static int taskbar_click(rfb_server *s, int x, int y) {
    if (y < WORK_H) return 0;
    TbItem it[24];
    int n = taskbar_layout(it, 24);
    for (int i = 0; i < n; i++) {
        if (x < it[i].x || x >= it[i].x + it[i].w) continue;
        if (it[i].kind == TB_LAUNCH) {
            spawn(it[i].arg);
        } else {
            XWindow *w = find_win(it[i].win);
            if (!w) return 1;
            if (w->minimized)            restore_window(w);
            else if (w->id == X.focus)   minimize_window(w);   /* click again */
            else { stack_raise(w->id); set_focus(w->id); rfb_damage_full(s); }
        }
        return 1;
    }
    return 1;      /* bare taskbar — still ours, don't leak it to a window */
}

/* ── librfb callbacks ─────────────────────────────────────────────────────── */
static void on_idle(rfb_server *s) {
    X.srv = s;

    /* Reap launched apps so they don't linger as zombies. */
    while (waitpid(-1, NULL, WNOHANG) > 0) { }

    /* The clock only changes once a minute; damage it then, so an idle
     * desktop still sends the odd tiny update instead of a full frame. */
    {
        static int last_min = -1;
        time_t now = time(NULL);
        struct tm tmv;
        if (localtime_r(&now, &tmv) && tmv.tm_min != last_min) {
            last_min = tmv.tm_min;
            rfb_damage(s, FB_W - 70, WORK_H, 70, TASKBAR_H);
        }
    }
    /* accept new X clients */
    for (;;) {
        int fd = accept(X.lfd, NULL, NULL);
        if (fd < 0) break;
        int fl = fcntl(fd, F_GETFL, 0);
        if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        fcntl(fd, F_SETFD, FD_CLOEXEC);   /* launched apps must not inherit */
        XClient *slot = NULL;
        for (int i = 0; i < MAX_XCLIENTS; i++)
            if (X.cl[i].fd < 0) { slot = &X.cl[i]; break; }
        if (!slot) { close(fd); continue; }
        memset(slot, 0, sizeof *slot);
        slot->fd = fd;
        slot->state = 1;
    }
    for (int i = 0; i < MAX_XCLIENTS; i++)
        if (X.cl[i].fd >= 0) service_client(&X.cl[i]);
}

static void blit_window(rfb_server *s, XWindow *w, int ox, int oy) {
    uint8_t *fb = rfb_fb(s);
    int fw = rfb_w(s), fh = rfb_h(s);
    if (w->px) {
        for (int j = 0; j < w->h; j++) {
            int fy = oy + j;
            if ((unsigned)fy >= (unsigned)fh) continue;
            for (int i = 0; i < w->w; i++) {
                int fx = ox + i;
                if ((unsigned)fx >= (unsigned)fw) continue;
                uint32_t v = w->px[j * w->w + i] | 0xff000000u;
                memcpy(fb + ((size_t)fy * fw + fx) * 4, &v, 4);
            }
        }
    }
    /* children (relative to this window's origin) */
    for (int i = 0; i < MAX_WINDOWS; i++) {
        XWindow *ch = &X.win[i];
        if (ch->id && ch->parent == w->id && ch->mapped)
            blit_window(s, ch, ox + ch->x, oy + ch->y);
    }
}

static void render(rfb_server *s) {
    X.srv = s;
    rfb_draw_desktop(s);
    /* back to front, so the front-most window lands on top */
    for (int i = X.nstack - 1; i >= 0; i--) {
        XWindow *w = find_win(X.stack[i]);
        if (!w || !w->toplevel || !w->mapped || w->minimized) continue;
        w->frame.title = w->title[0] ? w->title : "x11";
        w->frame.inactive = (w->id != X.focus);
        rfb_draw_winframe(s, &w->frame);
        blit_window(s, w, rfb_winframe_cx(&w->frame),
                    rfb_winframe_cy(&w->frame));
    }
    draw_taskbar(s);          /* always on top of the windows */
}

static void on_pointer(rfb_server *s, int buttons, int x, int y) {
    X.srv = s;
    X.ptr_x = x; X.ptr_y = y;

    /* Click-to-raise/focus, before anything else looks at the click: a
     * press on any part of a window (chrome or content) brings it to the
     * front and gives it the keyboard. */
    static int prev_btn1 = 0;
    static int swallow_drag = 0;      /* press consumed by a button/taskbar */
    int btn1 = buttons & 1;
    if (btn1 && !prev_btn1) {
        if (taskbar_click(s, x, y)) {
            swallow_drag = 1;
            prev_btn1 = btn1;
            X.btn_state = 0;
            return;
        }
        XWindow *top = toplevel_at(x, y);
        if (top) {
            /* title-bar buttons act on press, and must not start a drag */
            int b = rfb_winframe_button_at(&top->frame, x, y);
            if (b != RFB_BTN_NONE) {
                swallow_drag = 1;
                if (stack_raise(top->id)) rfb_damage_full(s);
                set_focus(top->id);
                if (b == RFB_BTN_CLOSE)     close_window(top);
                else if (b == RFB_BTN_MIN)  minimize_window(top);
                else                        toggle_maximize(top);
                prev_btn1 = btn1;
                X.btn_state = 0;
                return;
            }
            if (stack_raise(top->id)) rfb_damage_full(s);
            set_focus(top->id);
        }
    }
    if (!btn1) swallow_drag = 0;
    prev_btn1 = btn1;

    /* Frame dragging — only the front-most window under the pointer, so a
     * drag can't grab a window buried beneath another. */
    if (!swallow_drag) {
        XWindow *top = toplevel_at(x, y);
        for (int i = 0; i < MAX_WINDOWS; i++) {
            XWindow *w = &X.win[i];
            if (!w->id || !w->toplevel || !w->mapped || w->minimized) continue;
            if (w != top && !w->frame.dragging) continue;
            if (rfb_winframe_pointer(s, &w->frame, buttons, x, y)) {
                /* keep the title bar reachable: never let a window be
                 * dragged down behind the taskbar */
                if (w->frame.y > WORK_H - RFB_TITLE_H)
                    w->frame.y = WORK_H - RFB_TITLE_H;
                rfb_damage_full(s);
            }
        }
    }

    uint16_t newstate = 0;
    if (buttons & 1) newstate |= 0x100;
    if (buttons & 2) newstate |= 0x200;
    if (buttons & 4) newstate |= 0x400;

    XWindow *w = deepest_at(x, y);
    if (w) {
        XClient *c = win_client(w);
        int ox, oy;
        win_origin(w, &ox, &oy);
        uint32_t t = (uint32_t)rfb_now_ms();
        if (c) {
            /* buttons: press/release events */
            for (int b = 0; b < 3; b++) {
                uint16_t bit = (uint16_t)(0x100 << b);
                int was = (X.btn_state & bit) != 0;
                int now = (newstate & bit) != 0;
                if (was == now) continue;
                uint32_t need = now ? 0x4 : 0x8;
                if (!(w->evmask & need)) continue;
                uint8_t ev[32]; memset(ev, 0, sizeof ev);
                ev[0] = now ? 4 : 5;
                ev[1] = (uint8_t)(b + 1);
                p32(ev, 4, t);
                p32(ev, 8, ROOT_ID);
                p32(ev, 12, w->id);
                p32(ev, 16, 0);
                p16(ev, 20, (uint16_t)x); p16(ev, 22, (uint16_t)y);
                p16(ev, 24, (uint16_t)(x - ox)); p16(ev, 26, (uint16_t)(y - oy));
                p16(ev, 28, (uint16_t)(X.btn_state | X.mod_state));
                ev[30] = 1;
                send_event(c, ev);
            }
            /* motion */
            if (w->evmask & 0x40) {
                uint8_t ev[32]; memset(ev, 0, sizeof ev);
                ev[0] = 6;
                p32(ev, 4, t);
                p32(ev, 8, ROOT_ID);
                p32(ev, 12, w->id);
                p32(ev, 16, 0);
                p16(ev, 20, (uint16_t)x); p16(ev, 22, (uint16_t)y);
                p16(ev, 24, (uint16_t)(x - ox)); p16(ev, 26, (uint16_t)(y - oy));
                p16(ev, 28, (uint16_t)(newstate | X.mod_state));
                ev[30] = 1;
                send_event(c, ev);
            }
        }
    }
    X.btn_state = newstate;

    /* Follow the pointer with the right cursor shape. The frame chrome is
     * OURS, not the client's, so it always shows the plain arrow — without
     * this the title bar inherits the app's cursor (an I-beam over xterm's
     * title bar, which is wrong and looks broken). */
    {
        int on_chrome = 0;
        if (w) {
            XWindow *t = w;
            while (t && !t->toplevel && t->id != ROOT_ID) t = find_win(t->parent);
            if (t && t->toplevel) {
                int cx = rfb_winframe_cx(&t->frame), cy = rfb_winframe_cy(&t->frame);
                on_chrome = (x < cx || x >= cx + t->w || y < cy || y >= cy + t->h);
            }
        }
        int shape = (w && !on_chrome) ? cursor_for(w) : RFB_CUR_DEFAULT;
        if (xtrace && shape != X.cursor_shape) {
            X.cursor_shape = shape;
            printf("[xtiny] cursor: win=%#x own=%d -> shape=%d\n",
                   w ? w->id : 0, w ? w->cursor : -99, shape);
            fflush(stdout);
        }
        rfb_set_cursor(s, shape);
    }
}

static void on_key(rfb_server *s, uint32_t ks, int down) {
    X.srv = s;
    /* Track modifiers so KeyPress state fields are right — xterm feeds the
     * state into XLookupString, which is how Ctrl+C becomes ^C. */
    uint16_t mbit = 0;
    switch (ks) {
    case 0xffe1: case 0xffe2: mbit = 1; break;   /* Shift    */
    case 0xffe5:              mbit = 2; break;   /* CapsLock */
    case 0xffe3: case 0xffe4: mbit = 4; break;   /* Control  */
    case 0xffe9: case 0xffea: mbit = 8; break;   /* Alt/Mod1 */
    }
    if (mbit) {
        if (down) X.mod_state |= mbit;
        else      X.mod_state &= (uint16_t)~mbit;
    }
    uint8_t code = keysym_to_keycode(ks);
    if (!code) return;

    /* Deliver to the FOCUS window, not whatever the pointer happens to be
     * over. Focus is a top-level, but the widget that selected for key
     * events is usually a child (xterm's VT window), so hand the event to
     * the deepest descendant that actually asked for it. */
    XWindow *top = find_win(X.focus);
    if (!top) {
        if (xtrace) { printf("[xtiny] key: no focus window\n"); fflush(stdout); }
        return;
    }
    uint32_t need = down ? 0x1 : 0x2;

    /* Pick the window that will actually ACT on the key, innermost first:
     * the client's own SetInputFocus target, else the deepest descendant
     * that selected for key events, else the top-level itself. Delivering
     * to the top-level when a child is the real consumer silently drops
     * every keystroke — xterm's shell window selects for keys but only
     * its VT child has key actions. */
    XWindow *w = NULL;
    XWindow *xf = find_win(X.xfocus);
    if (xf && xf->mapped && (xf->evmask & need) && in_focus_tree(xf)) {
        w = xf;
    } else {
        for (int i = 0; i < MAX_WINDOWS; i++) {
            XWindow *ch = &X.win[i];
            if (!ch->id || ch->id == ROOT_ID || !ch->mapped) continue;
            if (ch->toplevel || !(ch->evmask & need)) continue;
            if (in_focus_tree(ch)) w = ch;        /* later = deeper/newer */
        }
        if (!w && (top->evmask & need)) w = top;
    }
    if (xtrace) {
        printf("[xtiny] key: focus=%#x xfocus=%#x -> target=%#x\n",
               X.focus, X.xfocus, w ? w->id : 0);
        fflush(stdout);
    }
    if (!w) return;
    XClient *c = win_client(w);
    if (!c) return;
    int ox, oy;
    win_origin(w, &ox, &oy);
    uint8_t ev[32]; memset(ev, 0, sizeof ev);
    ev[0] = down ? 2 : 3;
    ev[1] = code;
    p32(ev, 4, (uint32_t)rfb_now_ms());
    p32(ev, 8, ROOT_ID);
    p32(ev, 12, w->id);
    p32(ev, 16, 0);
    p16(ev, 20, (uint16_t)X.ptr_x); p16(ev, 22, (uint16_t)X.ptr_y);
    p16(ev, 24, (uint16_t)(X.ptr_x - ox)); p16(ev, 26, (uint16_t)(X.ptr_y - oy));
    p16(ev, 28, (uint16_t)(X.btn_state | X.mod_state));
    ev[30] = 1;
    send_event(c, ev);
}

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(void) {
    const char *tr = getenv("XTINY_TRACE");
    xtrace = tr && *tr == '1';
    for (int i = 0; i < MAX_XCLIENTS; i++) X.cl[i].fd = -1;
    X.ptr_x = FB_W / 2; X.ptr_y = FB_H / 2;

    /* root window entry */
    X.win[0].id = ROOT_ID;
    X.win[0].w = FB_W; X.win[0].h = FB_H;
    X.win[0].mapped = 1;
    X.win[0].class_ = 1;
    X.win[0].creator = -1;

    mkdir("/tmp/.X11-unix", 01777);
    unlink("/tmp/.X11-unix/X1");
    X.lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (X.lfd < 0) { perror("socket"); return 1; }
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, "/tmp/.X11-unix/X1");
    if (bind(X.lfd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        perror("bind X1"); return 1;
    }
    if (listen(X.lfd, 4) < 0) { perror("listen"); return 1; }
    int fl = fcntl(X.lfd, F_GETFL, 0);
    if (fl >= 0) fcntl(X.lfd, F_SETFL, fl | O_NONBLOCK);
    fcntl(X.lfd, F_SETFD, FD_CLOEXEC);

    printf("[xtiny] X server on DISPLAY=:1 (/tmp/.X11-unix/X1)\n");
    fflush(stdout);

    rfb_config cfg = {
        .name       = "LinuxOnTab X11",
        .w          = FB_W,
        .h          = FB_H,
        .port       = 5900,
        .render     = render,
        .on_pointer = on_pointer,
        .on_key     = on_key,
        .on_idle    = on_idle,
    };
    return rfb_run(&cfg);
}
