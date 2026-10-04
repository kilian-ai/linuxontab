/*
 * librfb.c — minimal RFB 3.8 display-server kit for LinuxOnTab WASM guests
 *
 * Extracted from the original monolithic vnc-server.c. See librfb.h for
 * the app-facing API and build-vnc-demos.sh for the build.
 */
#include "librfb.h"
#include "librfb_font.h"

#include <errno.h>
#include <math.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define FB_BPP 4
#define RFB_MAX_DAMAGE 16

struct rfb_server {
    rfb_config cfg;
    uint8_t *fb;
    int w, h;
    int cfd;
    /* damage state */
    int full;
    int nrects;
    struct { int x, y, w, h; } rects[RFB_MAX_DAMAGE];
    /* repair-nudge state (see push_keepalive) */
    int saw_fbreq;      /* client update loop is live — nudges allowed */
    int cursor;         /* last shape sent (see rfb_set_cursor) */
    /* ExtendedDesktopSize (see the SetDesktopSize handler) */
    int eds_ok;         /* viewer advertised the pseudo-encoding */
    int eds_pending;    /* send an ExtendedDesktopSize rect next update */
    int eds_reason, eds_status;
};

/* ── wire helpers ─────────────────────────────────────────────────────────── */
/* All socket I/O is NONBLOCKING with a usleep poll on EAGAIN. This is not a
 * style choice: on the WASM kernel, a task blocked in read()/accept() with no
 * kernel timers pending parks the CPU worker forever (deadline==0 → infinite
 * atomic wait in arch_cpu_idle) and injected network IRQs fail to wake it —
 * the guest goes comatose until some unrelated event fires. usleep() arms a
 * kernel timer, so the idle park always has a timeout; each expiry runs
 * pending softirqs, which is what actually delivers our TCP traffic. */
#define POLL_US 5000

static void set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    /* An app the server launches (see xtiny's taskbar) must not inherit the
     * RFB sockets across exec — a stray copy would hold the connection open
     * after the server closed it. */
    fcntl(fd, F_SETFD, FD_CLOEXEC);
}

/* Give up on a connection that stays silent/unwritable this long. A live
 * client requests updates continuously (~30/s), so half a minute of
 * nothing means the peer is gone without a RST/FIN we could see — e.g.
 * the browser page reloaded and its injected-TCP relay simply vanished.
 * Without this, serve_client() polls the zombie fd forever and the
 * single-client server can never accept anyone else. */
#define IO_STALL_LIMIT_US (30 * 1000 * 1000)

static void write_all(rfb_server *s, const void *buf, size_t n) {
    const char *p = buf;
    long stalled = 0;
    while (n) {
        ssize_t r = write(s->cfd, p, n);
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if ((stalled += POLL_US) >= IO_STALL_LIMIT_US) return;
            usleep(POLL_US);
            continue;
        }
        if (r <= 0) { if (errno == EINTR) continue; return; }
        stalled = 0;
        p += r; n -= r;
    }
}

/* Repair nudge, fired from ANY stalled read. The browser→guest direction
 * of the slirp transport loses segments (guest-side backlog tail-drop),
 * and TCP ordering then blocks every later client byte behind the hole.
 * The page's retransmit timers are throttled to ≥1 s in hidden tabs
 * (1/min after ~5 min), but its GO-BACK-N repair also fires event-driven
 * whenever the client ENQUEUES a message. So while a read is silent, WE
 * push a Bell on our own (unthrottled, usleep-paced) clock; the client
 * answers a Bell with a no-op SetEncodings, and that enqueue triggers the
 * page's hole repair — a fully timer-free repair chain. Bell/SetEncodings
 * are a pure SIDE-CHANNEL: neither touches the update request/response
 * pipeline, so a nudge during a hiccup costs nothing when there is no
 * hole. (An earlier design pushed empty FramebufferUpdates and swallowed
 * the client's answering request — that turned every short hiccup into
 * extra 300 ms dead cycles. Don't.) This must live HERE, not only at the
 * message boundary: repair bursts coalesce messages across segment
 * boundaries, so a lost segment can strand the server mid-message (type
 * byte read, body missing) — exactly when repair is needed most. */
static void push_keepalive(rfb_server *s) {
    if (!s->saw_fbreq) return;
    uint8_t bell = 2;   /* RFB server→client Bell */
    write_all(s, &bell, 1);
}

static int read_all(rfb_server *s, void *buf, size_t n) {
    char *p = buf;
    long stalled = 0, ka_mark = 0;
    while (n) {
        ssize_t r = read(s->cfd, p, n);
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if ((stalled += POLL_US) >= IO_STALL_LIMIT_US) return 0;
            if (stalled - ka_mark >= 300000) {   /* 300 ms of silence */
                ka_mark = stalled;
                push_keepalive(s);
            }
            if (s->cfg.on_idle) s->cfg.on_idle(s);
            usleep(POLL_US);
            continue;
        }
        if (r == 0) return 0;
        if (r < 0) { if (errno == EINTR) continue; return 0; }
        stalled = 0;
        p += r; n -= r;
    }
    return 1;
}

/* ── accessors ────────────────────────────────────────────────────────────── */
uint8_t *rfb_fb(rfb_server *s)   { return s->fb; }
int      rfb_w(rfb_server *s)    { return s->w; }
int      rfb_h(rfb_server *s)    { return s->h; }
void    *rfb_user(rfb_server *s) { return s->cfg.user; }

uint64_t rfb_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

/* ── pointer shape ────────────────────────────────────────────────────────── */
static const char *const CURSOR_NAMES[RFB_CUR__COUNT] = {
    "default", "text", "pointer", "crosshair", "wait",
    "move", "ns-resize", "ew-resize", "nwse-resize", "nesw-resize",
};

