/*
 * vnc-server.c — xeyes demo on librfb, for the LinuxOnTab WASM kernel
 *
 * Desktop with one draggable window; eyes inside track the pointer.
 * 640×480, port 5900, no auth. All protocol/transport machinery lives in
 * librfb.c — this file is just the scene: a model (window position +
 * mouse), a render() that repaints it, and damage declarations for what
 * moved.
 *
 * Build + install: ./build-vnc-demos.sh
 */
#include "librfb.h"

#include <stdlib.h>

#define FB_W 640
#define FB_H 480

/* ── eye geometry ─────────────────────────────────────────────────────────── */
#define WIN_W   460
#define WIN_H   340
#define EYE_R       78
#define EYE_RING     4
#define PUPIL_R     24
#define PUPIL_GAP    6
#define SHINE_R      7
#define EYE_MARGIN  (EYE_R + EYE_RING + 4)

/* ── scene model ──────────────────────────────────────────────────────────── */
static rfb_winframe win = { .x = 88, .y = 50, .w = WIN_W, .h = WIN_H,
                            .title = "xeyes" };
static int mouse_x = FB_W/2, mouse_y = FB_H/2;
/* Pupil position most recently covered by a damage rect, per eye. */
static int dmg_px[2], dmg_py[2];
static int dmg_valid = 0;

static void eye_center(int e, int *cx, int *cy) {
    *cx = rfb_winframe_cx(&win) + WIN_W*(e+1)/3;
    *cy = rfb_winframe_cy(&win) + WIN_H/2;
}

/* Classic xeyes math: pupil rides the cursor direction, clamped inside. */
static void pupil_pos(int e, int *px, int *py) {
    int cx, cy;
    eye_center(e, &cx, &cy);
    float dx = (float)(mouse_x - cx);
    float dy = (float)(mouse_y - cy);
    float dist = dx*dx + dy*dy;
    float max_d = (float)(EYE_R - PUPIL_R - PUPIL_GAP);
    if (dist > max_d*max_d && dist > 0.f) {
        float k = max_d / __builtin_sqrtf(dist);
        dx *= k; dy *= k;
    }
    *px = cx + (int)dx;
    *py = cy + (int)dy;
}

/* ── callbacks ────────────────────────────────────────────────────────────── */
static void render(rfb_server *s) {
    rfb_draw_desktop(s);
    rfb_draw_winframe(s, &win);
    rfb_fill_rect(s, rfb_winframe_cx(&win), rfb_winframe_cy(&win),
                  WIN_W, WIN_H, 0xFF,0xFF,0xFF);

    for (int e = 0; e < 2; e++) {
        int cx, cy, px, py;
        eye_center(e, &cx, &cy);
        pupil_pos(e, &px, &py);

        rfb_fill_circle(s, cx, cy, EYE_R+EYE_RING, 0x33,0x33,0x33);
        rfb_fill_circle(s, cx, cy, EYE_R,           0xFF,0xFF,0xFF);
        rfb_fill_circle(s, px, py, PUPIL_R,     0x1A,0x1A,0x1A);
        rfb_fill_circle(s, px, py, PUPIL_R-5,   0x40,0x28,0x10);
        rfb_fill_circle(s, px-8, py-9, SHINE_R,   0xFF,0xFF,0xFF);
        rfb_fill_circle(s, px-8, py-9, SHINE_R-3, 0xEE,0xEE,0xEE);
    }
}

static void on_pointer(rfb_server *s, int buttons, int x, int y) {
    mouse_x = x;
    mouse_y = y;

    if (rfb_winframe_pointer(s, &win, buttons, x, y)) {
        /* window moved — everything under the old and new frame changed */
        rfb_damage_full(s);
        dmg_valid = 0;
        return;
    }

    /* Damage the union of the last-damaged and new pupil box per eye, so
     * the next update carries only the few KB that actually changed. */
    for (int e = 0; e < 2; e++) {
        int px, py;
        pupil_pos(e, &px, &py);
        if (!dmg_valid) {
            int cx, cy;
            eye_center(e, &cx, &cy);
            rfb_damage(s, cx-EYE_MARGIN, cy-EYE_MARGIN,
                       2*EYE_MARGIN+1, 2*EYE_MARGIN+1);
        } else if (px != dmg_px[e] || py != dmg_py[e]) {
            int x0 = (px < dmg_px[e] ? px : dmg_px[e]) - PUPIL_R - 1;
            int y0 = (py < dmg_py[e] ? py : dmg_py[e]) - PUPIL_R - 1;
            int x1 = (px > dmg_px[e] ? px : dmg_px[e]) + PUPIL_R + 1;
            int y1 = (py > dmg_py[e] ? py : dmg_py[e]) + PUPIL_R + 1;
            rfb_damage(s, x0, y0, x1-x0+1, y1-y0+1);
        }
        dmg_px[e] = px; dmg_py[e] = py;
    }
    dmg_valid = 1;
}

int main(void) {
    rfb_config cfg = {
        .name       = "LinuxOnTab xeyes",
        .w          = FB_W,
        .h          = FB_H,
        .port       = 5900,
        .render     = render,
        .on_pointer = on_pointer,
    };
    return rfb_run(&cfg);
}
