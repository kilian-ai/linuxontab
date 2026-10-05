/* lot-calendar — the date & time dialog xtiny opens on a double-click of the
 * taskbar clock (and closes on the next one). A big ticking clock, the full
 * date, and a month calendar with today marked. Arrows / PgUp PgDn / the < >
 * buttons change month, Home or "Today" comes back, Esc closes. */
#include "ui.h"
#include <time.h>

#define WIN_W 300
#define WIN_H 398
#define TITLE "Date & Time"          /* xtiny finds the dialog by this title */

static Ui u;
static int view_year, view_mon;      /* the month on show (mon 0-11) */
static int press_id = -1;

static const char *MONTHS[] = { "January", "February", "March", "April", "May", "June", "July",
                                "August", "September", "October", "November", "December" };
static const char *WEEKDAYS[] = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                                  "Friday", "Saturday" };
static const char *HEAD[] = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };

static int days_in(int y, int m) {
    static const int d[] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (m == 1 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) return 29;
    return d[m];
}

/* 0 = Monday ... 6 = Sunday, for day 1 of the month */
static int first_weekday(int y, int m) {
    struct tm t;
    memset(&t, 0, sizeof t);
    t.tm_year = y - 1900; t.tm_mon = m; t.tm_mday = 1; t.tm_hour = 12;
    timegm(&t);
    return (t.tm_wday + 6) % 7;
}

static struct tm now_tm(void) {
    time_t now = time(NULL);
    struct tm t;
    localtime_r(&now, &t);
    return t;
}

static void go_today(void) {
    struct tm t = now_tm();
    view_year = t.tm_year + 1900;
    view_mon = t.tm_mon;
}

static void shift_month(int d) {
    view_mon += d;
    while (view_mon < 0) { view_mon += 12; view_year--; }
    while (view_mon > 11) { view_mon -= 12; view_year++; }
}

/* layout */
static Rect r_prev(void)  { Rect r = { 16, 136, 30, 28 }; return r; }
static Rect r_next(void)  { Rect r = { u.w - 46, 136, 30, 28 }; return r; }
static Rect r_today(void) { Rect r = { u.w / 2 - 44, u.h - 38, 88, 28 }; return r; }
static int cell_w(void)   { return (u.w - 32) / 7; }

static void draw(void) {
    struct tm t = now_tm();
    ui_fill(&u, 0, 0, u.w, u.h, C_BG);

    /* clock + date */
    char hm[8], sec[4];
    snprintf(hm, sizeof hm, "%02d:%02d", t.tm_hour, t.tm_min);
    snprintf(sec, sizeof sec, "%02d", t.tm_sec);
    int s = 7, s2 = 3;
    int wbig = big_width(hm, s), wsec = big_width(sec, s2);
    int x0 = (u.w - (wbig + 8 + wsec)) / 2;
    big_text(&u, x0, 22, hm, s, C_TEXT);
    big_text(&u, x0 + wbig + 8, 22 + 7 * s - 7 * s2, sec, s2, C_ACCENT);
    char date[64];
    snprintf(date, sizeof date, "%s, %d %s %d", WEEKDAYS[t.tm_wday], t.tm_mday,
             MONTHS[t.tm_mon], t.tm_year + 1900);
    Rect dr = { 0, 82, u.w, 20 };
    ui_text_center(&u, dr, date, C_DIM);
    ui_fill(&u, 16, 118, u.w - 32, 1, C_LINE);

    /* month header */
    Rect pr = r_prev(), nr = r_next();
    ui_button(&u, pr, "<", rect_has(pr, u.mx, u.my), press_id == 1, C_BTN, C_TEXT);
    ui_button(&u, nr, ">", rect_has(nr, u.mx, u.my), press_id == 2, C_BTN, C_TEXT);
    char head[32];
    snprintf(head, sizeof head, "%s %d", MONTHS[view_mon], view_year);
    Rect hr = { 0, 136, u.w, 28 };
    ui_text_center(&u, hr, head, C_TEXT);

    /* grid */
    int cw = cell_w(), ch = 26, gx = (u.w - 7 * cw) / 2, gy = 176;
    for (int i = 0; i < 7; i++) {
        Rect c = { gx + i * cw, gy, cw, 20 };
        ui_text_center(&u, c, HEAD[i], i >= 5 ? C_FAINT : C_DIM);
    }
    gy += 22;
    int fw = first_weekday(view_year, view_mon), nd = days_in(view_year, view_mon);
    int is_this_month = view_year == t.tm_year + 1900 && view_mon == t.tm_mon;
    for (int d = 1; d <= nd; d++) {
        int idx = fw + d - 1, row = idx / 7, col = idx % 7;
        Rect c = { gx + col * cw, gy + row * ch, cw, ch };
        char num[4];
        snprintf(num, sizeof num, "%d", d);
        if (is_this_month && d == t.tm_mday) {
            ui_circle(&u, c.x + c.w / 2, c.y + c.h / 2, 11, C_ACCENT);
            ui_text_center(&u, c, num, C_ON_ACCENT);
        } else {
            ui_text_center(&u, c, num, col >= 5 ? C_DIM : C_TEXT);
        }
    }
    if (!is_this_month) {
        Rect tr = r_today();
        ui_button(&u, tr, "Today", rect_has(tr, u.mx, u.my), press_id == 3, C_BTN, C_TEXT);
    }
    ui_present(&u);
}