void rfb_set_cursor(rfb_server *s, int shape) {
    if (shape < 0 || shape >= RFB_CUR__COUNT) shape = RFB_CUR_DEFAULT;
    if (s->cursor == shape || s->cfd < 0) return;
    s->cursor = shape;
    char body[64];
    int n = snprintf(body, sizeof body, "\x01rfb-cursor:%s",
                     CURSOR_NAMES[shape]);
    if (n < 0) return;
    uint8_t hdr[8];
    memset(hdr, 0, sizeof hdr);
    hdr[0] = 3;                       /* ServerCutText */
    uint32_t len_be = htonl((uint32_t)n);
    memcpy(hdr + 4, &len_be, 4);
    write_all(s, hdr, 8);
    write_all(s, body, (size_t)n);
}

/* ── damage ───────────────────────────────────────────────────────────────── */
void rfb_damage_full(rfb_server *s) {
    s->full = 1;
    s->nrects = 0;
}

void rfb_damage(rfb_server *s, int x, int y, int w, int h) {
    if (s->full) return;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > s->w) w = s->w - x;
    if (y + h > s->h) h = s->h - y;
    if (w <= 0 || h <= 0) return;
    if (s->nrects >= RFB_MAX_DAMAGE) { rfb_damage_full(s); return; }
    s->rects[s->nrects].x = x;
    s->rects[s->nrects].y = y;
    s->rects[s->nrects].w = w;
    s->rects[s->nrects].h = h;
    s->nrects++;
}

/* ── framebuffer primitives ───────────────────────────────────────────────── */
static void put_px(rfb_server *s, int x, int y,
                   uint8_t b, uint8_t g, uint8_t r) {
    if ((unsigned)x >= (unsigned)s->w || (unsigned)y >= (unsigned)s->h) return;
    uint8_t *p = s->fb + (y*s->w + x)*FB_BPP;
    p[0]=b; p[1]=g; p[2]=r; p[3]=0xff;
}
void rfb_fill_rect(rfb_server *s, int x, int y, int w, int h,
                   uint8_t b, uint8_t g, uint8_t r) {
    for (int dy=0; dy<h; dy++)
        for (int dx=0; dx<w; dx++)
            put_px(s, x+dx, y+dy, b, g, r);
}
void rfb_fill_circle(rfb_server *s, int cx, int cy, int rad,
                     uint8_t b, uint8_t g, uint8_t r) {
    int r2 = rad*rad;
    for (int dy=-rad; dy<=rad; dy++)
        for (int dx=-rad; dx<=rad; dx++)
            if (dx*dx + dy*dy <= r2)
                put_px(s, cx+dx, cy+dy, b, g, r);
}

/* ── alpha blending + anti-aliased shapes ─────────────────────────────────── */
void rfb_blend_px(rfb_server *s, int x, int y,
                  uint8_t b, uint8_t g, uint8_t r, int a) {
    if (a <= 0) return;
    if ((unsigned)x >= (unsigned)s->w || (unsigned)y >= (unsigned)s->h) return;
    uint8_t *p = s->fb + (y*s->w + x)*FB_BPP;
    if (a >= 255) { p[0]=b; p[1]=g; p[2]=r; p[3]=0xff; return; }
    int ia = 255 - a;
    p[0] = (uint8_t)((p[0]*ia + b*a + 127) / 255);
    p[1] = (uint8_t)((p[1]*ia + g*a + 127) / 255);
    p[2] = (uint8_t)((p[2]*ia + r*a + 127) / 255);
    p[3] = 0xff;
}
void rfb_blend_rect(rfb_server *s, int x, int y, int w, int h,
                    uint8_t b, uint8_t g, uint8_t r, int a) {
    for (int dy = 0; dy < h; dy++)
        for (int dx = 0; dx < w; dx++)
            rfb_blend_px(s, x+dx, y+dy, b, g, r, a);
}
static float clamp01(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

/* Coverage of a pixel by a corner arc: 1 inside radius rad around (cx,cy),
 * fading over one pixel at the edge. */
static float arc_cov(float px, float py, float cx, float cy, float rad) {
    float dx = px - cx, dy = py - cy;
    return clamp01(rad - sqrtf(dx*dx + dy*dy) + 0.5f);
}

void rfb_fill_rrect(rfb_server *s, int x, int y, int w, int h, int rad,
                    uint8_t b, uint8_t g, uint8_t r) {
    if (rad*2 > w) rad = w/2;
    if (rad*2 > h) rad = h/2;
    for (int dy = 0; dy < h; dy++) {
        for (int dx = 0; dx < w; dx++) {
            float cov = 1.0f;
            int inx = dx < rad ? 0 : dx >= w - rad ? 2 : 1;
            int iny = dy < rad ? 0 : dy >= h - rad ? 2 : 1;
            if (inx != 1 && iny != 1) {
                float ccx = inx == 0 ? rad : w - rad;
                float ccy = iny == 0 ? rad : h - rad;
                cov = arc_cov(dx + 0.5f, dy + 0.5f, ccx, ccy, (float)rad);
            }
            rfb_blend_px(s, x+dx, y+dy, b, g, r, (int)(cov * 255.0f + 0.5f));
        }
    }
}

void rfb_fill_circle_aa(rfb_server *s, float cx, float cy, float rad,
                        uint8_t b, uint8_t g, uint8_t r, int a) {
    int x0 = (int)floorf(cx - rad - 1), x1 = (int)ceilf(cx + rad + 1);
    int y0 = (int)floorf(cy - rad - 1), y1 = (int)ceilf(cy + rad + 1);
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
            float cov = arc_cov(x + 0.5f, y + 0.5f, cx, cy, rad);
            if (cov > 0) rfb_blend_px(s, x, y, b, g, r, (int)(cov * a + 0.5f));
        }
}

