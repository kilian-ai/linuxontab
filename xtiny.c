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

#include <dirent.h>
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

/* The desktop follows the viewer: the shell's X display panel asks for its
 * own size (RFB SetDesktopSize → on_resize). Until a viewer connects the
 * screen is XTINY_GEOMETRY (WxH) or 1024x768. */
#define FB_W (X.fbw)
#define FB_H (X.fbh)
#define FB_MIN_W 640
#define FB_MIN_H 400
#define FB_MAX_W 3840
#define FB_MAX_H 2160

/* The taskbar owns the bottom strip; windows live above it. */
#define TASKBAR_H 34
#define WORK_H    (FB_H - TASKBAR_H)

#define MAX_XCLIENTS 8
/* The largest request the setup reply advertises (max request length is
 * 0xffff words). A client may legally send one that big — Xlib does for a
 * full-window XPutImage, e.g. 320x200 at 32 bpp = 256 KB — so each client's
 * input buffer must hold it, or the request is rejected as malformed and the
 * client dropped. */
#define MAX_REQ_BYTES (0xffff * 4)
/* Toolkit apps are resource-hungry: FOX (Xfe) makes every widget an X
 * window and gives each icon an image pixmap plus a shape bitmap. */
#define MAX_WINDOWS  1024
#define MAX_PIXMAPS  4096
#define MAX_GCS      512
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
    int override_;              /* override-redirect top-level (menus,
                                   tooltips, drop-downs): placed by the
                                   client's own x/y, no frame, no focus */
    rfb_winframe frame;
    char title[64];
    int creator;
    int put_scale;              /* _LOT_PUTIMAGE_SCALE: PutImage pixels are k×k blocks */
    struct { uint32_t atom, type; uint8_t fmt; uint32_t n;
             uint8_t data[512]; } props[MAX_PROPS];
    int nprops;
} XWindow;

typedef struct {
    uint32_t id;                /* 0 = free */
    int w, h;
    uint32_t *px;
    int creator;
    int depth;                  /* 1: bitmap, px holds 0/1 */
} XPixmap;

typedef struct {
    uint32_t id;                /* 0 = free */
    uint32_t fg, bg;
    int creator;
    uint32_t clip;              /* clip-mask bitmap, 0 = None */
    int clip_x, clip_y;         /* clip origin */
} XGC;

typedef struct {
    int fd;                     /* -1 = free */
    int state;                  /* 1 handshake, 2 running */
    uint8_t inbuf[MAX_REQ_BYTES];
    int inlen;
    uint16_t seq;
    uint32_t root_evmask;
} XClient;

static struct {
    int lfd;
    int au_lfd, au_fd;          /* sound socket /tmp/.lot-audio (see audio_poll) */
    uint8_t au_part[4];         /* a partial stereo frame carried to the next read */
    int au_npart;
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

    int fbw, fbh;               /* current screen size (see FB_W) */
    int tb_hover;               /* taskbar item under the pointer, -1 none */
    int menu_open;              /* the Apps menu is showing */
    int menu_hover;             /* menu row under the pointer / keyboard, -1 */

    /* Active grabs (GrabPointer / GrabKeyboard). A toolkit opening a menu
     * grabs both: clicks outside the popup must reach the popup's client
     * (that is how the menu learns to close) and the arrow keys must reach
     * the popup, not the focused frame. */
    uint32_t pgrab_win, pgrab_mask;
    int pgrab_owner;            /* owner_events: own windows get their events */
    uint32_t igrab_win;         /* implicit grab: the press went here, until all buttons are up */
    uint32_t ptr_win;           /* window under the pointer, for Enter/LeaveNotify */
    uint32_t kgrab_win;

    /* Edge-drag resize of a top-level (see on_pointer). */
    uint32_t rz_win;
    int rz_edges;               /* RZ_* bits */
    int rz_px, rz_py;           /* pointer at press */
    int rz_x, rz_w, rz_h;       /* frame x + content size at press */
    int rz_nw, rz_nh, rz_nx;    /* latest target geometry */
    uint64_t rz_last_ms;        /* throttle: clients re-layout per resize */
} X;

/* Default X resources, served as the root window's RESOURCE_MANAGER (what
 * xrdb would load). Xlib reads it at connect, so every Xt app — xterm
 * above all — starts with a theme matching the desktop instead of the
 * stark black-on-white defaults. A client that sets the property wins. */
static const char XTINY_RESOURCES[] =
    "XTerm*title:\tTerminal\n"
    "XTerm*iconName:\tTerminal\n"
    "XTerm*background:\t#1b1d23\n"
    "XTerm*foreground:\t#d5d9e0\n"
    "XTerm*cursorColor:\t#7aa2f7\n"
    "XTerm*highlightColor:\t#3e4451\n"
    "XTerm*internalBorder:\t10\n"
    "XTerm*borderWidth:\t0\n"
    "XTerm*scrollBar:\tfalse\n"
    "XTerm*saveLines:\t4000\n"
    "XTerm*metaSendsEscape:\ttrue\n"
    "XTerm*vt100.geometry:\t80x24\n"
    "XTerm*color0:\t#2a2e38\n"
    "XTerm*color1:\t#e06c75\n"
    "XTerm*color2:\t#98c379\n"
    "XTerm*color3:\t#e5c07b\n"
    "XTerm*color4:\t#61afef\n"
    "XTerm*color5:\t#c678dd\n"
    "XTerm*color6:\t#56b6c2\n"
    "XTerm*color7:\t#abb2bf\n"
    "XTerm*color8:\t#5c6370\n"
    "XTerm*color9:\t#ef7b84\n"
    "XTerm*color10:\t#a9d48a\n"
    "XTerm*color11:\t#f0cf8f\n"
    "XTerm*color12:\t#79bdf5\n"
    "XTerm*color13:\t#d595e8\n"
    "XTerm*color14:\t#6ccbd6\n"
    "XTerm*color15:\t#e6e9ef\n";
#define XA_RESOURCE_MANAGER 23
#define XA_STRING           31

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

/* Numeric colour specs, as XParseColor accepts them: #RGB, #RRGGBB,
 * #RRRGGGBBB, #RRRRGGGGBBBB (high bits significant) and rgb:R/G/B with
 * 1-4 hex digits per channel (scaled). xterm sends its #rrggbb resource
 * colours to the server by name, so these must resolve here. */
static int hexval(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}
static int color_numeric(const char *name, int len, uint32_t *rgb) {
    unsigned ch[3];
    if (len >= 4 && name[0] == '#' && (len - 1) % 3 == 0 && len - 1 <= 12) {
        int d = (len - 1) / 3;
        for (int k = 0; k < 3; k++) {
            unsigned v = 0;
            for (int i = 0; i < d; i++) {
                int h = hexval(name[1 + k*d + i]);
                if (h < 0) return 0;
                v = v << 4 | (unsigned)h;
            }
            ch[k] = d >= 2 ? v >> (4*d - 8) : v * 17;   /* top 8 bits */
        }
    } else if (len > 4 && !strncmp(name, "rgb:", 4)) {
        int k = 0, i = 4;
        while (k < 3) {
            unsigned v = 0; int d = 0;
            while (i < len && name[i] != '/') {
                int h = hexval(name[i++]);
                if (h < 0 || ++d > 4) return 0;
                v = v << 4 | (unsigned)h;
            }
            if (!d) return 0;
            ch[k++] = v * 255 / ((1u << (4*d)) - 1);  /* scale to 8 bits */
            if (k < 3) { if (i >= len) return 0; i++; }
        }
        if (i != len) return 0;
    } else {
        return 0;
    }
    *rgb = ch[0] << 16 | ch[1] << 8 | ch[2];
    return 1;
}

