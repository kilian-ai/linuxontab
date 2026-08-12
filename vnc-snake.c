/*
 * vnc-snake.c — keyboard-interactive snake on librfb, for the LinuxOnTab
 * WASM kernel. First demo to exercise the KeyEvent path end-to-end
 * (browser canvas keydown → RFB KeyEvent → on_key).
 *
 * Arrows / WASD steer, p or space pauses, r restarts. Runs on :5900 like
 * the eyes demo (start one at a time; the shell's X display connects
 * there). Time-driven animation happens in render(): the client's
 * message-driven request loop calls it ~30×/s while idle, and each tick
 * damages only the few cells that changed.
 *
 * Build + install: ./build-vnc-demos.sh
 */
#include "librfb.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define FB_W 640
#define FB_H 480

#define CELL    20
#define GRID_W  22
#define GRID_H  15
#define CAP     (GRID_W * GRID_H)
#define TICK_MS 140

/* ── scene model ──────────────────────────────────────────────────────────── */
static rfb_winframe win = { .x = 96, .y = 70,
                            .w = GRID_W*CELL, .h = GRID_H*CELL,
                            .title = "snake" };

enum { READY, RUNNING, PAUSED, OVER };
static struct {
    signed char bx[CAP], by[CAP];   /* ring buffer; head at head_i */
    int head_i, len;
    int dx, dy;                     /* current direction */
    int qdx, qdy;                   /* queued direction (applied at tick) */
    int fx, fy;                     /* food cell */
    int state, score;
    uint64_t last_tick;
} g;

static int cell_x(int i) { return g.bx[(g.head_i + i) % CAP]; }
static int cell_y(int i) { return g.by[(g.head_i + i) % CAP]; }

static int on_body(int x, int y) {
    for (int i = 0; i < g.len; i++)
        if (cell_x(i) == x && cell_y(i) == y) return 1;
    return 0;
}

static void spawn_food(void) {
    do {
        g.fx = rand() % GRID_W;
        g.fy = rand() % GRID_H;
    } while (on_body(g.fx, g.fy));
}

static void reset(void) {
    g.head_i = 0; g.len = 3;
    for (int i = 0; i < 3; i++) {
        g.bx[i] = (signed char)(GRID_W/2 - i);
        g.by[i] = (signed char)(GRID_H/2);
    }
    g.dx = g.qdx = 1; g.dy = g.qdy = 0;
    g.state = READY;   /* wait for the first direction key */
    g.score = 0;
    g.last_tick = rfb_now_ms();
    spawn_food();
}

/* ── damage helpers ───────────────────────────────────────────────────────── */
static void damage_cell(rfb_server *s, int x, int y) {
    rfb_damage(s, rfb_winframe_cx(&win) + x*CELL,
               rfb_winframe_cy(&win) + y*CELL, CELL, CELL);
}
static void damage_content(rfb_server *s) {
    rfb_damage(s, rfb_winframe_cx(&win), rfb_winframe_cy(&win),
               win.w, win.h);
}
static void damage_score(rfb_server *s) {
    rfb_damage(s, win.x + RFB_BORDER + win.w - 130, win.y, 130, RFB_TITLE_H);
}

/* ── game tick ────────────────────────────────────────────────────────────── */
static void step(rfb_server *s) {
    g.dx = g.qdx; g.dy = g.qdy;
    int nx = cell_x(0) + g.dx;
    int ny = cell_y(0) + g.dy;

    if (nx < 0 || nx >= GRID_W || ny < 0 || ny >= GRID_H ||
        on_body(nx, ny) || g.len >= CAP - 1) {
        g.state = OVER;
        damage_content(s);      /* overlay text appears */
        return;
    }

    int ate = (nx == g.fx && ny == g.fy);
    damage_cell(s, cell_x(0), cell_y(0));   /* old head → body color */
    if (!ate) {
        damage_cell(s, cell_x(g.len-1), cell_y(g.len-1));  /* tail vacates */
    }

    g.head_i = (g.head_i + CAP - 1) % CAP;
    g.bx[g.head_i] = (signed char)nx;
    g.by[g.head_i] = (signed char)ny;
    if (ate) {
        g.len++; g.score++;
        spawn_food();
        damage_cell(s, g.fx, g.fy);
        damage_score(s);
    }
    damage_cell(s, nx, ny);                 /* new head */
}