/* Anti-aliased line, thickness ~1.5 px (window-button glyphs). */
static void aa_line(rfb_server *s, float x0, float y0, float x1, float y1,
                    uint8_t b, uint8_t g, uint8_t r, int a) {
    float vx = x1 - x0, vy = y1 - y0, len2 = vx*vx + vy*vy;
    int bx0 = (int)floorf(fminf(x0, x1) - 2), bx1 = (int)ceilf(fmaxf(x0, x1) + 2);
    int by0 = (int)floorf(fminf(y0, y1) - 2), by1 = (int)ceilf(fmaxf(y0, y1) + 2);
    for (int y = by0; y <= by1; y++)
        for (int x = bx0; x <= bx1; x++) {
            float px = x + 0.5f - x0, py = y + 0.5f - y0;
            float t = len2 > 0 ? (px*vx + py*vy) / len2 : 0;
            t = clamp01(t);
            float dx = px - t*vx, dy = py - t*vy;
            float cov = clamp01(1.25f - sqrtf(dx*dx + dy*dy));
            if (cov > 0) rfb_blend_px(s, x, y, b, g, r, (int)(cov * a + 0.5f));
        }
}

/* ── UI labels (librfb_font.h) ────────────────────────────────────────────── */
static int uif_index(unsigned char c) {
    return (c >= UIF_FIRST && c <= UIF_LAST) ? c - UIF_FIRST : '?' - UIF_FIRST;
}
static int uif_adv16(const char *txt, int n) {
    int a = 0;
    for (int i = 0; i < n && txt[i]; i++)
        a += UIF_GLYPHS[uif_index((unsigned char)txt[i])].adv16;
    return a;
}
int rfb_label_width(const char *txt) {
    return (uif_adv16(txt, (int)strlen(txt)) + 15) / 16;
}
static void uif_glyph(rfb_server *s, int px, int base, int gi,
                      uint8_t b, uint8_t g, uint8_t r) {
    const uint8_t *bits = UIF_BITS + UIF_GLYPHS[gi].off;
    int gx = px + UIF_GLYPHS[gi].x, gy = base + UIF_GLYPHS[gi].y;
    for (int j = 0; j < UIF_GLYPHS[gi].h; j++)
        for (int i = 0; i < UIF_GLYPHS[gi].w; i++)
            rfb_blend_px(s, gx + i, gy + j, b, g, r, bits[j * UIF_GLYPHS[gi].w + i]);
}
int rfb_draw_label(rfb_server *s, int x, int cy, int maxw, const char *txt,
                   uint8_t b, uint8_t g, uint8_t r) {
    /* centre the cap height (~10 px at 13 px) on cy */
    int base = cy + 5;
    int n = (int)strlen(txt);
    int full = (uif_adv16(txt, n) + 15) / 16;
    int ell = 0;
    if (maxw > 0 && full > maxw) {
        /* shorten until text + "..." fits */
        int dots = 3 * UIF_GLYPHS['.' - UIF_FIRST].adv16;
        while (n > 0 && (uif_adv16(txt, n) + dots + 15) / 16 > maxw) n--;
        ell = 1;
    }
    int pen = x * 16;
    for (int i = 0; i < n; i++) {
        int gi = uif_index((unsigned char)txt[i]);
        uif_glyph(s, pen / 16, base, gi, b, g, r);
        pen += UIF_GLYPHS[gi].adv16;
    }
    if (ell)
        for (int k = 0; k < 3; k++) {
            int gi = '.' - UIF_FIRST;
            uif_glyph(s, pen / 16, base, gi, b, g, r);
            pen += UIF_GLYPHS[gi].adv16;
        }
    return (pen + 15) / 16 - x;
}

/* ── 5×5 pixel font, 2× scale, 12 px/char advance ────────────────────────── */
/* Each glyph: 5 rows of 5 bits (bit4 = leftmost column). */
static const uint8_t FONT[128][5] = {
    [' '] = {0x00,0x00,0x00,0x00,0x00},
    [':'] = {0x00,0x04,0x00,0x04,0x00},
    ['-'] = {0x00,0x00,0x0E,0x00,0x00},
    ['.'] = {0x00,0x00,0x00,0x00,0x04},
    ['/'] = {0x01,0x02,0x04,0x08,0x10},
    ['+'] = {0x00,0x04,0x0E,0x04,0x00},
    ['0'] = {0x0E,0x13,0x15,0x19,0x0E},
    ['1'] = {0x04,0x0C,0x04,0x04,0x0E},
    ['2'] = {0x1E,0x01,0x0E,0x10,0x1F},
    ['3'] = {0x1E,0x01,0x06,0x01,0x1E},
    ['4'] = {0x11,0x11,0x1F,0x01,0x01},
    ['5'] = {0x1F,0x10,0x1E,0x01,0x1E},
    ['6'] = {0x0E,0x10,0x1E,0x11,0x0E},
    ['7'] = {0x1F,0x01,0x02,0x04,0x04},
    ['8'] = {0x0E,0x11,0x0E,0x11,0x0E},
    ['9'] = {0x0E,0x11,0x0F,0x01,0x0E},
    ['a'] = {0x0E,0x01,0x0F,0x11,0x0F},
    ['b'] = {0x10,0x1E,0x11,0x11,0x1E},
    ['c'] = {0x0F,0x10,0x10,0x10,0x0F},
    ['d'] = {0x01,0x0F,0x11,0x11,0x0F},
    ['e'] = {0x0E,0x11,0x1F,0x10,0x0E},
    ['f'] = {0x06,0x08,0x1C,0x08,0x08},
    ['g'] = {0x0F,0x10,0x13,0x11,0x0F},
    ['h'] = {0x10,0x10,0x1E,0x11,0x11},
    ['i'] = {0x04,0x00,0x04,0x04,0x04},
    ['j'] = {0x02,0x00,0x02,0x12,0x0C},
    ['k'] = {0x11,0x12,0x1C,0x12,0x11},
    ['l'] = {0x08,0x08,0x08,0x08,0x06},
    ['m'] = {0x11,0x1B,0x15,0x11,0x11},
    ['n'] = {0x11,0x19,0x15,0x13,0x11},
    ['o'] = {0x0E,0x11,0x11,0x11,0x0E},
    ['p'] = {0x1E,0x11,0x1E,0x10,0x10},
    ['q'] = {0x0F,0x11,0x0F,0x01,0x01},
    ['r'] = {0x1E,0x11,0x1E,0x14,0x12},
    ['s'] = {0x0F,0x10,0x0E,0x01,0x1E},
    ['t'] = {0x08,0x1C,0x08,0x08,0x06},
    ['u'] = {0x11,0x11,0x11,0x11,0x0F},
    ['v'] = {0x11,0x11,0x11,0x0A,0x04},
    ['w'] = {0x11,0x11,0x15,0x1B,0x11},
    ['x'] = {0x11,0x0A,0x04,0x0A,0x11},
    ['y'] = {0x11,0x0A,0x04,0x04,0x04},
    ['z'] = {0x1F,0x02,0x04,0x08,0x1F},
};
void rfb_draw_text(rfb_server *s, int x, int y, const char *txt,
                   uint8_t b, uint8_t g, uint8_t r) {
    for (; *txt; txt++, x += 12) {
        unsigned ci = (unsigned char)*txt;
        /* the chrome font is lowercase-only: capitals would draw blank
         * ("Wolfenstein 3D Shareware" came out "olfenstein 3 hareware") */
        if (ci >= 'A' && ci <= 'Z') ci += 'a' - 'A';
        const uint8_t *gl = FONT[ci < 128 ? ci : 0];
        for (int row=0; row<5; row++)
            for (int col=0; col<5; col++)
                if (gl[row] & (0x10u >> col)) {
                    put_px(s, x+col*2,   y+row*2,   b, g, r);
                    put_px(s, x+col*2+1, y+row*2,   b, g, r);
                    put_px(s, x+col*2,   y+row*2+1, b, g, r);
                    put_px(s, x+col*2+1, y+row*2+1, b, g, r);
                }
    }
}