int main(void) {
    go_today();
    /* above the clock: bottom-right corner (xtiny keeps it off the taskbar) */
    Display *probe = XOpenDisplay(NULL);
    int x = -1, y = -1;
    if (probe) {
        int sw = DisplayWidth(probe, DefaultScreen(probe));
        int sh = DisplayHeight(probe, DefaultScreen(probe));
        XCloseDisplay(probe);
        x = sw - WIN_W - 12;
        y = sh - WIN_H - 40;
        if (x < 0) x = 0;
        if (y < 0) y = 0;
    }
    if (ui_open(&u, TITLE, "lot-calendar", WIN_W, WIN_H, x, y, WIN_W, WIN_H)) return 1;
    int last_sec = -1;
    for (;;) {
        XEvent ev;
        int got = ui_next_event(&u, &ev, 250);
        int redraw = 0;
        if (got) {
            switch (ev.type) {
            case Expose: if (ev.xexpose.count == 0) redraw = 1; break;
            case ConfigureNotify: case MotionNotify: case LeaveNotify: redraw = 1; break;
            case ButtonPress:
                if (ev.xbutton.button == 4) { shift_month(-1); redraw = 1; break; }
                if (ev.xbutton.button == 5) { shift_month(1); redraw = 1; break; }
                if (ev.xbutton.button != 1) break;
                press_id = rect_has(r_prev(), ev.xbutton.x, ev.xbutton.y) ? 1 :
                           rect_has(r_next(), ev.xbutton.x, ev.xbutton.y) ? 2 :
                           rect_has(r_today(), ev.xbutton.x, ev.xbutton.y) ? 3 : -1;
                redraw = 1;
                break;
            case ButtonRelease:
                if (press_id == 1 && rect_has(r_prev(), ev.xbutton.x, ev.xbutton.y)) shift_month(-1);
                if (press_id == 2 && rect_has(r_next(), ev.xbutton.x, ev.xbutton.y)) shift_month(1);
                if (press_id == 3 && rect_has(r_today(), ev.xbutton.x, ev.xbutton.y)) go_today();
                press_id = -1;
                redraw = 1;
                break;
            case KeyPress: {
                KeySym ks = ui_key(&ev, NULL, NULL);
                if (ks == XK_Escape || ks == XK_q) goto done;
                if (ks == XK_Left || ks == XK_Prior || ks == XK_Up) shift_month(-1);
                if (ks == XK_Right || ks == XK_Next || ks == XK_Down) shift_month(1);
                if (ks == XK_Home || ks == XK_t) go_today();
                redraw = 1;
                break;
            }
            }
        }
        if (u.want_close) break;
        struct tm t = now_tm();
        if (t.tm_sec != last_sec) { last_sec = t.tm_sec; redraw = 1; }
        if (redraw) draw();
    }
done:
    ui_close(&u);
    return 0;
}