static int color_lookup(const char *name, int len, uint32_t *rgb) {
    if (color_numeric(name, len, rgb)) return 1;
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

/* ── selections ───────────────────────────────────────────────────────────── */
typedef struct { uint32_t atom, owner; } Selection;
static Selection selections[16];
static Selection *sel_find(uint32_t atom, int create) {
    for (int i = 0; i < 16; i++) if (selections[i].atom == atom && atom) return &selections[i];
    if (!create) return NULL;
    for (int i = 0; i < 16; i++) if (!selections[i].atom) { selections[i].atom = atom; return &selections[i]; }
    return NULL;
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
    if (w->toplevel && w->override_) { *ox = w->x; *oy = w->y; return; }
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

/* Just part of a window (window coordinates). */
static void damage_window_rect(XWindow *w, int x, int y, int rw, int rh) {
    if (!X.srv || !win_visible(w)) return;
    if (x < 0) { rw += x; x = 0; }
    if (y < 0) { rh += y; y = 0; }
    if (x + rw > w->w) rw = w->w - x;
    if (y + rh > w->h) rh = w->h - y;
    if (rw <= 0 || rh <= 0) return;
    int ox, oy;
    win_origin(w, &ox, &oy);
    rfb_damage(X.srv, ox + x, oy + y, rw, rh);
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
/* GC clip mask (SetClipMask/clip origin): FOX draws icons with transparency
 * as a CopyArea through their shape bitmap. Outside the mask = clipped. */
static XPixmap *find_pix(uint32_t id);
static int gc_clip_ok(const XGC *gc, int x, int y) {
    if (!gc || !gc->clip) return 1;
    XPixmap *m = find_pix(gc->clip);
    if (!m || !m->px) return 1;
    int mx = x - gc->clip_x, my = y - gc->clip_y;
    if ((unsigned)mx >= (unsigned)m->w || (unsigned)my >= (unsigned)m->h) return 0;
    return m->px[my * m->w + mx] != 0;
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

/* PropertyNotify (state 0 = NewValue, 1 = Deleted) to the window's client
 * when it selected PropertyChangeMask; for the root, to every client that
 * selected it there. Toolkits read the server time this way: LibreOffice's
 * X11 frame appends zero bytes to a property and blocks in XIfEvent until
 * the PropertyNotify arrives (without it, soffice hangs before its first
 * window maps). */
static void ev_property_notify(XWindow *w, uint32_t atom, int state) {
    uint8_t ev[32]; memset(ev, 0, sizeof ev);
    ev[0] = 28;
    p32(ev, 4, w->id);
    p32(ev, 8, atom);
    p32(ev, 12, (uint32_t)rfb_now_ms());
    ev[16] = (uint8_t)state;
    if (w->id == ROOT_ID) {
        for (int i = 0; i < MAX_XCLIENTS; i++) {
            XClient *c = &X.cl[i];
            if (c->fd >= 0 && c->state == 2 && (c->root_evmask & 0x400000)) send_event(c, ev);
        }
        return;
    }
    XClient *c = win_client(w);
    if (c && (w->evmask & 0x400000)) send_event(c, ev);
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
        if (w->override_) {
            if (fx >= w->x && fx < w->x + w->w && fy >= w->y && fy < w->y + w->h)
                return w;
            continue;
        }
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
    if (w->id == X.pgrab_win) X.pgrab_win = 0;
    if (w->id == X.kgrab_win) X.kgrab_win = 0;
    if (w->id == X.igrab_win) X.igrab_win = 0;
    if (w->id == X.ptr_win)   X.ptr_win = 0;
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

static uint32_t atom_by_name(const char *name);

/* Slide a top-level's frame back onto the screen. Toolkits create their
 * shell window at 1x1 and grow it before mapping (xterm does), so the
 * placement check at CreateWindow sees nothing to clamp — check again
 * when the window is mapped or a mapped window grows. */
static void keep_on_screen(XWindow *w) {
    if (!w->toplevel || w->maxed) return;
    int fw = w->w + 2*RFB_BORDER, fh = RFB_TITLE_H + w->h + RFB_BORDER;
    if (w->frame.x + fw > FB_W)   w->frame.x = FB_W - fw;
    if (w->frame.y + fh > WORK_H) w->frame.y = WORK_H - fh;
    if (w->frame.x < 0) w->frame.x = 0;
    if (w->frame.y < 0) w->frame.y = 0;
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
            if (bit == 9) slot->override_ = (int)(v & 1);       /* CWOverrideRedirect */
            if (bit == 11) slot->evmask = v;
            if (bit == 14) slot->cursor = cursor_id_shape(v);   /* CWCursor */
        }
        if (!slot->toplevel) slot->override_ = 0;
        if (slot->class_ == 1) {
            slot->px = malloc((size_t)slot->w * slot->h * 4);
            if (slot->px) win_fill_bg(slot);
        }
        if (slot->toplevel && slot->override_) {
            slot->frame.w = slot->w;
            slot->frame.h = slot->h;
            slot->frame.title = slot->title;
        } else if (slot->toplevel) {
            slot->frame.x = 100 + (X.ntoplevel % 5) * 40;
            slot->frame.y = 40 + (X.ntoplevel % 5) * 30;
            slot->frame.w = slot->w;
            slot->frame.h = slot->h;
            /* keep the cascade on screen: a big window (a 760x500 browser)
             * placed at the cascade offset ran off the right edge */
            {
                int fw = slot->w + 2*RFB_BORDER, fh = RFB_TITLE_H + slot->h + RFB_BORDER;
                if (slot->frame.x + fw > FB_W)   slot->frame.x = FB_W - fw > 0 ? FB_W - fw : 0;
                if (slot->frame.y + fh > WORK_H) slot->frame.y = WORK_H - fh > 0 ? WORK_H - fh : 0;
            }
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
            if (bit == 9 && w->toplevel) w->override_ = (int)(v & 1);
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
            if (w->toplevel && w->override_) {
                /* a popup: where the client put it, on top, and the
                 * keyboard focus stays with the window that opened it */
                stack_add(w->id);
                stack_raise(w->id);
            } else if (w->toplevel) {    /* newly shown windows come to front
                                          * and take the keyboard */
                /* A client that asks for a user-specified position
                 * (WM_NORMAL_HINTS flags & USPosition, as `-geometry +x+y`
                 * or the date dialog above the clock do) gets it; everything
                 * else keeps the cascade. PPosition is ignored: toolkits set
                 * it with whatever x/y they happened to create at. */
                for (int i = 0; i < w->nprops; i++) {
                    if (w->props[i].atom != 40 || w->props[i].fmt != 32 || w->props[i].n < 3) continue;
                    if (g32(w->props[i].data, 0) & 1) {      /* USPosition */
                        w->frame.x = (int)(int32_t)g32(w->props[i].data, 4);
                        w->frame.y = (int)(int32_t)g32(w->props[i].data, 8);
                    }
                }
                keep_on_screen(w);
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
            if (w->id == X.pgrab_win) X.pgrab_win = 0;
            if (w->id == X.kgrab_win) X.kgrab_win = 0;
            if (w->id == X.igrab_win) X.igrab_win = 0;
            if (w->id == X.ptr_win)   X.ptr_win = 0;
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
            if (bit == 0 && (!w->toplevel || w->override_)) w->x = (int16_t)v;
            if (bit == 1 && (!w->toplevel || w->override_)) w->y = (int16_t)v;
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
            if (w->toplevel) {
                w->frame.w = nw; w->frame.h = nh;
                if (w->mapped && !w->override_) keep_on_screen(w);
            }
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
        ev_property_notify(w, prop, 0);
        /* _LOT_PUTIMAGE_SCALE (CARDINAL/32, k = 1..4): a video player sends
         * frames at 1/k size and every pixel lands as a k×k block at window
         * position (dst*k) — k² less data through the socket than an
         * upscaled frame. xtiny-only; lotplay checks the server vendor. */
        if (fmt == 32 && n >= 1 && prop == atom_by_name("_LOT_PUTIMAGE_SCALE")) {
            int k = (int)g32(r, 24);
            w->put_scale = k >= 1 && k <= 4 ? k : 1;
        }
        if (prop == 39 && w->toplevel) {          /* WM_NAME → frame title */
            uint32_t bytes = n * (fmt / 8);
            if (bytes > sizeof w->title - 1) bytes = sizeof w->title - 1;
            memcpy(w->title, r + 24, bytes);
            w->title[bytes] = 0;
            if (X.srv) rfb_damage_full(X.srv);
        }
        break;
    }
    case 19: { /* DeleteProperty */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        uint32_t prop = g32(r, 8);
        for (int i = 0; i < w->nprops; i++) {
            if (w->props[i].atom != prop) continue;
            w->props[i] = w->props[--w->nprops];
            ev_property_notify(w, prop, 1);
            break;
        }
        break;
    }

    case 20: { /* GetProperty */
        XWindow *w = find_win(g32(r, 4));
        if (!w) { send_error(c, 3, g32(r, 4), op); return; }
        uint32_t prop = g32(r, 8);
        const uint8_t *data = NULL;
        uint32_t type = 0, total = 0;
        int fmt = 0;
        for (int i = 0; i < w->nprops; i++) {
            if (w->props[i].atom == prop) {
                data = w->props[i].data;
                type = w->props[i].type;
                fmt = w->props[i].fmt;
                total = w->props[i].n * (uint32_t)(fmt / 8);
                break;
            }
        }
        if (!data && w->id == ROOT_ID && prop == XA_RESOURCE_MANAGER) {
            data = (const uint8_t *)XTINY_RESOURCES;
            type = XA_STRING; fmt = 8;
            total = (uint32_t)strlen(XTINY_RESOURCES);
        }
        uint8_t b[24]; memset(b, 0, sizeof b);
        if (!data) { send_reply(c, 0, b, NULL, 0); break; }   /* None */
        /* long-offset / long-length are in 4-byte units (Xlib asks for a
         * big length; a length-0 query just learns the type and size) */
        uint32_t start = g32(r, 16) * 4u, want = g32(r, 20) * 4u;
        if (start > total) { send_error(c, 2, g32(r, 16), op); return; }
        uint32_t n = total - start;
        if (want < n) n = want;
        int unit = fmt / 8;
        n -= n % (uint32_t)unit;
        p32(b, 0, type);
        p32(b, 4, total - start - n);             /* bytes_after */
        p32(b, 8, n / (uint32_t)unit);
        send_reply(c, (uint8_t)fmt, b, data + start, (int)n);
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

    /* Selections (clipboard, PRIMARY, drag and drop): track owners and
     * route ConvertSelection to the owner as a SelectionRequest; the owner
     * answers the requestor through SendEvent(SelectionNotify). */
    case 22: { /* SetSelectionOwner */
        uint32_t owner = g32(r, 4), atom = g32(r, 8), t = g32(r, 12);
        Selection *sel = sel_find(atom, 1);
        if (!sel) break;
        XWindow *ow = find_win(owner);
        if (sel->owner && sel->owner != owner) {          /* tell the old owner */
            XWindow *old = find_win(sel->owner);
            XClient *oc = old ? win_client(old) : NULL;
            if (oc) {
                uint8_t ev[32]; memset(ev, 0, sizeof ev);
                ev[0] = 29;                               /* SelectionClear */
                p32(ev, 4, t); p32(ev, 8, sel->owner); p32(ev, 12, atom);
                send_event(oc, ev);
            }
        }
        sel->owner = ow ? owner : 0;
        if (!sel->owner) sel->atom = 0;
        break;
    }
    case 23: { /* GetSelectionOwner */
        Selection *sel = sel_find(g32(r, 4), 0);
        uint8_t b[24]; memset(b, 0, sizeof b);
        if (sel && find_win(sel->owner)) p32(b, 0, sel->owner);
        send_reply(c, 0, b, NULL, 0);
        break;
    }
    case 24: { /* ConvertSelection */
        uint32_t req = g32(r, 4), atom = g32(r, 8), target = g32(r, 12), prop = g32(r, 16), t = g32(r, 20);
        Selection *sel = sel_find(atom, 0);
        XWindow *ow = sel ? find_win(sel->owner) : NULL;
        XClient *oc = ow ? win_client(ow) : NULL;
        uint8_t ev[32]; memset(ev, 0, sizeof ev);
        if (oc) {
            ev[0] = 30;                                   /* SelectionRequest */
            p32(ev, 4, t); p32(ev, 8, sel->owner); p32(ev, 12, req);
            p32(ev, 16, atom); p32(ev, 20, target); p32(ev, 24, prop);
            send_event(oc, ev);
        } else {
            ev[0] = 31;                                   /* SelectionNotify: no owner */
            p32(ev, 4, t); p32(ev, 8, req); p32(ev, 12, atom); p32(ev, 16, target);
            send_event(c, ev);
        }
        break;
    }
    case 25: { /* SendEvent — deliver to the destination window's client
                * (PointerWindow/InputFocus resolve to the focus window) */
        uint32_t dest = g32(r, 4);
        if (dest == 0 || dest == 1) dest = X.focus;
        XWindow *w = find_win(dest);
        XClient *dc = w ? win_client(w) : NULL;
        if (dc) {
            uint8_t ev[32];
            memcpy(ev, r + 12, 32);
            ev[0] |= 0x80;                                /* sent by SendEvent */
            send_event(dc, ev);
        }
        break;
    }

    case 26: case 31: { /* GrabPointer / GrabKeyboard — always granted */
        XWindow *gw = find_win(g32(r, 4));
        if (gw && op == 26) {
            X.pgrab_win = gw->id;
            X.pgrab_owner = r[1];
            X.pgrab_mask = g16(r, 8);
        } else if (gw) {
            X.kgrab_win = gw->id;
        }
        uint8_t b[24]; memset(b, 0, sizeof b);
        send_reply(c, 0, b, NULL, 0);             /* status = Success */
        break;
    }
    case 27: X.pgrab_win = 0; break;              /* UngrabPointer */
    case 32: X.kgrab_win = 0; break;              /* UngrabKeyboard */

    /* The void half of the grab family: UngrabPointer(27), GrabButton(28),
     * UngrabButton(29), ChangeActivePointerGrab(30), GrabKey(33),
     * UngrabKey(34), AllowEvents(35). Nothing to do — passive grabs are not
     * implemented (active ones are, above) — but they must be accepted
     * silently: erroring on a
     * void request makes Xlib's default handler abort the client. */
    case 28: case 29: case 30:
    case 33: case 34: case 35:
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
        slot->depth = r[1];
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
            if (bit == 17) slot->clip_x = (int16_t)v;
            if (bit == 18) slot->clip_y = (int16_t)v;
            if (bit == 19) slot->clip = v;
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
            if (bit == 17) gc->clip_x = (int16_t)v;
            if (bit == 18) gc->clip_y = (int16_t)v;
            if (bit == 19) gc->clip = v;
        }
        break;
    }
    case 57: { /* CopyGC */
        XGC *src = find_gc(g32(r, 4)), *dst = find_gc(g32(r, 8));
        if (src && dst) {
            dst->fg = src->fg; dst->bg = src->bg;
            dst->clip = src->clip; dst->clip_x = src->clip_x; dst->clip_y = src->clip_y;
        }
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
                XGC *gc = find_gc(g32(r, 12));
                for (int j = 0; j < h; j++)
                    for (int i = 0; i < w; i++)
                        if (gc_clip_ok(gc, dx + i, dy + j))
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

    case 63: { /* CopyPlane — one bit-plane of src, as GC foreground/background
                * (FOX draws bitmaps and check marks this way) */
        Drawable src, dst;
        XGC *gc = find_gc(g32(r, 12));
        if (!resolve_drawable(g32(r, 4), &src) ||
            !resolve_drawable(g32(r, 8), &dst)) { send_error(c, 9, 0, op); return; }
        if (!gc) { send_error(c, 13, g32(r, 12), op); return; }
        int sx = gs16(r, 16), sy = gs16(r, 18);
        int dx = gs16(r, 20), dy = gs16(r, 22);
        int w = g16(r, 24), h = g16(r, 26);
        uint32_t plane = g32(r, 28);
        if (src.px && w > 0 && h > 0) {
            uint8_t *bits = malloc((size_t)w * h);     /* src may be dst */
            if (bits) {
                for (int j = 0; j < h; j++)
                    for (int i = 0; i < w; i++) {
                        int fx = sx + i, fy = sy + j;
                        bits[j * w + i] = (unsigned)fx < (unsigned)src.w && (unsigned)fy < (unsigned)src.h &&
                                          (src.px[fy * src.w + fx] & plane);
                    }
                for (int j = 0; j < h; j++)
                    for (int i = 0; i < w; i++)
                        if (gc_clip_ok(gc, dx + i, dy + j))
                            dput(&dst, dx + i, dy + j, bits[j * w + i] ? gc->fg : gc->bg);
                free(bits);
            }
        }
        if (dst.win) damage_window(dst.win);
        uint8_t ev[32]; memset(ev, 0, sizeof ev);
        ev[0] = 14;                                /* NoExpose */
        p32(ev, 4, g32(r, 8));
        ev[10] = 63;
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
            /* Clipped row copies: a video player pushes megabytes of these
             * per second, so no per-pixel calls. Only the drawn rows are
             * damaged — Xlib splits a big image into many requests, and
             * damaging the whole window for each re-sent all of it. */
            int stride = w * 4;
            int k = d.win && d.win->put_scale > 1 ? d.win->put_scale : 1;
            if (k > 1 && d.px) {                  /* scaled: k×k blocks */
                for (int j = 0; j < h; j++) {
                    const uint8_t *src = r + 24 + j * stride;
                    for (int v = 0; v < k; v++) {
                        int y = (dy + j) * k + v;
                        if ((unsigned)y >= (unsigned)d.h) continue;
                        uint32_t *row = d.px + (size_t)y * d.w;
                        for (int i = 0; i < w; i++) {
                            uint32_t px = (uint32_t)src[i*4] | (uint32_t)src[i*4+1] << 8 |
                                          (uint32_t)src[i*4+2] << 16;
                            int x = (dx + i) * k;
                            for (int u = 0; u < k; u++)
                                if ((unsigned)(x + u) < (unsigned)d.w) row[x + u] = px;
                        }
                    }
                }
                if (d.win) damage_window_rect(d.win, dx * k, dy * k, w * k, h * k);
                break;
            }
            int i0 = dx < 0 ? -dx : 0, i1 = dx + w > d.w ? d.w - dx : w;
            int j0 = dy < 0 ? -dy : 0, j1 = dy + h > d.h ? d.h - dy : h;
            if (d.px && i0 < i1)
                for (int j = j0; j < j1; j++) {
                    const uint8_t *src = r + 24 + j * stride + i0 * 4;
                    uint32_t *dst = d.px + (size_t)(dy + j) * d.w + dx + i0;
                    for (int i = 0; i < i1 - i0; i++, src += 4)
                        dst[i] = (uint32_t)src[0] | (uint32_t)src[1] << 8 | (uint32_t)src[2] << 16;
                }
            if (d.win) damage_window_rect(d.win, dx, dy, w, h);
        } else if (depth == 1 && format <= 2) {
            /* Bitmaps: XYBitmap (format 0) paints GC fg/bg; XYPixmap and
             * ZPixmap of depth 1 carry the pixel values 0/1 themselves (what
             * depth-1 pixmaps — icon masks — store). LSB-first bit order,
             * 32-bit scanline pad, as announced in the connection setup. */
            XGC *gc = find_gc(g32(r, 8));
            int left = r[20];
            int stride = ((w + left + 31) / 32) * 4;
            for (int j = 0; j < h; j++) {
                const uint8_t *row = r + 24 + j * stride;
                for (int i = 0; i < w; i++) {
                    int b = (row[(i + left) >> 3] >> ((i + left) & 7)) & 1;
                    uint32_t px = format == 0 ? (gc ? (b ? gc->fg : gc->bg) : (b ? 1u : 0u)) : (uint32_t)b;
                    if (gc_clip_ok(gc, dx + i, dy + j)) dput(&d, dx + i, dy + j, px);
                }
            }
            if (d.win) damage_window_rect(d.win, dx, dy, w, h);
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
    p16(buf, 26, MAX_REQ_BYTES / 4);              /* max request len */
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
        w->frame.square = 0;
        resize_window(w, w->save_w, w->save_h);
    } else {
        w->save_x = w->frame.x; w->save_y = w->frame.y;
        w->save_w = w->w;       w->save_h = w->h;
        w->maxed = 1;
        w->frame.square = 1;
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

/* ── applications ─────────────────────────────────────────────────────────── */
/* What the Apps menu and the pinned taskbar buttons offer. Built-in entries
 * cover the X apps and the terminal apps worth a window; packages can add
 * their own as freedesktop .desktop files in /usr/share/applications
 * (Name, Comment, Exec, Terminal, NoDisplay, plus X-LinuxOnTab-Package =
 * the apk package that installs it); a file named like a built-in id
 * replaces that entry. An app whose command is missing still shows when it
 * names a package: picking it installs the package in a terminal first. */
#define MAX_APPS 32
typedef struct {
    char id[32];                /* desktop-file id (basename) */
    char name[40];
    char comment[64];
    char exec[160];             /* command line (simple quoting) */
    char pkg[32];               /* apk package that provides it */
    int terminal;               /* run inside an xterm */
    uint32_t color;             /* icon tile, 0xRRGGBB */
    int pinned;                 /* also a taskbar button */
    int installed;              /* command found on PATH (refresh_apps) */
} App;

static const App BUILTIN_APPS[] = {
    { "xterm",   "Terminal",       "A shell in a window",          "xterm -fn fixed -e /bin/sh", "xterm",    0, 0x3B4252, 1, 0 },
    { "netsurf", "Browser",        "NetSurf web browser",          "netsurf",                    "netsurf",  0, 0x2F6FD0, 1, 0 },
    /* No package: lives on the x86 Chromium disk (console "chromium" row,
     * ?xdisk=), so it shows only while that disk is mounted at /opt/x86. */
    { "chromium","Chromium",       "Chromium 131 (x86-64, Blink)", "/opt/x86/chromium-desktop",  "",         0, 0x4285F4, 0, 0 },
    /* Likewise the LibreOffice disk (console "libreoffice" row) at /opt/lo. */
    { "writer",  "Writer",         "LibreOffice Writer documents", "/opt/lo/writer",             "",         0, 0x2A6099, 0, 0 },
    { "htop",    "System Monitor", "Processes and memory (htop)",  "htop",                       "htop",     1, 0x2E8B57, 0, 0 },
    /* matches the xfe package's own xfe.desktop, so the entry looks the same
     * before and after install */
    { "xfe",     "File Manager",   "Xfe, the X File Explorer",     "xfe",                        "xfe",      0, 0xC58A2A, 1, 0 },
    { "mc",      "Midnight Commander", "Two-pane file manager",    "mc",                         "mc",       1, 0x006064, 0, 0 },
    { "textedit","Text Editor",    "Edit text files in a window",  "lot-textedit",               "xtiny-apps", 0, 0x7B3FA0, 1, 0 },
    { "calc",    "Calculator",     "A pocket calculator",          "lot-calc",                   "xtiny-apps", 0, 0x4A6FA5, 0, 0 },
    { "nano",    "nano",           "Text editor in a terminal",    "nano",                       "nano",     1, 0x5E3A80, 0, 0 },
    { "python3", "Python",         "Python 3.11 interpreter",      "python3",                    "python3",  1, 0x3776AB, 0, 0 },
    { "node",    "Node.js",        "JavaScript REPL (QuickJS)",    "node",                       "nodejs",   1, 0x3C873A, 0, 0 },
    { "trust",   "Rust IDE",       "TRUST: build and run Rust",    "trust",                      "trust",    1, 0xB7410E, 0, 0 },
    { "tmux",    "tmux",           "Terminal multiplexer",         "tmux",                       "tmux",     1, 0x1BB91F, 0, 0 },
    /* clawlite opens its REPL without a key and says where to put one
     * (~/.config/clawlite/config); the terminal window stays up meanwhile. */
    { "claw",    "AI Assistant",   "claw LLM agent (needs API key)", "claw",                     "claw",     1, 0xD97757, 0, 0 },
    /* asks for the account on first start (neomutt-setup), then NeoMutt */
    { "neomutt", "Mail",           "NeoMutt mail client (IMAP/SMTP)", "neomutt-setup --run",        "neomutt",  1, 0x1F7A8C, 0, 0 },
    { "lotplay", "Videos",         "Video player (ffmpeg)",        "lotplay",                    "lotplay",  0, 0xE63946, 0, 0 },
    { "wolf3d",  "Wolfenstein 3D", "Shareware episode 1",          "wolf3d",                     "wolf3d",   0, 0x9B1C1C, 0, 0 },
    { "tetris",  "Tetris",         "vitetris, in colour",          "tetris",                     "vitetris", 1, 0xC77700, 0, 0 },
    { "xeyes",   "Eyes",           "Eyes that follow the pointer", "xeyes",                      "xeyes",    0, 0x5A5F69, 0, 0 },
};
#define NBUILTIN ((int)(sizeof BUILTIN_APPS / sizeof BUILTIN_APPS[0]))

static App apps[MAX_APPS];
static int napps;

/* Is the program (first word of cmd) executable somewhere on PATH? */
static int on_path(const char *cmd) {
    char prog[96];
    int n = 0;
    while (cmd[n] && cmd[n] != ' ' && n < (int)sizeof prog - 1) { prog[n] = cmd[n]; n++; }
    prog[n] = 0;
    if (!n) return 0;
    if (strchr(prog, '/')) return access(prog, X_OK) == 0;
    const char *path = getenv("PATH");
    if (!path || !*path) path = "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin";
    char buf[256];
    for (const char *p = path; *p; ) {
        const char *e = strchr(p, ':');
        int dl = e ? (int)(e - p) : (int)strlen(p);
        if (dl > 0 && dl + 1 + n < (int)sizeof buf) {
            memcpy(buf, p, dl); buf[dl] = '/'; memcpy(buf + dl + 1, prog, n + 1);
            if (access(buf, X_OK) == 0) return 1;
        }
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

static void copy_field(char *dst, size_t cap, const char *src) {
    size_t n = strlen(src);
    while (n && (src[n-1] == '\n' || src[n-1] == '\r' || src[n-1] == ' ')) n--;
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = 0;
}

/* Parse one .desktop file into *a (keeps built-in defaults for missing
 * keys). Returns 0 for NoDisplay/Hidden entries or files without Exec. */
static int parse_desktop(const char *path, App *a) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[256];
    int in_entry = 0, hidden = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '[') { in_entry = !strncmp(line, "[Desktop Entry]", 15); continue; }
        if (!in_entry) continue;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        const char *k = line, *v = eq + 1;
        if      (!strcmp(k, "Name"))    copy_field(a->name, sizeof a->name, v);
        else if (!strcmp(k, "Comment")) copy_field(a->comment, sizeof a->comment, v);
        else if (!strcmp(k, "Terminal")) a->terminal = !strncmp(v, "true", 4);
        else if (!strcmp(k, "NoDisplay") || !strcmp(k, "Hidden")) hidden |= !strncmp(v, "true", 4);
        else if (!strcmp(k, "X-LinuxOnTab-Package")) copy_field(a->pkg, sizeof a->pkg, v);
        else if (!strcmp(k, "X-LinuxOnTab-Color")) a->color = (uint32_t)strtoul(v + (*v == '#'), NULL, 16);
        else if (!strcmp(k, "Exec")) {
            /* drop field codes (%f %U ...) — nothing is ever passed */
            char out[160]; int o = 0;
            for (const char *q = v; *q && *q != '\n' && o < (int)sizeof out - 1; q++) {
                if (q[0] == '%' && q[1]) { q++; continue; }
                out[o++] = *q;
            }
            out[o] = 0;
            copy_field(a->exec, sizeof a->exec, out);
        }
    }
    fclose(f);
    return !hidden && a->exec[0] && a->name[0];
}

/* Rebuild the list: built-ins, then .desktop files (re-read only when the
 * directory changes), then resolve which commands are installed. Cheap
 * enough to run every few seconds from on_idle, so `apk add` while the
 * desktop is up shows its app without a restart. */
static void refresh_apps(int force) {
    static uint64_t last;
    static long dir_mtime = -1;
    uint64_t now = rfb_now_ms();
    if (!force && last && now - last < 3000) return;
    last = now;

    struct stat st;
    long mt = stat("/usr/share/applications", &st) == 0 ? (long)st.st_mtime : 0;
    int rebuild = force || mt != dir_mtime || napps == 0;
    dir_mtime = mt;
    int changed = 0;
    if (rebuild) {
        napps = 0;
        for (int i = 0; i < NBUILTIN && napps < MAX_APPS; i++) apps[napps++] = BUILTIN_APPS[i];
        DIR *d = mt ? opendir("/usr/share/applications") : NULL;
        struct dirent *de;
        while (d && (de = readdir(d))) {
            size_t l = strlen(de->d_name);
            if (l < 9 || strcmp(de->d_name + l - 8, ".desktop")) continue;
            char id[32];
            size_t il = l - 8 < sizeof id - 1 ? l - 8 : sizeof id - 1;
            memcpy(id, de->d_name, il); id[il] = 0;
            int slot = -1;
            for (int i = 0; i < napps; i++) if (!strcmp(apps[i].id, id)) slot = i;
            App a;
            if (slot >= 0) a = apps[slot];
            else {
                memset(&a, 0, sizeof a);
                snprintf(a.id, sizeof a.id, "%s", id);
                a.color = 0x4C566A;
            }
            char path[320];
            snprintf(path, sizeof path, "/usr/share/applications/%s", de->d_name);
            int ok = parse_desktop(path, &a);
            if (slot >= 0) {
                if (ok) apps[slot] = a;
                else { memmove(&apps[slot], &apps[slot + 1], (size_t)(napps - slot - 1) * sizeof(App)); napps--; }
            } else if (ok && napps < MAX_APPS) {
                apps[napps++] = a;
            }
        }
        if (d) closedir(d);
        changed = 1;
    }
    for (int i = 0; i < napps; i++) {
        int ok = on_path(apps[i].exec);
        if (ok != apps[i].installed) { apps[i].installed = ok; changed = 1; }
    }
    if (changed && X.srv) rfb_damage_full(X.srv);
}

/* Offered at all: runnable now, or installable. */
static int app_visible(const App *a) { return a->installed || a->pkg[0]; }

/* Split a command line into argv (whitespace, "double" or 'single' quotes).
 * Writes into buf; returns argc. */
static int split_cmd(const char *cmd, char *buf, size_t cap, char **argv, int maxv) {
    int argc = 0;
    size_t o = 0;
    const char *p = cmd;
    while (*p && argc < maxv - 1) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        argv[argc++] = buf + o;
        char q = 0;
        while (*p && (q || (*p != ' ' && *p != '\t'))) {
            if (!q && (*p == '"' || *p == '\'')) { q = *p++; continue; }
            if (q && *p == q) { q = 0; p++; continue; }
            if (o < cap - 1) buf[o++] = *p;
            p++;
        }
        if (o < cap - 1) buf[o++] = 0;
    }
    argv[argc] = NULL;
    return argc;
}

static void spawn_argv(char *const *argv) {
    pid_t p = fork();
    if (p != 0) {                         /* parent (or fork failure) */
        if (p < 0) perror("[xtiny] fork");
        return;
    }
    /* Child. stdin MUST come from /dev/null: an X client left on the guest
     * console busy-reads it one byte at a time and pegs the single CPU
     * (the documented Xvfb spin). Sockets are CLOEXEC, so exec drops them. */
    setenv("DISPLAY", ":1", 1);
    /* Started by /etc/rc (?image=xtiny), xtiny inherits init's HOME=/, and
     * every app it launches would keep its config and history in / (claw's
     * key file, shell/python history, ...). Guest apps run as root. */
    const char *home = getenv("HOME");
    if (!home || !*home || !strcmp(home, "/")) setenv("HOME", "/root", 1);
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, 0);
        if (devnull > 2) close(devnull);
    }
    execvp(argv[0], argv);
    _exit(127);
}

/* Start an app: directly, in a terminal, or — not installed yet — in a
 * terminal that runs `apk add` first, so the download is visible. */
static void launch_app(const App *a) {
    char buf[512], script[400];
    char *argv[24];
    if (a->installed && !a->terminal) {
        split_cmd(a->exec, buf, sizeof buf, argv, 24);
    } else if (a->installed) {
        int n = 0;
        argv[n++] = "xterm"; argv[n++] = "-T"; argv[n++] = (char *)a->name;
        argv[n++] = "-fn"; argv[n++] = "fixed"; argv[n++] = "-e";
        split_cmd(a->exec, buf, sizeof buf, argv + n, 24 - n);
    } else {
        /* GUI apps detach (setsid) so closing the installer keeps them */
        /* A package newer than the image's baked index is "Unknown": refresh
         * the index once and retry, rather than failing on a stale snapshot. */
        if (a->terminal)
            snprintf(script, sizeof script,
                     "{ apk add %s || { apk update && apk add %s; }; } && exec %s; "
                     "echo; echo 'Install failed - press Enter to close.'; read x",
                     a->pkg, a->pkg, a->exec);
        else
            snprintf(script, sizeof script,
                     "{ apk add %s || { apk update && apk add %s; }; } && "
                     "{ setsid %s </dev/null >/dev/null 2>&1 & sleep 2; exit 0; }; "
                     "echo; echo 'Install failed - press Enter to close.'; read x",
                     a->pkg, a->pkg, a->exec);
        snprintf(buf, sizeof buf, "Installing %s", a->name);
        int n = 0;
        argv[n++] = "xterm"; argv[n++] = "-T"; argv[n++] = buf;
        argv[n++] = "-fn"; argv[n++] = "fixed"; argv[n++] = "-e";
        argv[n++] = "/bin/sh"; argv[n++] = "-c"; argv[n++] = script;
        argv[n] = NULL;
    }
    printf("[xtiny] launch %s%s\n", a->id, a->installed ? "" : " (install first)");
    fflush(stdout);
    spawn_argv(argv);
}

/* An app's icon: a rounded colour tile with its initial. */
static void draw_app_tile(rfb_server *s, int x, int y, int sz, const App *a) {
    uint8_t r = (uint8_t)(a->color >> 16), g = (uint8_t)(a->color >> 8), b = (uint8_t)a->color;
    rfb_fill_rrect(s, x, y, sz, sz, sz / 4, b, g, r);
    char ini[2] = { a->name[0] ? a->name[0] : '?', 0 };
    int tw = rfb_label_width(ini);
    rfb_draw_label(s, x + (sz - tw) / 2, y + sz / 2 - 1, 0, ini, 0xFF, 0xFF, 0xFF);
}

/* ── Apps menu ────────────────────────────────────────────────────────────── */
#define MENU_W      300
#define MENU_ROW_H  46
#define MENU_HEAD_H 34
#define MENU_PAD    6
#define MENU_MIN_W  180     /* narrowest column before entries are dropped */

/* Entries flow top-to-bottom into as many columns as the work area needs
 * (no scrolling), each up to MENU_W wide and narrowed to fit the screen, so
 * a short panel still reaches every app. */
typedef struct { int x, y, w, h, n, rows, cols, colw; int idx[MAX_APPS]; } MenuLayout;

static void menu_layout(MenuLayout *m) {
    m->n = 0;
    for (int i = 0; i < napps; i++) if (app_visible(&apps[i])) m->idx[m->n++] = i;
    int maxrows = (WORK_H - 16 - MENU_HEAD_H - 2*MENU_PAD) / MENU_ROW_H;
    if (maxrows < 1) maxrows = 1;
    int maxcols = (FB_W - 16) / MENU_MIN_W;
    if (maxcols < 1) maxcols = 1;
    m->cols = (m->n + maxrows - 1) / maxrows;
    if (m->cols < 1) m->cols = 1;
    if (m->cols > maxcols) { m->cols = maxcols; if (m->n > maxcols * maxrows) m->n = maxcols * maxrows; }
    m->rows = (m->n + m->cols - 1) / m->cols;       /* balance the columns */
    if (m->rows < 1) m->rows = 1;
    m->colw = MENU_W;                               /* narrow columns to fit */
    if (m->cols * m->colw > FB_W - 16) m->colw = (FB_W - 16) / m->cols;
    m->w = m->cols * m->colw;
    m->h = MENU_HEAD_H + m->rows * MENU_ROW_H + 2*MENU_PAD;
    m->x = 8;
    m->y = WORK_H - 8 - m->h;
}

static int menu_row_at(const MenuLayout *m, int x, int y) {
    if (x < m->x || x >= m->x + m->w) return -1;
    int ry = y - (m->y + MENU_PAD + MENU_HEAD_H);
    if (ry < 0) return -1;
    int row = ry / MENU_ROW_H, col = (x - m->x) / m->colw;
    if (row >= m->rows || col >= m->cols) return -1;
    int r = col * m->rows + row;
    return r < m->n ? r : -1;
}

static void menu_damage(rfb_server *s) {
    MenuLayout m; menu_layout(&m);
    rfb_damage(s, m.x - 16, m.y - 16, m.w + 32, m.h + 40);
}

static void menu_set(rfb_server *s, int open) {
    if (X.menu_open == open) return;
    if (!open) menu_damage(s);           /* old extent, before it goes */
    X.menu_open = open;
    X.menu_hover = -1;
    if (open) { refresh_apps(1); menu_damage(s); }
}

static void draw_menu(rfb_server *s) {
    MenuLayout m; menu_layout(&m);
    rfb_drop_shadow(s, m.x, m.y, m.w, m.h, 140);
    rfb_fill_rrect(s, m.x, m.y, m.w, m.h, 10, 0x4A, 0x45, 0x40);            /* rim  */
    rfb_fill_rrect(s, m.x + 1, m.y + 1, m.w - 2, m.h - 2, 9, 0x2E, 0x2A, 0x26);  /* body */
    rfb_draw_label(s, m.x + 14, m.y + MENU_PAD + MENU_HEAD_H / 2, 0, "Applications",
                   0x9A, 0x96, 0x92);
    for (int r = 0; r < m.n; r++) {
        const App *a = &apps[m.idx[r]];
        int cx = m.x + (r / m.rows) * m.colw, cw = m.colw;
        int ry = m.y + MENU_PAD + MENU_HEAD_H + (r % m.rows) * MENU_ROW_H;
        if (r == X.menu_hover)
            rfb_fill_rrect(s, cx + MENU_PAD, ry + 2, cw - 2*MENU_PAD, MENU_ROW_H - 4, 7,
                           0x4A, 0x44, 0x3E);
        draw_app_tile(s, cx + 14, ry + (MENU_ROW_H - 30) / 2, 30, a);
        int tx = cx + 56, tw = cw - 56 - 14;
        int badge = 0;
        if (!a->installed) {                 /* "Install" tag on the right */
            const char *t = "Install";
            badge = rfb_label_width(t) + 16;
            int bx = cx + cw - 14 - badge;
            rfb_fill_rrect(s, bx, ry + MENU_ROW_H/2 - 10, badge, 20, 10, 0x5C, 0x4A, 0x2E);
            rfb_draw_label(s, bx + 8, ry + MENU_ROW_H/2 - 1, 0, t, 0xFF, 0xC8, 0x8A);
            tw -= badge + 8;
        }
        rfb_draw_label(s, tx, ry + 15, tw, a->name, 0xF0, 0xED, 0xEA);
        rfb_draw_label(s, tx, ry + 31, tw, a->comment, 0x9A, 0x96, 0x92);
    }
}

/* ── taskbar ──────────────────────────────────────────────────────────────── */
/* One layout routine feeds both drawing and hit-testing, so a button can
 * never be drawn somewhere it cannot be clicked. */
enum { TB_NONE = 0, TB_MENU, TB_LAUNCH, TB_WINDOW };
typedef struct { int x, w, kind, arg; uint32_t win; } TbItem;

#define TB_PAD    5                       /* button inset from the bar edge */
#define TB_CLOCK_W 64
#define TB_MENU_W  78

static int taskbar_layout(TbItem *it, int max) {
    int n = 0, x = 6;
    it[n].x = x; it[n].w = TB_MENU_W; it[n].kind = TB_MENU; it[n].arg = 0; it[n].win = 0;
    x += TB_MENU_W + 6;
    n++;
    for (int i = 0; i < napps && n < max; i++) {
        if (!apps[i].pinned || !apps[i].installed) continue;
        int bw = rfb_label_width(apps[i].name) + 24;
        it[n].x = x; it[n].w = bw; it[n].kind = TB_LAUNCH;
        it[n].arg = i; it[n].win = 0;
        x += bw + 4;
        n++;
    }
    x += 12;                              /* gap between launchers and list */
    int nwin = 0;
    for (int i = 0; i < X.nstack; i++) {
        XWindow *w = find_win(X.stack[i]);
        if (w && w->mapped && !w->override_) nwin++;
    }
    /* window buttons share what is left, 90..180 px each */
    int room = FB_W - TB_CLOCK_W - 8 - x;
    int bw = nwin ? room / nwin - 4 : 0;
    if (bw > 180) bw = 180;
    if (bw < 90)  bw = 90;
    /* list in creation order (stable), not stacking order (which jumps) */
    for (int i = 0; i < MAX_WINDOWS && n < max; i++) {
        XWindow *w = &X.win[i];
        if (!w->id || !w->toplevel || !w->mapped || w->override_) continue;
        if (x + bw > FB_W - TB_CLOCK_W - 8) break;
        it[n].x = x; it[n].w = bw; it[n].kind = TB_WINDOW;
        it[n].arg = 0; it[n].win = w->id;
        x += bw + 4;
        n++;
    }
    return n;
}

static int taskbar_item_at(int x, int y) {
    if (y < WORK_H) return -1;
    TbItem it[24];
    int n = taskbar_layout(it, 24);
    for (int i = 0; i < n; i++)
        if (x >= it[i].x && x < it[i].x + it[i].w) return i;
    return -1;
}

static void draw_taskbar(rfb_server *s) {
    int y = WORK_H;
    rfb_fill_rect(s, 0, y, FB_W, TASKBAR_H, 0x1D,0x1A,0x17);
    rfb_fill_rect(s, 0, y, FB_W, 1, 0x3A,0x36,0x32);
    int by = y + TB_PAD, bh = TASKBAR_H - 2*TB_PAD, cy = y + TASKBAR_H/2;

    TbItem it[24];
    int n = taskbar_layout(it, 24);
    for (int i = 0; i < n; i++) {
        int hov = (i == X.tb_hover);
        if (it[i].kind == TB_MENU) {
            /* accent pill with a 3x3 dot grid */
            int on = X.menu_open || hov;
            rfb_fill_rrect(s, it[i].x, by, it[i].w, bh, 7,
                           on ? 0xFF : 0xE8, on ? 0xA8 : 0x90, on ? 0x6A : 0x4E);
            for (int gy = 0; gy < 3; gy++)
                for (int gx = 0; gx < 3; gx++)
                    rfb_fill_circle_aa(s, it[i].x + 13.5f + gx * 5, cy - 4.5f + gy * 5, 1.6f,
                                       0xFF, 0xFF, 0xFF, 255);
            rfb_draw_label(s, it[i].x + 32, cy, 0, "Apps", 0xFF, 0xFF, 0xFF);
        } else if (it[i].kind == TB_LAUNCH) {
            uint8_t v = hov ? 0x3A : 0x2C;
            rfb_fill_rrect(s, it[i].x, by, it[i].w, bh, 6, v, (uint8_t)(v-2), (uint8_t)(v-4));
            rfb_draw_label(s, it[i].x + 12, cy, it[i].w - 20,
                           apps[it[i].arg].name, 0xE0,0xDD,0xDA);
        } else {
            XWindow *w = find_win(it[i].win);
            if (!w) continue;
            int focused = (w->id == X.focus) && !w->minimized;
            uint8_t v = focused ? 0x3C : hov ? 0x30 : 0x24;
            rfb_fill_rrect(s, it[i].x, by, it[i].w, bh, 6, v, (uint8_t)(v-2), (uint8_t)(v-4));
            if (focused)                  /* accent bar under the active app */
                rfb_fill_rrect(s, it[i].x + it[i].w/2 - 12, by + bh - 3, 24, 3, 1,
                               0xFF,0xA2,0x5E);
            const char *t = w->title[0] ? w->title : "x11";
            uint8_t fg = w->minimized ? 0x80 : focused ? 0xF0 : 0xC8;
            rfb_draw_label(s, it[i].x + 10, cy, it[i].w - 20, t,
                           fg, (uint8_t)(fg+1), (uint8_t)(fg+2));
        }
    }

    /* clock, right-aligned */
    time_t now = time(NULL);
    struct tm tmv;
    if (localtime_r(&now, &tmv)) {
        char buf[8];
        snprintf(buf, sizeof buf, "%02d:%02d", tmv.tm_hour, tmv.tm_min);
        rfb_draw_label(s, FB_W - 12 - rfb_label_width(buf), cy, 0, buf,
                       0xD2,0xCF,0xCC);
    }
}

/* The date & time dialog (lot-calendar, package xtiny-apps): open it, or
 * close it if it is already showing — a double-click on the clock toggles. */
#define CALENDAR_TITLE "Date & Time"
static void toggle_calendar(void) {
    for (int i = 0; i < MAX_WINDOWS; i++) {
        XWindow *w = &X.win[i];
        if (w->id && w->toplevel && w->mapped && !strcmp(w->title, CALENDAR_TITLE)) {
            close_window(w);
            return;
        }
    }
    App a;
    memset(&a, 0, sizeof a);
    snprintf(a.id, sizeof a.id, "calendar");
    snprintf(a.name, sizeof a.name, "%s", CALENDAR_TITLE);
    snprintf(a.exec, sizeof a.exec, "lot-calendar");
    snprintf(a.pkg, sizeof a.pkg, "xtiny-apps");
    a.installed = on_path(a.exec);
    launch_app(&a);
}

/* Returns 1 if the click was consumed by the taskbar. */
static int taskbar_click(rfb_server *s, int x, int y) {
    if (y < WORK_H) return 0;
    if (x >= FB_W - TB_CLOCK_W - 8) {    /* the clock: double-click = dialog */
        static uint64_t last;
        uint64_t now = rfb_now_ms();
        if (last && now - last < 450) { last = 0; menu_set(s, 0); toggle_calendar(); }
        else last = now;
        return 1;
    }
    TbItem it[24];
    int n = taskbar_layout(it, 24);
    for (int i = 0; i < n; i++) {
        if (x < it[i].x || x >= it[i].x + it[i].w) continue;
        if (it[i].kind == TB_MENU) {
            menu_set(s, !X.menu_open);
            rfb_damage(s, 0, WORK_H, FB_W, TASKBAR_H);
            return 1;
        }
        menu_set(s, 0);
        if (it[i].kind == TB_LAUNCH) {
            launch_app(&apps[it[i].arg]);
        } else {
            XWindow *w = find_win(it[i].win);
            if (!w) return 1;
            if (w->minimized)            restore_window(w);
            else if (w->id == X.focus)   minimize_window(w);   /* click again */
            else { stack_raise(w->id); set_focus(w->id); rfb_damage_full(s); }
        }
        return 1;
    }
    menu_set(s, 0);
    return 1;      /* bare taskbar — still ours, don't leak it to a window */
}

/* Pointer while the menu is open: hover rows, launch on press, close on a
 * press anywhere else. Returns 1 if the event was the menu's. */
static int menu_pointer(rfb_server *s, int buttons, int x, int y, int pressed) {
    if (!X.menu_open) return 0;
    MenuLayout m; menu_layout(&m);
    int row = menu_row_at(&m, x, y);
    if (row != X.menu_hover) { X.menu_hover = row; menu_damage(s); }
    int inside = x >= m.x && x < m.x + m.w && y >= m.y && y < m.y + m.h;
    if (pressed) {
        if (row >= 0) {
            const App *a = &apps[m.idx[row]];
            menu_set(s, 0);
            rfb_damage(s, 0, WORK_H, FB_W, TASKBAR_H);
            launch_app(a);
            return 1;
        }
        if (inside) return 1;             /* header / padding: stay open */
        if (y >= WORK_H) return 0;        /* the taskbar handles its own */
        menu_set(s, 0);
        rfb_damage(s, 0, WORK_H, FB_W, TASKBAR_H);
        return 1;                         /* a dismissing click goes nowhere */
    }
    (void)buttons;
    rfb_set_cursor(s, RFB_CUR_DEFAULT);
    return inside;
}

/* Keys while the menu is open: arrows move, Enter launches, Esc closes. */
static int menu_key(rfb_server *s, uint32_t ks, int down) {
    if (!X.menu_open) return 0;
    if (!down) return 1;
    MenuLayout m; menu_layout(&m);
    if (ks == 0xff1b) {                                   /* Escape */
        menu_set(s, 0);
        rfb_damage(s, 0, WORK_H, FB_W, TASKBAR_H);
    } else if (ks == 0xff52 || ks == 0xff54) {            /* Up / Down */
        int h = X.menu_hover;
        if (ks == 0xff54) h = h < 0 ? 0 : (h + 1) % (m.n ? m.n : 1);
        else              h = h <= 0 ? m.n - 1 : h - 1;
        X.menu_hover = h;
        menu_damage(s);
    } else if ((ks == 0xff51 || ks == 0xff53) && m.cols > 1) {   /* Left / Right */
        int h = X.menu_hover < 0 ? 0 : X.menu_hover;
        int to = h + (ks == 0xff53 ? m.rows : -m.rows);
        if (to >= 0 && to < m.n) h = to;             /* no cell there: stay */
        X.menu_hover = h;
        menu_damage(s);
    } else if ((ks == 0xff0d || ks == 0xff8d) && X.menu_hover >= 0 && X.menu_hover < m.n) {
        const App *a = &apps[m.idx[X.menu_hover]];
        menu_set(s, 0);
        rfb_damage(s, 0, WORK_H, FB_W, TASKBAR_H);
        launch_app(a);
    }
    return 1;
}

/* ── desktop ──────────────────────────────────────────────────────────────── */
/* A quiet vertical gradient. Each row is one flat colour, and adjacent
 * rows mostly share one (the channels move ~25 levels over the whole
 * height), so RRE sends it as a few dozen tall bands, not per-pixel data. */
static void draw_desktop(rfb_server *s) {
    static const int top[3] = {0x48, 0x38, 0x2E}, bot[3] = {0x26, 0x1E, 0x19};
    int h = WORK_H > 1 ? WORK_H : 1;
    for (int y = 0; y < WORK_H; y++) {
        uint8_t c[3];
        for (int k = 0; k < 3; k++)
            c[k] = (uint8_t)(top[k] + (bot[k] - top[k]) * y / (h - 1 > 0 ? h - 1 : 1));
        rfb_fill_rect(s, 0, y, FB_W, 1, c[0], c[1], c[2]);
    }
}

/* ── resize ───────────────────────────────────────────────────────────────── */
/* The viewer asked for a new screen size: adopt it, keep every title bar
 * reachable, refit maximised windows, and tell clients watching the root. */
static int on_resize(rfb_server *s, int *w, int *h) {
    (void)s;
    if (*w < FB_MIN_W) *w = FB_MIN_W;
    if (*h < FB_MIN_H) *h = FB_MIN_H;
    if (*w > FB_MAX_W) *w = FB_MAX_W;
    if (*h > FB_MAX_H) *h = FB_MAX_H;
    X.fbw = *w; X.fbh = *h;
    X.win[0].w = *w; X.win[0].h = *h;
    if (X.ptr_x >= *w) X.ptr_x = *w - 1;
    if (X.ptr_y >= *h) X.ptr_y = *h - 1;
    for (int i = 0; i < MAX_WINDOWS; i++) {
        XWindow *t = &X.win[i];
        if (!t->id || !t->toplevel) continue;
        if (t->maxed) {
            t->frame.x = 0; t->frame.y = 0;
            resize_window(t, FB_W - 2*RFB_BORDER, WORK_H - RFB_TITLE_H - RFB_BORDER);
            continue;
        }
        int fw = t->w + 2*RFB_BORDER;
        if (t->frame.x + fw > FB_W) t->frame.x = FB_W - fw;
        if (t->frame.x < 0) t->frame.x = 0;
        if (t->frame.y > WORK_H - RFB_TITLE_H) t->frame.y = WORK_H - RFB_TITLE_H;
        if (t->frame.y < 0) t->frame.y = 0;
    }
    for (int i = 0; i < MAX_XCLIENTS; i++) {
        XClient *c = &X.cl[i];
        if (c->fd < 0 || c->state != 2 || !(c->root_evmask & 0x20000)) continue;
        uint8_t ev[32]; memset(ev, 0, sizeof ev);
        ev[0] = 22;                               /* ConfigureNotify */
        p32(ev, 4, ROOT_ID); p32(ev, 8, ROOT_ID);
        p16(ev, 20, (uint16_t)*w); p16(ev, 22, (uint16_t)*h);
        send_event(c, ev);
    }
    printf("[xtiny] screen %dx%d\n", *w, *h);
    fflush(stdout);
    return 1;
}

/* ── sound ────────────────────────────────────────────────────────────────── */
/* /tmp/.lot-audio: the desktop's tiny sound server. One source at a time
 * writes raw PCM (s16le, stereo, 48 kHz — RFB_AUDIO_*); it is forwarded to
 * the viewer over the RFB connection (librfb's QEMU audio extension), so
 * sound plays wherever the X display is open. A newer connection replaces
 * the current one; a source closing its socket ends the stream, and the
 * viewer drops what it still has queued (that is how lotplay flushes on
 * pause and seek). Read even with no viewer, so a source never blocks. */
#define AUDIO_SOCK "/tmp/.lot-audio"

static void audio_close(rfb_server *s) {
    if (X.au_fd >= 0) close(X.au_fd);
    X.au_fd = -1;
    X.au_npart = 0;
    rfb_audio_flush(s);
}

static void audio_poll(rfb_server *s) {
    if (X.au_lfd < 0) return;
    int fd = accept(X.au_lfd, NULL, NULL);
    if (fd >= 0) {
        audio_close(s);                       /* the newest source wins */
        int fl = fcntl(fd, F_GETFL, 0);
        if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        X.au_fd = fd;
    }
    if (X.au_fd < 0) return;
    uint8_t buf[16384 + 4];
    for (int rounds = 0; rounds < 8; rounds++) {
        memcpy(buf, X.au_part, (size_t)X.au_npart);
        ssize_t r = read(X.au_fd, buf + X.au_npart, 16384);
        if (r == 0) { audio_close(s); return; }
        if (r < 0) {
            if (errno == EINTR) continue;
            if (errno != EAGAIN && errno != EWOULDBLOCK) audio_close(s);
            return;
        }
        size_t n = (size_t)X.au_npart + (size_t)r;
        size_t whole = n & ~(size_t)3;           /* forward whole frames only */
        X.au_npart = (int)(n - whole);
        memcpy(X.au_part, buf + whole, (size_t)X.au_npart);
        rfb_audio_send(s, buf, whole);           /* dropped if nobody listens */
    }
}

/* ── librfb callbacks ─────────────────────────────────────────────────────── */
static void on_idle(rfb_server *s) {
    X.srv = s;

    /* Reap launched apps so they don't linger as zombies. */
    while (waitpid(-1, NULL, WNOHANG) > 0) { }
    refresh_apps(0);

    /* The clock only changes once a minute; damage it then, so an idle
     * desktop still sends the odd tiny update instead of a full frame. */
    {
        static int last_min = -1;
        time_t now = time(NULL);
        struct tm tmv;
        if (localtime_r(&now, &tmv) && tmv.tm_min != last_min) {
            last_min = tmv.tm_min;
            rfb_damage(s, FB_W - TB_CLOCK_W - 8, WORK_H, TB_CLOCK_W + 8, TASKBAR_H);
        }
    }
    audio_poll(s);
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
    draw_desktop(s);
    /* back to front, so the front-most window lands on top */
    for (int i = X.nstack - 1; i >= 0; i--) {
        XWindow *w = find_win(X.stack[i]);
        if (!w || !w->toplevel || !w->mapped || w->minimized) continue;
        if (w->override_) {
            rfb_drop_shadow(s, w->x, w->y, w->w, w->h, 90);
            blit_window(s, w, w->x, w->y);
            continue;
        }
        w->frame.title = w->title[0] ? w->title : "x11";
        w->frame.inactive = (w->id != X.focus);
        rfb_draw_winframe(s, &w->frame);
        blit_window(s, w, rfb_winframe_cx(&w->frame),
                    rfb_winframe_cy(&w->frame));
    }
    draw_taskbar(s);          /* always on top of the windows */
    if (X.menu_open) draw_menu(s);
}

/* ── edge resize ──────────────────────────────────────────────────────────── */
enum { RZ_L = 1, RZ_R = 2, RZ_B = 4 };
#define RZ_OUT 6     /* grab zone outside the frame (where the shadow is) */
#define RZ_IN  3     /* ... and just inside it */

/* Which resize edges of which window are under the point. The front-most
 * window whose (zone-expanded) frame contains the point decides, so an
 * edge buried under another window can't be grabbed. */
static int resize_edges_at(int x, int y, XWindow **out) {
    *out = NULL;
    if (y >= WORK_H) return 0;
    for (int i = 0; i < X.nstack; i++) {
        XWindow *w = find_win(X.stack[i]);
        if (!w || !w->mapped || w->minimized || !w->toplevel) continue;
        if (w->override_) {                       /* popups cover what they cover */
            if (x >= w->x && x < w->x + w->w && y >= w->y && y < w->y + w->h) return 0;
            continue;
        }
        int fx = w->frame.x, fy = w->frame.y;
        int fw = w->w + 2*RFB_BORDER, fh = RFB_TITLE_H + w->h + RFB_BORDER;
        if (x < fx - RZ_OUT || x >= fx + fw + RZ_OUT ||
            y < fy || y >= fy + fh + RZ_OUT)
            continue;
        if (w->maxed) return 0;
        int e = 0;
        if (y >= fy + RFB_TITLE_H) {              /* title bar = move, not resize */
            if (x < fx + RZ_IN)       e |= RZ_L;
            if (x >= fx + fw - RZ_IN) e |= RZ_R;
        }
        if (y >= fy + fh - RZ_IN)     e |= RZ_B;
        if (e) *out = w;
        return e;
    }
    return 0;
}

static int resize_cursor(int e) {
    if ((e & RZ_B) && (e & RZ_L)) return RFB_CUR_NESW_RESIZE;
    if ((e & RZ_B) && (e & RZ_R)) return RFB_CUR_NWSE_RESIZE;
    if (e & RZ_B)                 return RFB_CUR_NS_RESIZE;
    return RFB_CUR_EW_RESIZE;
}

/* Apply the pending edge-drag geometry. Throttled while dragging: each
 * resize makes the client re-layout and repaint (xterm reflows its whole
 * screen), so per-motion-event resizes would just queue up behind it. */
static void resize_apply(rfb_server *s, int force) {
    XWindow *w = find_win(X.rz_win);
    if (!w) { X.rz_win = 0; return; }
    if (w->w == X.rz_nw && w->h == X.rz_nh && w->frame.x == X.rz_nx) return;
    uint64_t now = rfb_now_ms();
    if (!force && now - X.rz_last_ms < 80) return;
    X.rz_last_ms = now;
    w->frame.x = X.rz_nx;
    resize_window(w, X.rz_nw, X.rz_nh);
    rfb_damage_full(s);
}

/* ── pointer events, X semantics ──────────────────────────────────────────
 * Button and motion events go to the deepest window under the pointer and
 * propagate up to the first ancestor that selected them; a ButtonPress
 * starts an implicit grab on the window that got it, until every button is
 * up; Enter/LeaveNotify follow the pointer from window to window (with the
 * virtual ones for the windows in between). GTK 2 needs all three: its
 * buttons are input-only child windows that activate on release only after
 * an EnterNotify, and its widgets often select presses on an ancestor. */
static void send_pointer_ev(XWindow *ew, int type, int detail, uint32_t child,
                            int x, int y, uint16_t state) {
    XClient *c = win_client(ew);
    if (!c) return;
    int ox, oy;
    win_origin(ew, &ox, &oy);
    uint8_t ev[32]; memset(ev, 0, sizeof ev);
    ev[0] = (uint8_t)type;
    ev[1] = (uint8_t)detail;
    p32(ev, 4, (uint32_t)rfb_now_ms());
    p32(ev, 8, ROOT_ID);
    p32(ev, 12, ew->id);
    p32(ev, 16, child);
    p16(ev, 20, (uint16_t)x); p16(ev, 22, (uint16_t)y);
    p16(ev, 24, (uint16_t)(x - ox)); p16(ev, 26, (uint16_t)(y - oy));
    p16(ev, 28, state);
    if (type == 7 || type == 8) {              /* Enter/LeaveNotify */
        ev[30] = 0;                            /* mode: Normal */
        ev[31] = (uint8_t)(2 | (in_focus_tree(ew) ? 1 : 0));   /* same-screen, focus */
    } else {
        ev[30] = 1;                            /* same-screen */
    }
    send_event(c, ev);
}

/* First window from src upwards that selected `need`; *child = its child on
 * the way down to src (0 when it is src itself). The root is xtiny's own. */
static XWindow *pointer_target(XWindow *src, uint32_t need, uint32_t *child) {
    XWindow *prev = NULL;
    for (XWindow *t = src; t && t->id != ROOT_ID; t = find_win(t->parent)) {
        if (t->evmask & need) { *child = prev ? prev->id : 0; return t; }
        prev = t;
    }
    *child = 0;
    return NULL;
}

#define PTR_MAXDEPTH 32
static int pointer_chain(XWindow *w, XWindow **out) {     /* w, its parent, ... root */
    int n = 0;
    while (w && n < PTR_MAXDEPTH) {
        out[n++] = w;
        if (w->id == ROOT_ID) break;
        w = find_win(w->parent);
    }
    return n;
}

static void crossing_one(XWindow *w, int type, int detail, uint32_t child,
                         int x, int y, uint16_t state, XWindow *only) {
    if (!w || w->id == ROOT_ID || (only && w != only)) return;
    if (!(w->evmask & (type == 7 ? 0x10 : 0x20))) return;   /* Enter/LeaveWindowMask */
    send_pointer_ev(w, type, detail, child, x, y, state);
}

/* The pointer moved from `from` to `to` (NULL = the root). With a grab,
 * only the grab window hears about it. Details: 0 Ancestor, 1 Virtual,
 * 2 Inferior, 3 Nonlinear, 4 NonlinearVirtual. */
static void pointer_crossing(XWindow *from, XWindow *to, int x, int y, uint16_t state,
                             XWindow *only) {
    XWindow *root = find_win(ROOT_ID);
    if (!from) from = root;
    if (!to) to = root;
    if (!from || !to || from == to) return;
    XWindow *ca[PTR_MAXDEPTH], *cb[PTR_MAXDEPTH];
    int na = pointer_chain(from, ca), nb = pointer_chain(to, cb);
    int ia = -1, ib = -1;
    for (int i = 0; i < na && ia < 0; i++)
        for (int j = 0; j < nb; j++)
            if (ca[i] == cb[j]) { ia = i; ib = j; break; }
    if (ia < 0) return;
    if (ia == 0) {                              /* into a descendant of from */
        crossing_one(from, 8, 2, cb[ib - 1]->id, x, y, state, only);
        for (int j = ib - 1; j >= 1; j--) crossing_one(cb[j], 7, 1, cb[j - 1]->id, x, y, state, only);
        crossing_one(to, 7, 0, 0, x, y, state, only);
    } else if (ib == 0) {                       /* out to an ancestor of from */
        crossing_one(from, 8, 0, 0, x, y, state, only);
        for (int i = 1; i < ia; i++) crossing_one(ca[i], 8, 1, ca[i - 1]->id, x, y, state, only);
        crossing_one(to, 7, 2, ca[ia - 1]->id, x, y, state, only);
    } else {                                    /* across */
        crossing_one(from, 8, 3, 0, x, y, state, only);
        for (int i = 1; i < ia; i++) crossing_one(ca[i], 8, 4, ca[i - 1]->id, x, y, state, only);
        for (int j = ib - 1; j >= 1; j--) crossing_one(cb[j], 7, 4, cb[j - 1]->id, x, y, state, only);
        crossing_one(to, 7, 3, 0, x, y, state, only);
    }
}

static void on_pointer(rfb_server *s, int buttons, int x, int y) {
    X.srv = s;
    X.ptr_x = x; X.ptr_y = y;
    static int prev_btn1 = 0;
    static int swallow_drag = 0;      /* press consumed by a button/taskbar */

    /* The Apps menu sits above everything and owns the pointer while open
     * (a press on the taskbar falls through so the Apps button toggles). */
    {
        int pressed = (buttons & 1) && !prev_btn1;
        if (menu_pointer(s, buttons, x, y, pressed)) {
            if (pressed) swallow_drag = 1;
            prev_btn1 = buttons & 1;
            return;
        }
    }

    /* Hover feedback: taskbar buttons, and the window-button glyphs of the
     * front-most window under the pointer. Only the strips that changed
     * are damaged. */
    {
        int th = taskbar_item_at(x, y);
        if (th != X.tb_hover) {
            X.tb_hover = th;
            rfb_damage(s, 0, WORK_H, FB_W, TASKBAR_H);
        }
        XWindow *ht = toplevel_at(x, y);
        for (int i = 0; i < MAX_WINDOWS; i++) {
            XWindow *w = &X.win[i];
            if (!w->id || !w->toplevel || w->override_) continue;
            int hv = (w == ht) && !(buttons & 1) &&
                     rfb_winframe_over_buttons(&w->frame, x, y);
            if (hv != w->frame.hover) {
                w->frame.hover = hv;
                rfb_damage_titlebar(s, &w->frame);
            }
        }
    }

    /* An edge drag in progress owns the pointer until release. */
    if (X.rz_win) {
        int dx = x - X.rz_px, dy = y - X.rz_py;
        int nw = X.rz_w, nh = X.rz_h;
        if (X.rz_edges & RZ_R) nw += dx;
        if (X.rz_edges & RZ_L) nw -= dx;
        if (X.rz_edges & RZ_B) nh += dy;
        if (nw < 160) nw = 160;
        if (nh < 60)  nh = 60;
        if (nw > FB_W - 2*RFB_BORDER) nw = FB_W - 2*RFB_BORDER;
        if (nh > WORK_H - RFB_TITLE_H - RFB_BORDER) nh = WORK_H - RFB_TITLE_H - RFB_BORDER;
        X.rz_nw = nw; X.rz_nh = nh;
        X.rz_nx = (X.rz_edges & RZ_L) ? X.rz_x + (X.rz_w - nw) : X.rz_x;
        int done = !(buttons & 1);
        resize_apply(s, done);
        if (done) { X.rz_win = 0; prev_btn1 = 0; swallow_drag = 0; }
        rfb_set_cursor(s, resize_cursor(X.rz_edges));
        return;
    }

    /* Click-to-raise/focus, before anything else looks at the click: a
     * press on any part of a window (chrome or content) brings it to the
     * front and gives it the keyboard. */
    int btn1 = buttons & 1;
    if (btn1 && !prev_btn1 && !X.pgrab_win) {
        if (taskbar_click(s, x, y)) {
            swallow_drag = 1;
            prev_btn1 = btn1;
            X.btn_state = 0;
            return;
        }
        XWindow *rw;
        int e = resize_edges_at(x, y, &rw);
        if (e) {                          /* start an edge drag */
            if (stack_raise(rw->id)) rfb_damage_full(s);
            set_focus(rw->id);
            X.rz_win = rw->id; X.rz_edges = e;
            X.rz_px = x; X.rz_py = y;
            X.rz_x = rw->frame.x; X.rz_w = rw->w; X.rz_h = rw->h;
            X.rz_nx = rw->frame.x; X.rz_nw = rw->w; X.rz_nh = rw->h;
            X.rz_last_ms = 0;
            swallow_drag = 1;
            prev_btn1 = btn1;
            X.btn_state = 0;
            rfb_set_cursor(s, resize_cursor(e));
            return;
        }
        XWindow *top = toplevel_at(x, y);
        if (top && top->override_) top = NULL;    /* a popup: just deliver */
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
    if (!swallow_drag && !X.pgrab_win) {
        XWindow *top = toplevel_at(x, y);
        for (int i = 0; i < MAX_WINDOWS; i++) {
            XWindow *w = &X.win[i];
            if (!w->id || !w->toplevel || !w->mapped || w->minimized || w->override_) continue;
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
    XWindow *gw = X.pgrab_win ? find_win(X.pgrab_win) : NULL;
    XWindow *ig = X.igrab_win ? find_win(X.igrab_win) : NULL;
    /* an active grab reports to the grab window, except (owner_events) the
     * grabbing client's own windows, which get their events as usual */
    int grab_redirect = gw && !(X.pgrab_owner && w && w->creator == gw->creator);
    uint16_t st0 = (uint16_t)(X.btn_state | X.mod_state);

    /* Enter/LeaveNotify */
    {
        XWindow *pw = X.ptr_win ? find_win(X.ptr_win) : NULL;
        if (w != pw) {
            pointer_crossing(pw, w, x, y, st0, gw ? gw : ig);
            X.ptr_win = w ? w->id : 0;
        }
    }

    /* ButtonPress / ButtonRelease */
    for (int b = 0; b < 3; b++) {
        uint16_t bit = (uint16_t)(0x100 << b);
        int was = (X.btn_state & bit) != 0;
        int now = (newstate & bit) != 0;
        if (was == now) continue;
        uint32_t need = now ? 0x4 : 0x8;
        XWindow *ew = NULL;
        uint32_t child = 0;
        if (grab_redirect) {
            if ((X.pgrab_mask | 0x4 | 0x8) & need) ew = gw;
        } else if (ig && !gw) {
            if (ig->evmask & need) ew = ig;           /* implicit grab: owner_events off */
        } else {
            ew = pointer_target(w, need, &child);
        }
        if (ew) send_pointer_ev(ew, now ? 4 : 5, b + 1, child, x, y,
                                (uint16_t)(X.btn_state | X.mod_state));
        if (now && ew && !gw && !ig) { X.igrab_win = ew->id; ig = ew; }
        X.btn_state = (uint16_t)(now ? (X.btn_state | bit) : (X.btn_state & ~bit));
    }

    /* Wheel: RFB mask bits 3..6 are X buttons 4..7 (up, down, left, right);
     * the viewer sends each click as the bit set, then cleared. X clients
     * (NetSurf, GTK, xterm, Xt scrollbars) expect a ButtonPress + Release
     * pair per click, routed like any press — active grab, implicit grab,
     * propagation to the first window that selected ButtonPress — with the
     * release going to the window that got the press, as the implicit grab
     * would, and no grab left behind. Press state is the state before the
     * click; the release adds Button4/5Mask (6/7 have no mask bit). */
    {
        static int prev_wheel = 0;
        int wheel = (buttons >> 3) & 0xf;
        for (int b = 0; b < 4; b++) {
            if (!((wheel >> b) & 1) || ((prev_wheel >> b) & 1)) continue;
            int xb = 4 + b;
            XWindow *ew = NULL;
            uint32_t child = 0;
            int grabbed = 0;
            if (grab_redirect) {
                ew = gw; grabbed = 1;                 /* active grab: always reported */
            } else if (ig && !gw) {
                if (ig->evmask & 0x4) ew = ig;
            } else {
                ew = pointer_target(w, 0x4, &child);
            }
            if (!ew) continue;
            uint16_t st = (uint16_t)(X.btn_state | X.mod_state);
            send_pointer_ev(ew, 4, xb, child, x, y, st);
            if (grabbed || (ew->evmask & 0x8)) {
                uint16_t rst = st;
                if (xb <= 5) rst |= (uint16_t)(0x100 << (xb - 1));
                send_pointer_ev(ew, 5, xb, child, x, y, rst);
            }
        }
        prev_wheel = wheel;
    }

    /* MotionNotify */
    {
        uint32_t need = 0x40;                                  /* PointerMotion */
        if (newstate) need |= 0x2000;                          /* ButtonMotion */
        need |= newstate & (0x100 | 0x200 | 0x400);            /* Button1..3Motion */
        XWindow *ew = NULL;
        uint32_t child = 0;
        if (grab_redirect) {
            if (X.pgrab_mask & need) ew = gw;
        } else if (ig && !gw) {
            if (ig->evmask & need) ew = ig;
        } else {
            ew = pointer_target(w, need, &child);
        }
        if (ew) send_pointer_ev(ew, 6, 0, child, x, y, (uint16_t)(newstate | X.mod_state));
    }
    X.btn_state = newstate;
    if (!newstate) X.igrab_win = 0;

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
        if (!buttons) {                   /* resize zones beat everything */
            XWindow *rw;
            int e = resize_edges_at(x, y, &rw);
            if (e) shape = resize_cursor(e);
        }
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
    if (menu_key(s, ks, down)) return;
    uint8_t code = keysym_to_keycode(ks);
    if (!code) return;

    /* Deliver to the FOCUS window, not whatever the pointer happens to be
     * over. Focus is a top-level, but the widget that selected for key
     * events is usually a child (xterm's VT window), so hand the event to
     * the deepest descendant that actually asked for it. */
    uint32_t need = down ? 0x1 : 0x2;
    XWindow *kg = X.kgrab_win ? find_win(X.kgrab_win) : NULL;
    if (kg) {
        /* a grabbed keyboard (an open menu) goes to the grab window */
        XClient *c = win_client(kg);
        if (!c) return;
        int ox, oy;
        win_origin(kg, &ox, &oy);
        uint8_t ev[32]; memset(ev, 0, sizeof ev);
        ev[0] = down ? 2 : 3;
        ev[1] = code;
        p32(ev, 4, (uint32_t)rfb_now_ms());
        p32(ev, 8, ROOT_ID);
        p32(ev, 12, kg->id);
        p16(ev, 20, (uint16_t)X.ptr_x); p16(ev, 22, (uint16_t)X.ptr_y);
        p16(ev, 24, (uint16_t)(X.ptr_x - ox)); p16(ev, 26, (uint16_t)(X.ptr_y - oy));
        p16(ev, 28, (uint16_t)(X.btn_state | X.mod_state));
        ev[30] = 1;
        send_event(c, ev);
        return;
    }
    XWindow *top = find_win(X.focus);
    if (!top) {
        if (xtrace) { printf("[xtiny] key: no focus window\n"); fflush(stdout); }
        return;
    }

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
    X.fbw = 1024; X.fbh = 768;
    const char *geo = getenv("XTINY_GEOMETRY");
    if (geo) {
        int gw = 0, gh = 0;
        if (sscanf(geo, "%dx%d", &gw, &gh) == 2) on_resize(NULL, &gw, &gh);
    }
    X.tb_hover = -1;
    X.menu_hover = -1;
    refresh_apps(1);
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

    /* sound socket */
    X.au_fd = -1;
    unlink(AUDIO_SOCK);
    X.au_lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (X.au_lfd >= 0) {
        struct sockaddr_un au;
        memset(&au, 0, sizeof au);
        au.sun_family = AF_UNIX;
        strcpy(au.sun_path, AUDIO_SOCK);
        if (bind(X.au_lfd, (struct sockaddr *)&au, sizeof au) < 0 || listen(X.au_lfd, 2) < 0) {
            perror("[xtiny] audio socket");
            close(X.au_lfd);
            X.au_lfd = -1;
        } else {
            int afl = fcntl(X.au_lfd, F_GETFL, 0);
            if (afl >= 0) fcntl(X.au_lfd, F_SETFL, afl | O_NONBLOCK);
            fcntl(X.au_lfd, F_SETFD, FD_CLOEXEC);
        }
    }

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
        .on_resize  = on_resize,
        .audio      = 1,
    };
    return rfb_run(&cfg);
}