/* ── window-frame chrome ──────────────────────────────────────────────────── */
int rfb_winframe_cx(const rfb_winframe *wf) { return wf->x + RFB_BORDER; }
int rfb_winframe_cy(const rfb_winframe *wf) { return wf->y + RFB_TITLE_H; }

void rfb_draw_desktop(rfb_server *s) {
    rfb_fill_rect(s, 0, 0, s->w, s->h, 0x3A,0x38,0x36);
}

/* Theme (dark). Colours are b,g,r like every librfb call. */
#define FR_RADIUS   9
#define FR_SHADOW   14     /* shadow reach in px */
#define BTN_R       6.0f   /* window-button radius */
#define BTN_STEP    20     /* centre-to-centre */
#define BTN_X0      (RFB_BORDER + 16)

static int btn_cx(const rfb_winframe *wf, int i) { return wf->x + BTN_X0 + i * BTN_STEP; }
static int btn_cy(const rfb_winframe *wf)        { return wf->y + RFB_TITLE_H / 2; }

/* Soft shadow: darken by distance from the (slightly lowered) frame rect.
 * Only the strips outside the frame are visited — the frame covers the
 * rest. Each column of a side strip has one alpha, so over the banded
 * desktop it compresses into a handful of tall RRE subrects. */
static void draw_shadow(rfb_server *s, int x, int y, int fw, int fh, int strength) {
    const int S = FR_SHADOW, off = 4;
    int rx0 = x, ry0 = y + off, rx1 = x + fw, ry1 = y + fh + off;   /* half-open */
    for (int py = ry0 - S; py < ry1 + S; py++) {
        int inside_y = (py >= y && py < y + fh);
        for (int px = rx0 - S; px < rx1 + S; px++) {
            /* skip the frame body except its rounded top corners */
            if (inside_y && px >= x && px < x + fw &&
                !(py < y + FR_RADIUS && (px < x + FR_RADIUS || px >= x + fw - FR_RADIUS))) {
                px = x + fw - 1;
                continue;
            }
            int dx = px < rx0 ? rx0 - px : px >= rx1 ? px - rx1 + 1 : 0;
            int dy = py < ry0 ? ry0 - py : py >= ry1 ? py - ry1 + 1 : 0;
            float d = sqrtf((float)(dx*dx + dy*dy));
            if (d >= S) continue;
            float t = 1.0f - d / S;
            rfb_blend_px(s, px, py, 0, 0, 0, (int)(strength * t * t + 0.5f));
        }
    }
}

void rfb_drop_shadow(rfb_server *s, int x, int y, int w, int h, int strength) {
    draw_shadow(s, x, y, w, h, strength);
}

