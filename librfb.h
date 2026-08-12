/*
 * librfb.h — minimal RFB 3.8 display-server kit for LinuxOnTab WASM guests
 *
 * The pattern: an app owns a scene model, repaints it into a BGRA
 * framebuffer in render(), reports what changed via rfb_damage(), and
 * receives input through callbacks. The library owns everything else:
 * the RFB handshake and message loop, damage-rect delivery with RRE
 * compression, request pacing, and the nonblocking-I/O discipline the
 * WASM kernel needs (see librfb.c wire-helpers comment).
 *
 * The browser side (shell/wasm.html "X display" panel) is a generic RFB
 * client — anything built on this library appears there unmodified.
 *
 * Apps: vnc-server.c (pointer-tracking eyes), vnc-snake.c (keyboard demo).
 * Build: ./build-vnc-demos.sh
 */
#ifndef LIBRFB_H
#define LIBRFB_H

#include <stdint.h>

typedef struct rfb_server rfb_server;

typedef struct rfb_config {
    const char *name;   /* desktop name sent in ServerInit */
    int w, h;           /* framebuffer size */
    int port;           /* TCP listen port (the shell connects to 5900) */

    /* Repaint the whole scene into rfb_fb(s). Called before every update
     * is sent — this is also where time-driven animation advances (use
     * rfb_now_ms() and call rfb_damage() for cells that changed). Only
     * damaged regions are transmitted, so a full repaint is cheap. */
    void (*render)(rfb_server *s);

    /* Input callbacks; either may be NULL. */
    void (*on_pointer)(rfb_server *s, int buttons, int x, int y);
    void (*on_key)(rfb_server *s, uint32_t keysym, int down);

    /* Called after each client handshake, before the first update — reset
     * per-session state here (e.g. restart a game). May be NULL. */
    void (*on_connect)(rfb_server *s);

    /* Called continuously (~every 5 ms while idle/stalled, and after every
     * protocol message) whether or not an RFB client is attached. Poll your
     * own sockets/timers here — this is how a server app (e.g. the tiny X
     * server) multiplexes its own clients into the single-threaded loop.
     * May be NULL. */
    void (*on_idle)(rfb_server *s);

    void *user;         /* app state, reachable via rfb_user() */
} rfb_config;

/* ── accessors ── */
uint8_t *rfb_fb(rfb_server *s);
int      rfb_w(rfb_server *s);
int      rfb_h(rfb_server *s);
void    *rfb_user(rfb_server *s);

/* ── damage: mark regions changed since the last update ── */
void rfb_damage(rfb_server *s, int x, int y, int w, int h);
void rfb_damage_full(rfb_server *s);

/* ── drawing primitives (BGRA fb; colors passed as b,g,r bytes) ── */
void rfb_fill_rect(rfb_server *s, int x, int y, int w, int h,
                   uint8_t b, uint8_t g, uint8_t r);
void rfb_fill_circle(rfb_server *s, int cx, int cy, int rad,
                     uint8_t b, uint8_t g, uint8_t r);
/* 5×5 bitmap font at 2× scale, 12 px advance; covers a-z subset + 0-9
 * (unknown glyphs render blank). 10 px tall. */
void rfb_draw_text(rfb_server *s, int x, int y, const char *txt,
                   uint8_t b, uint8_t g, uint8_t r);

/* ── draggable window-frame chrome (shared demo desktop) ── */
#define RFB_TITLE_H 28
#define RFB_BORDER   2

typedef struct rfb_winframe {
    int x, y;           /* frame top-left on the desktop */
    int w, h;           /* CONTENT area size (frame adds border + title) */
    const char *title;
    int dragging, drag_ox, drag_oy;
    int inactive;       /* 1 = dim the chrome (window lacks focus) */
} rfb_winframe;

void rfb_draw_desktop(rfb_server *s);
void rfb_draw_winframe(rfb_server *s, const rfb_winframe *wf);
/* Which title-bar button is under the point, if any. Keeps the button
 * geometry in one place instead of duplicating it in every app. */
enum { RFB_BTN_NONE = 0, RFB_BTN_CLOSE, RFB_BTN_MIN, RFB_BTN_MAX };
int  rfb_winframe_button_at(const rfb_winframe *wf, int x, int y);
/* Content-area origin. */
int  rfb_winframe_cx(const rfb_winframe *wf);
int  rfb_winframe_cy(const rfb_winframe *wf);
/* Title-bar dragging. Returns 1 if the window moved (the caller should
 * treat the whole frame as damaged — rfb_damage_full is simplest). */
int  rfb_winframe_pointer(rfb_server *s, rfb_winframe *wf,
                          int buttons, int x, int y);

/* ── keysyms (X11 values, as sent by the browser client) ── */
#define RFB_KEY_LEFT  0xff51
#define RFB_KEY_UP    0xff52
#define RFB_KEY_RIGHT 0xff53
#define RFB_KEY_DOWN  0xff54

/* Monotonic milliseconds, for animation in render(). */
uint64_t rfb_now_ms(void);

/* ── pointer shape ────────────────────────────────────────────────────────
 * The viewer's own cursor is switched to a named shape, rather than the
 * server painting a cursor into the framebuffer. That keeps the pointer
 * crisp and — because the browser draws it locally — perfectly responsive
 * even while the transport is stalled, which a server-drawn cursor could
 * never be. Sent as an RFB ServerCutText carrying a "\x01rfb-cursor:NAME"
 * payload: a real client treats it as a clipboard update and ignores the
 * unknown marker, while ours maps NAME onto a CSS cursor keyword. */
enum {
    RFB_CUR_DEFAULT = 0,   /* arrow          */
    RFB_CUR_TEXT,          /* I-beam         */
    RFB_CUR_POINTER,       /* hand           */
    RFB_CUR_CROSSHAIR,
    RFB_CUR_WAIT,
    RFB_CUR_MOVE,
    RFB_CUR_NS_RESIZE,
    RFB_CUR_EW_RESIZE,
    RFB_CUR_NWSE_RESIZE,
    RFB_CUR_NESW_RESIZE,
    RFB_CUR__COUNT
};
/* Idempotent: repeats of the current shape cost nothing. */
void rfb_set_cursor(rfb_server *s, int shape);

/* Serve forever (accept loop; one client at a time). Returns on fatal
 * socket errors only. */
int rfb_run(const rfb_config *cfg);

#endif /* LIBRFB_H */