/* ── callbacks ────────────────────────────────────────────────────────────── */
static void render(rfb_server *s) {
    /* Advance time-driven animation. The transport freezes for 1-2 s every
     * so often (kernel/slirp lurches); if we caught up the missed ticks in
     * a burst the snake would jump several cells with stale steering and
     * die "for free". Instead: a gap of >2 ticks means the player saw a
     * frozen frame — PAUSE game time across it (resync, step nothing) so a
     * stall never kills. Small jitter (≤2 ticks) still catches up. */
    if (g.state == RUNNING) {
        uint64_t now = rfb_now_ms();
        if (now - g.last_tick >= (uint64_t)(3*TICK_MS)) {
            g.last_tick = now;                    /* stall: freeze, don't ffwd */
        } else if (now - g.last_tick >= TICK_MS) {
            g.last_tick += TICK_MS;
            step(s);
            if (now - g.last_tick >= TICK_MS) {   /* one catch-up step max */
                g.last_tick += TICK_MS;
                step(s);
            }
        }
    }

    rfb_draw_desktop(s);
    rfb_draw_winframe(s, &win);
    int cx = rfb_winframe_cx(&win), cy = rfb_winframe_cy(&win);

    /* score, right-aligned in the title bar */
    char sc[20];
    snprintf(sc, sizeof sc, "score %d", g.score);
    rfb_draw_text(s, win.x + RFB_BORDER + win.w - 120,
                  win.y + (RFB_TITLE_H-10)/2, sc, 0xBB,0xBB,0xBB);

    /* board */
    rfb_fill_rect(s, cx, cy, win.w, win.h, 0x18,0x16,0x14);

    /* food */
    rfb_fill_rect(s, cx + g.fx*CELL + 3, cy + g.fy*CELL + 3,
                  CELL-6, CELL-6, 0x3B,0x45,0xE8);          /* red */

    /* snake: head brighter than body */
    for (int i = g.len - 1; i >= 0; i--) {
        int px = cx + cell_x(i)*CELL, py = cy + cell_y(i)*CELL;
        if (i == 0)
            rfb_fill_rect(s, px+1, py+1, CELL-2, CELL-2, 0x51,0xE8,0x7C);
        else
            rfb_fill_rect(s, px+2, py+2, CELL-4, CELL-4, 0x3F,0xB3,0x4A);
    }

    if (g.state == READY) {
        rfb_draw_text(s, cx + (win.w - 11*12)/2, cy + win.h/2 + 28,
                      "press a key", 0xE8,0xE8,0xE8);
    } else if (g.state == PAUSED) {
        rfb_draw_text(s, cx + (win.w - 6*12)/2, cy + win.h/2 - 5,
                      "paused", 0xE8,0xE8,0xE8);
    } else if (g.state == OVER) {
        rfb_draw_text(s, cx + (win.w - 9*12)/2, cy + win.h/2 - 16,
                      "game over", 0x51,0x51,0xE8);
        rfb_draw_text(s, cx + (win.w - 7*12)/2, cy + win.h/2 + 8,
                      "press r", 0xC8,0xC8,0xC8);
    }
}

static void start_if_ready(rfb_server *s) {
    if (g.state == READY) {
        g.state = RUNNING;
        g.last_tick = rfb_now_ms();
        damage_content(s);   /* remove the "press a key" overlay */
    }
}

static void on_key(rfb_server *s, uint32_t ks, int down) {
    if (!down) return;
    switch (ks) {
    case RFB_KEY_LEFT:  case 'a': if (g.dx !=  1) { g.qdx = -1; g.qdy = 0; } start_if_ready(s); break;
    case RFB_KEY_RIGHT: case 'd': if (g.dx != -1) { g.qdx =  1; g.qdy = 0; } start_if_ready(s); break;
    case RFB_KEY_UP:    case 'w': if (g.dy !=  1) { g.qdx = 0; g.qdy = -1; } start_if_ready(s); break;
    case RFB_KEY_DOWN:  case 's': if (g.dy != -1) { g.qdx = 0; g.qdy =  1; } start_if_ready(s); break;
    case 'p': case ' ':
        if (g.state == RUNNING)      g.state = PAUSED;
        else if (g.state == PAUSED) { g.state = RUNNING; g.last_tick = rfb_now_ms(); }
        damage_content(s);
        break;
    case 'r':
        reset();
        rfb_damage_full(s);   /* board + score both change */
        break;
    }
}

static void on_pointer(rfb_server *s, int buttons, int x, int y) {
    if (rfb_winframe_pointer(s, &win, buttons, x, y))
        rfb_damage_full(s);
}

static void on_connect(rfb_server *s) {
    (void)s;
    reset();   /* fresh game per session — don't play out while unattended */
}

int main(void) {
    srand((unsigned)time(NULL));
    reset();
    rfb_config cfg = {
        .name       = "LinuxOnTab snake",
        .w          = FB_W,
        .h          = FB_H,
        .port       = 5900,
        .render     = render,
        .on_key     = on_key,
        .on_pointer = on_pointer,
        .on_connect = on_connect,
    };
    return rfb_run(&cfg);
}