void rfb_draw_winframe(rfb_server *s, const rfb_winframe *wf) {
    int fw = wf->w + 2*RFB_BORDER;
    int fh = RFB_TITLE_H + wf->h + RFB_BORDER;
    int dim = wf->inactive;
    int rad = wf->square ? 0 : FR_RADIUS;
    int x = wf->x, y = wf->y;

    if (!wf->square) draw_shadow(s, x, y, fw, fh, dim ? 70 : 120);

    /* outline + title bar; the top corners are rounded with AA coverage */
    const uint8_t ol[3]  = {0x10, 0x0F, 0x0D};                  /* outline   */
    const uint8_t tb[3]  = {dim ? 0x27 : 0x33, dim ? 0x25 : 0x30, dim ? 0x23 : 0x2D};
    const uint8_t hl[3]  = {0x48, 0x45, 0x42};                  /* top shine */
    for (int j = 0; j < RFB_TITLE_H; j++) {
        for (int i = 0; i < fw; i++) {
            int corner = rad && j < rad && (i < rad || i >= fw - rad);
            float co = 1.0f, ci = 1.0f;
            if (corner) {
                float ccx = i < rad ? rad : fw - rad;
                co = arc_cov(i + 0.5f, j + 0.5f, ccx, (float)rad, (float)rad);
                ci = arc_cov(i + 0.5f, j + 0.5f, ccx, (float)rad, (float)rad - 1.0f);
            } else if (i == 0 || i == fw - 1 || j == 0) {
                ci = 0.0f;
            }
            if (co <= 0) continue;
            /* inner colour: title fill, with a 1 px shine under the top edge */
            const uint8_t *in = (j == 1 && !dim && !corner) ? hl : tb;
            if (j == RFB_TITLE_H - 1) in = ol;                      /* separator */
            float a_in = ci, a_ol = co - ci;
            uint8_t cb = (uint8_t)(in[0]*a_in + ol[0]*a_ol) , cg = (uint8_t)(in[1]*a_in + ol[1]*a_ol);
            uint8_t cr = (uint8_t)(in[2]*a_in + ol[2]*a_ol);
            if (co >= 1.0f) {
                rfb_blend_px(s, x+i, y+j, cb, cg, cr, 255);
            } else {
                /* premultiplied over: dst = c + dst*(1-co) */
                int px = x+i, py = y+j;
                if ((unsigned)px < (unsigned)s->w && (unsigned)py < (unsigned)s->h) {
                    uint8_t *p = s->fb + (py*s->w + px)*FB_BPP;
                    p[0] = (uint8_t)(cb + p[0]*(1.0f-co));
                    p[1] = (uint8_t)(cg + p[1]*(1.0f-co));
                    p[2] = (uint8_t)(cr + p[2]*(1.0f-co));
                }
            }
        }
    }
    /* side + bottom outline around the content */
    rfb_fill_rect(s, x, y + RFB_TITLE_H, RFB_BORDER, wf->h + RFB_BORDER, ol[0], ol[1], ol[2]);
    rfb_fill_rect(s, x + fw - RFB_BORDER, y + RFB_TITLE_H, RFB_BORDER, wf->h + RFB_BORDER,
                  ol[0], ol[1], ol[2]);
    rfb_fill_rect(s, x, y + fh - RFB_BORDER, fw, RFB_BORDER, ol[0], ol[1], ol[2]);

    /* window buttons: close / minimise / maximise */
    static const uint8_t BTN[3][3] = { {0x57,0x5F,0xFF}, {0x2E,0xBC,0xFE}, {0x40,0xC8,0x28} };
    int lit = !dim || wf->hover;
    int cyb = btn_cy(wf);
    for (int i = 0; i < 3; i++) {
        float cx = btn_cx(wf, i) + 0.5f, cyf = cyb + 0.5f;
        if (lit) rfb_fill_circle_aa(s, cx, cyf, BTN_R, BTN[i][0], BTN[i][1], BTN[i][2], 255);
        else     rfb_fill_circle_aa(s, cx, cyf, BTN_R, 0x55, 0x52, 0x4E, 255);
        if (!wf->hover) continue;
        const int ga = 150;                   /* dark glyphs, macOS-style */
        if (i == 0) {
            aa_line(s, cx-2.6f, cyf-2.6f, cx+2.6f, cyf+2.6f, 0x10,0x10,0x40, ga);
            aa_line(s, cx-2.6f, cyf+2.6f, cx+2.6f, cyf-2.6f, 0x10,0x10,0x40, ga);
        } else if (i == 1) {
            aa_line(s, cx-3.2f, cyf, cx+3.2f, cyf, 0x00,0x30,0x50, ga);
        } else {
            aa_line(s, cx-3.2f, cyf, cx+3.2f, cyf, 0x00,0x40,0x08, ga);
            aa_line(s, cx, cyf-3.2f, cx, cyf+3.2f, 0x00,0x40,0x08, ga);
        }
    }

    /* centred title, kept clear of the buttons */
    const char *t = wf->title ? wf->title : "";
    int left = BTN_X0 + 2*BTN_STEP + 18;          /* past the buttons */
    int avail = fw - 2*left;
    if (avail > 8) {
        int tw = rfb_label_width(t);
        if (tw > avail) tw = avail;
        int tx = x + (fw - tw) / 2;
        uint8_t c = dim ? 0x8E : 0xE4;
        rfb_draw_label(s, tx, y + RFB_TITLE_H/2 - 1, avail, t, c, (uint8_t)(c+1), (uint8_t)(c+2));
    }
}

int rfb_winframe_button_at(const rfb_winframe *wf, int x, int y) {
    int cy = btn_cy(wf);
    if (y < cy - 9 || y > cy + 9) return RFB_BTN_NONE;
    for (int i = 0; i < 3; i++) {
        int bx = btn_cx(wf, i);
        if (x >= bx - 9 && x <= bx + 9) return RFB_BTN_CLOSE + i;
    }
    return RFB_BTN_NONE;
}

int rfb_winframe_over_buttons(const rfb_winframe *wf, int x, int y) {
    int cy = btn_cy(wf);
    return y >= cy - 10 && y <= cy + 10 &&
           x >= btn_cx(wf, 0) - 10 && x <= btn_cx(wf, 2) + 10;
}

void rfb_damage_titlebar(rfb_server *s, const rfb_winframe *wf) {
    rfb_damage(s, wf->x, wf->y, wf->w + 2*RFB_BORDER, RFB_TITLE_H);
}

int rfb_winframe_pointer(rfb_server *s, rfb_winframe *wf,
                         int buttons, int x, int y) {
    int fw = wf->w + 2*RFB_BORDER;
    int fh = RFB_TITLE_H + wf->h + RFB_BORDER;
    int moved = 0;
    if (buttons & 1) {
        if (!wf->dragging &&
            x >= wf->x && x < wf->x+fw &&
            y >= wf->y && y < wf->y+RFB_TITLE_H) {
            wf->dragging = 1;
            wf->drag_ox  = x - wf->x;
            wf->drag_oy  = y - wf->y;
        }
        if (wf->dragging) {
            int nx = x - wf->drag_ox;
            int ny = y - wf->drag_oy;
            if (nx < 0)          nx = 0;
            if (ny < 0)          ny = 0;
            if (nx+fw > s->w)    nx = s->w-fw;
            if (ny+fh > s->h)    ny = s->h-fh;
            if (nx != wf->x || ny != wf->y) {
                wf->x = nx; wf->y = ny;
                moved = 1;
            }
        }
    } else {
        wf->dragging = 0;
    }
    return moved;
}

/* ── RFB send path ────────────────────────────────────────────────────────── */

/* RRE-encode (RFC 6143 §7.7.3) the fb rect: u32 nSubrects, bg pixel, then
 * per subrect pixel + x,y,w,h (u16, rect-relative). Flat-colored scenes
 * shrink ~40×: the 1.2 MB full frame and 234 KB eye boxes were exactly the
 * bulk transfers that tripped the guest's ~700 KB TCP-stall cliff (see
 * wire-helpers comment). Runs are found per row, and a run identical to one
 * directly above it (same x, width, colour) grows that subrect downward
 * instead of starting a new one — window borders, shadow columns and the
 * banded desktop then cost one subrect per band, not one per row.
 * Returns malloc'd buffer size, or 0 when raw would be smaller (caller then
 * sends raw). */
typedef struct { uint16_t x, w; uint32_t px; uint32_t idx; } rre_run;

static size_t encode_rre(rfb_server *s, int x, int y, int w, int h,
                         uint8_t **out) {
    size_t cap = 8192, len = 8;   /* 8 = nSubrects + bg slot */
    size_t raw = (size_t)w * h * FB_BPP;
    uint8_t *buf = malloc(cap);
    rre_run *prev = malloc(sizeof(rre_run) * (size_t)(w + 1));
    rre_run *cur  = malloc(sizeof(rre_run) * (size_t)(w + 1));
    if (!buf || !prev || !cur) { free(buf); free(prev); free(cur); return 0; }
    int nprev = 0;
    uint32_t bg, nsub = 0;
    memcpy(&bg, s->fb + (y*s->w + x)*FB_BPP, 4);   /* bg = first pixel */
    for (int row = 0; row < h; row++) {
        const uint8_t *rp = s->fb + ((y+row)*s->w + x)*FB_BPP;
        int col = 0, ncur = 0, pi = 0;
        while (col < w) {
            uint32_t px;
            memcpy(&px, rp + (size_t)col*4, 4);
            int run = 1;
            while (col + run < w) {
                uint32_t q;
                memcpy(&q, rp + (size_t)(col+run)*4, 4);
                if (q != px) break;
                run++;
            }
            if (px != bg) {
                /* the previous row's runs are sorted by x: advance to ours */
                while (pi < nprev && prev[pi].x < col) pi++;
                if (pi < nprev && prev[pi].x == col && prev[pi].w == run &&
                    prev[pi].px == px) {
                    /* extend the subrect above us by one row */
                    uint8_t *sr = buf + 8 + (size_t)prev[pi].idx * 12;
                    uint16_t sh;
                    memcpy(&sh, sr + 10, 2);
                    sh = htons((uint16_t)(ntohs(sh) + 1));
                    memcpy(sr + 10, &sh, 2);
                    cur[ncur++] = prev[pi];
                } else {
                    /* Past raw size RRE has already lost (textured content:
                     * a game frame is mostly 1-pixel runs) — stop now
                     * instead of growing a buffer we will throw away. */
                    if (len + 12 >= raw) goto lost;
                    if (len + 12 > cap) {
                        cap *= 2;
                        uint8_t *nb = realloc(buf, cap);
                        if (!nb) goto lost;
                        buf = nb;
                    }
                    uint16_t sx = htons((uint16_t)col), sy = htons((uint16_t)row);
                    uint16_t sw = htons((uint16_t)run), sh = htons(1);
                    memcpy(buf+len,    &px, 4);
                    memcpy(buf+len+4,  &sx, 2);
                    memcpy(buf+len+6,  &sy, 2);
                    memcpy(buf+len+8,  &sw, 2);
                    memcpy(buf+len+10, &sh, 2);
                    cur[ncur].x = (uint16_t)col; cur[ncur].w = (uint16_t)run;
                    cur[ncur].px = px; cur[ncur].idx = nsub;
                    ncur++;
                    len += 12; nsub++;
                }
            }
            col += run;
        }
        rre_run *t = prev; prev = cur; cur = t;
        nprev = ncur;
    }
    free(prev); free(cur);
    if (len >= raw) { free(buf); return 0; }
    uint32_t n_be = htonl(nsub);
    memcpy(buf,   &n_be, 4);
    memcpy(buf+4, &bg,   4);
    *out = buf;
    return len;
lost:
    free(buf); free(prev); free(cur);
    return 0;
}

static void send_rect_hdr(rfb_server *s, int x, int y, int w, int h,
                          uint32_t enc) {
    uint8_t rect[12];
    uint16_t rx=htons((uint16_t)x), ry=htons((uint16_t)y);
    uint16_t rw=htons((uint16_t)w), rh=htons((uint16_t)h);
    uint32_t re=htonl(enc);
    memcpy(rect+0,&rx,2); memcpy(rect+2,&ry,2);
    memcpy(rect+4,&rw,2); memcpy(rect+6,&rh,2);
    memcpy(rect+8,&re,4);
    write_all(s, rect, 12);
}

static void send_raw_rect(rfb_server *s, int x, int y, int w, int h) {
    send_rect_hdr(s, x, y, w, h, 0);  /* encoding 0 = Raw */
    /* Coalesce all rows into one write_all() call.  Row-by-row writes
     * never fill the TCP send buffer, so the kernel's asyncify yield
     * never fires and the JS event loop — which delivers input events —
     * never gets control. */
    size_t sz = (size_t)w * h * FB_BPP;
    uint8_t *buf = malloc(sz);
    if (!buf) return;
    for (int dy = 0; dy < h; dy++)
        memcpy(buf + (size_t)dy*w*FB_BPP,
               s->fb + ((y+dy)*s->w + x)*FB_BPP, (size_t)w*FB_BPP);
    write_all(s, buf, sz);
    free(buf);
}

/* Preferred rect sender: RRE when it compresses, raw otherwise. */
static void send_rect(rfb_server *s, int x, int y, int w, int h) {
    uint8_t *rre = NULL;
    size_t sz = encode_rre(s, x, y, w, h, &rre);
    if (sz) {
        send_rect_hdr(s, x, y, w, h, 2);  /* encoding 2 = RRE */
        write_all(s, rre, sz);
        free(rre);
    } else {
        send_raw_rect(s, x, y, w, h);
    }
}

static void send_fbu_hdr(rfb_server *s, int nrect) {
    if (s->eds_pending) nrect++;
    uint8_t hdr[4] = {0, 0, (uint8_t)(nrect >> 8), (uint8_t)nrect};
    write_all(s, hdr, 4);
    if (!s->eds_pending) return;
    /* ExtendedDesktopSize pseudo-rect: x = reason, y = status, w/h = the
     * framebuffer size, then one screen covering all of it. */
    s->eds_pending = 0;
    send_rect_hdr(s, s->eds_reason, s->eds_status, s->w, s->h, (uint32_t)-308);
    uint8_t body[20];
    memset(body, 0, sizeof body);
    body[0] = 1;                                  /* number of screens */
    uint16_t sw = htons((uint16_t)s->w), sh = htons((uint16_t)s->h);
    memcpy(body + 12, &sw, 2);                    /* id 0, x 0, y 0 */
    memcpy(body + 14, &sh, 2);
    write_all(s, body, sizeof body);
}

static void send_fbu_full(rfb_server *s) {
    /* Horizontal bands so the client can paint progressively even if the
     * transport stalls mid-frame. */
    const int band_h = 40;
    const int nrect = (s->h + band_h - 1) / band_h;
    send_fbu_hdr(s, nrect);
    for (int y = 0; y < s->h; y += band_h) {
        int h = band_h;
        if (y + h > s->h) h = s->h - y;
        send_rect(s, 0, y, s->w, h);
    }
}

/* ── RFB 3.8 protocol ─────────────────────────────────────────────────────── */

/* Pixel format: 32bpp BGRA LE — red-shift=16, green=8, blue=0 */
static const uint8_t SERVER_PF[16] = {
    32, 24, 0, 1,
    0, 255,  /* red-max   */
    0, 255,  /* green-max */
    0, 255,  /* blue-max  */
    16, 8, 0,
    0, 0, 0
};

static void serve_client(rfb_server *s) {
    int cfd = s->cfd;

    /* ── handshake ── */
    write_all(s, "RFB 003.008\n", 12);
    char ver[12]; if (!read_all(s, ver, 12)) return;

    uint8_t sec[2] = {1, 1}; write_all(s, sec, 2);
    uint8_t chosen; if (!read_all(s, &chosen, 1)) return;
    if (chosen != 1) { fprintf(stderr, "[rfb] bad auth %u\n", chosen); return; }

    uint8_t ok[4] = {0}; write_all(s, ok, 4);
    uint8_t shared; if (!read_all(s, &shared, 1)) return;

    const char *name = s->cfg.name ? s->cfg.name : "librfb";
    uint8_t sinit[24];
    sinit[0]=(s->w>>8)&0xff; sinit[1]=s->w&0xff;
    sinit[2]=(s->h>>8)&0xff; sinit[3]=s->h&0xff;
    memcpy(sinit+4, SERVER_PF, 16);
    uint32_t nlen = htonl((uint32_t)strlen(name));
    memcpy(sinit+20, &nlen, 4);
    write_all(s, sinit, 24);
    write_all(s, name, strlen(name));

    rfb_damage_full(s);
    s->cursor = -1;      /* new viewer: next rfb_set_cursor really sends */
    s->eds_ok = 0;       /* re-announced if this viewer supports it */
    s->eds_pending = 0;
    if (s->cfg.on_connect) s->cfg.on_connect(s);

    s->saw_fbreq = 0;

    /* ── message loop ── */
    for (;;) {
        uint8_t mtype;
        if (!read_all(s, &mtype, 1)) break;
        if (s->cfg.on_idle) s->cfg.on_idle(s);

        switch (mtype) {
        case 0: { /* SetPixelFormat */
            uint8_t buf[19]; if (!read_all(s, buf, 19)) return;
            break;
        }
        case 2: { /* SetEncodings */
            uint8_t h3[3]; if (!read_all(s, h3, 3)) return;
            uint16_t cnt; memcpy(&cnt, h3+1, 2); cnt = ntohs(cnt);
            for (int i=0; i<cnt; i++) {
                uint8_t e4[4]; if (!read_all(s, e4, 4)) return;
                int32_t enc; memcpy(&enc, e4, 4); enc = (int32_t)ntohl((uint32_t)enc);
                /* -308 ExtendedDesktopSize: announce the current size once
                 * (reason 0); that is the viewer's cue that SetDesktopSize
                 * is understood here. Only for apps that can resize — and
                 * never revoked: the Bell nudge answer is an empty list. */
                if (enc == -308 && s->cfg.on_resize && !s->eds_ok) {
                    s->eds_ok = 1;
                    s->eds_pending = 1;
                    s->eds_reason = 0; s->eds_status = 0;
                }
            }
            break;
        }
        case 3: { /* FramebufferUpdateRequest */
            uint8_t req[9]; if (!read_all(s, req, 9)) return;
            uint8_t incr = req[0];
            s->saw_fbreq = 1;
            /* Repaint (and let the app advance animation + declare damage),
             * then send only what changed. */
            if (s->cfg.render) s->cfg.render(s);
            int sent = 1;
            if (!incr || s->full) {
                send_fbu_full(s);
                s->full = 0;
                s->nrects = 0;
            } else if (s->nrects > 0) {
                send_fbu_hdr(s, s->nrects);
                for (int i = 0; i < s->nrects; i++)
                    send_rect(s, s->rects[i].x, s->rects[i].y,
                              s->rects[i].w, s->rects[i].h);
                s->nrects = 0;
            } else {
                /* Nothing changed — legal empty update (or just the size
                 * announcement); the client's msg-done loop re-requests,
                 * so this sets the idle poll. */
                sent = s->eds_pending;
                send_fbu_hdr(s, 0);
            }
            /* Pacing + yield. The client re-requests the instant a response
             * completes (message-driven, immune to browser timer
             * throttling), so the server sets the loop rate: sleep longer
             * when nothing changed, just yield when something did. The
             * sleep doubles as the asyncify yield that lets queued input
             * events be delivered. */
            usleep(sent ? 1000 : 30000);
            break;
        }
        case 4: { /* KeyEvent */
            uint8_t buf[7]; if (!read_all(s, buf, 7)) return;
            if (s->cfg.on_key) {
                uint32_t ks; memcpy(&ks, buf+3, 4); ks = ntohl(ks);
                s->cfg.on_key(s, ks, buf[0]);
            }
            break;
        }
        case 5: { /* PointerEvent */
            uint8_t buf[5]; if (!read_all(s, buf, 5)) return;
            if (s->cfg.on_pointer) {
                uint16_t mx, my;
                memcpy(&mx, buf+1, 2); mx = ntohs(mx);
                memcpy(&my, buf+3, 2); my = ntohs(my);
                s->cfg.on_pointer(s, buf[0], (int)mx, (int)my);
            }
            break;
        }
        case 6: { /* ClientCutText */
            uint8_t buf[7]; if (!read_all(s, buf, 7)) return;
            uint32_t len; memcpy(&len, buf+3, 4); len = ntohl(len);
            while (len) {
                uint8_t drain[256];
                uint32_t ch = len < 256 ? len : 256;
                if (!read_all(s, drain, ch)) return;
                len -= ch;
            }
            break;
        }
        case 251: { /* SetDesktopSize (ExtendedDesktopSize extension) */
            uint8_t hd[7]; if (!read_all(s, hd, 7)) return;
            int nw = (hd[1] << 8) | hd[2], nh = (hd[3] << 8) | hd[4];
            for (int i = 0; i < hd[5]; i++) {       /* screen layout: unused */
                uint8_t scr[16]; if (!read_all(s, scr, 16)) return;
            }
            int status = 1;                         /* 1 = prohibited */
            if (s->cfg.on_resize && nw > 0 && nh > 0 &&
                s->cfg.on_resize(s, &nw, &nh) && nw > 0 && nh > 0) {
                status = 0;
                if (nw != s->w || nh != s->h) {
                    uint8_t *nfb = calloc((size_t)nw * nh, FB_BPP);
                    if (nfb) {
                        free(s->fb);
                        s->fb = nfb; s->w = nw; s->h = nh;
                    } else {
                        status = 2;                 /* out of resources */
                    }
                }
                rfb_damage_full(s);
            }
            s->eds_pending = 1;
            s->eds_reason = 1;                      /* answer to this client */
            s->eds_status = status;
            printf("[rfb] desktop size %dx%d (status %d)\n", s->w, s->h, status);
            fflush(stdout);
            break;
        }
        default:
            fprintf(stderr, "[rfb] unknown msg %u\n", mtype);
            return;
        }
    }
}

int rfb_run(const rfb_config *cfg) {
    rfb_server s = {0};
    s.cfg = *cfg;
    s.w = cfg->w; s.h = cfg->h;
    s.fb = malloc((size_t)s.w * s.h * FB_BPP);
    if (!s.fb) { perror("malloc"); return 1; }
    memset(s.fb, 0, (size_t)s.w * s.h * FB_BPP);

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons((uint16_t)cfg->port);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    if (listen(lfd, 1) < 0) { perror("listen"); return 1; }

    printf("[rfb] %s listening on :%d\n",
           cfg->name ? cfg->name : "librfb", cfg->port);
    fflush(stdout);

    /* Nonblocking accept + usleep poll — see the wire-helpers comment. A
     * blocking accept() here parks the guest so hard that the client's SYN
     * retries all expire before anything wakes it up. */
    set_nonblock(lfd);
    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (s.cfg.on_idle) s.cfg.on_idle(&s);
                usleep(s.cfg.on_idle ? 5000 : 50000);  /* keep app sockets live */
                continue;
            }
            if (errno == EINTR) continue;
            perror("accept"); break;
        }
        set_nonblock(cfd);  /* accepted fd does not inherit O_NONBLOCK */
        /* Big buffers cut the loss rate at its source: the transport drops
         * injected client segments when the socket backlog overflows while
         * the server is mid-write (backlog ceiling scales with rcvbuf+sndbuf). */
        int bufsz = 256 * 1024;
        setsockopt(cfd, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz));
        setsockopt(cfd, SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz));
        printf("[rfb] client connected\n"); fflush(stdout);
        s.cfd = cfd;
        serve_client(&s);
        printf("[rfb] client disconnected\n"); fflush(stdout);
        close(cfd);
        s.cfd = -1;
    }
    close(lfd);
    return 0;
}
