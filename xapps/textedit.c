/* lot-textedit — a plain text editor for the xtiny desktop.
 *   lot-textedit [file]
 * Toolbar New / Open / Save / Save As, line numbers, a status bar. Keys:
 * Ctrl+N new, Ctrl+O open, Ctrl+S save, Ctrl+Shift+S save as, Ctrl+Q quit,
 * Ctrl+A select all, Ctrl+C/X/V copy/cut/paste (an in-editor clipboard:
 * xtiny has no X selections), Ctrl+Z undo, Shift+movement selects, Tab
 * inserts 4 spaces. Unsaved changes are never dropped without a second ask. */
#include "ui.h"
#include <errno.h>
#include <time.h>
#include <unistd.h>

typedef struct { char *s; int n, cap; } Line;

static Ui u;
static Line *L;
static int nl, capl;
static int cy, cx;                   /* cursor: line, byte */
static int ay, ax, sel;              /* selection anchor (when sel) */
static int top, left;                /* scroll: first line, first column */
static char path[512];
static int modified;
static char *clip; static int clip_n;
static char msg[160]; static time_t msg_at;
static int prompt;                   /* 0, 'o' open, 's' save as */
static char pbuf[512]; static int pn;
static int armed;                    /* unsaved-changes warning shown: 'q','n','c' */
static int dragging, press_btn = -1;

/* ── text storage ─────────────────────────────────────────────────────────── */
static void line_reserve(Line *l, int need) {
    if (need <= l->cap) return;
    int c = l->cap ? l->cap : 16;
    while (c < need) c *= 2;
    l->s = realloc(l->s, (size_t)c);
    l->cap = c;
}

static void lines_reserve(int need) {
    if (need <= capl) return;
    int c = capl ? capl : 64;
    while (c < need) c *= 2;
    L = realloc(L, (size_t)c * sizeof *L);
    memset(L + capl, 0, (size_t)(c - capl) * sizeof *L);
    capl = c;
}

static void insert_line(int at, const char *s, int n) {
    lines_reserve(nl + 1);
    memmove(L + at + 1, L + at, (size_t)(nl - at) * sizeof *L);
    memset(&L[at], 0, sizeof L[at]);
    line_reserve(&L[at], n + 1);
    if (n) memcpy(L[at].s, s, (size_t)n);
    L[at].n = n;
    nl++;
}

static void delete_line(int at) {
    free(L[at].s);
    memmove(L + at, L + at + 1, (size_t)(nl - at - 1) * sizeof *L);
    nl--;
    memset(&L[nl], 0, sizeof L[nl]);
}

static void clear_text(void) {
    while (nl) delete_line(nl - 1);
    insert_line(0, "", 0);
    cy = cx = top = left = 0;
    sel = 0;
}

/* whole text as one buffer (caller frees) */
static char *serialize(int *len) {
    size_t total = 0;
    for (int i = 0; i < nl; i++) total += (size_t)L[i].n + 1;
    char *b = malloc(total + 1), *p = b;
    for (int i = 0; i < nl; i++) {
        memcpy(p, L[i].s, (size_t)L[i].n);
        p += L[i].n;
        if (i < nl - 1) *p++ = '\n';
    }
    *p = 0;
    *len = (int)(p - b);
    return b;
}

static void load_buffer(const char *b, int n) {
    while (nl) delete_line(nl - 1);
    int start = 0;
    for (int i = 0; i <= n; i++) {
        if (i == n || b[i] == '\n') {
            int e = i;
            if (e > start && b[e - 1] == '\r') e--;     /* CRLF files */
            insert_line(nl, b + start, e - start);
            start = i + 1;
        }
    }
    if (!nl) insert_line(0, "", 0);
}

/* ── undo: snapshots of the whole text, grouped by edit kind ──────────────── */
typedef struct { char *text; int len, cy, cx; } Snap;
#define MAX_UNDO 64
static Snap undo[MAX_UNDO];
static int nundo, last_kind;
static time_t last_edit;

static void snapshot(int kind) {
    time_t now = time(NULL);
    if (kind == last_kind && kind != 0 && now - last_edit < 2) { last_edit = now; return; }
    last_kind = kind; last_edit = now;
    if (nundo == MAX_UNDO) { free(undo[0].text); memmove(undo, undo + 1, sizeof undo[0] * (MAX_UNDO - 1)); nundo--; }
    Snap *s = &undo[nundo++];
    s->text = serialize(&s->len);
    s->cy = cy; s->cx = cx;
}

static void do_undo(void) {
    if (!nundo) { snprintf(msg, sizeof msg, "Nothing to undo"); msg_at = time(NULL); return; }
    Snap *s = &undo[--nundo];
    load_buffer(s->text, s->len);
    free(s->text);
    cy = s->cy < nl ? s->cy : nl - 1;
    cx = s->cx <= L[cy].n ? s->cx : L[cy].n;
    sel = 0; last_kind = 0; modified = 1;
}

static void forget_undo(void) {
    while (nundo) free(undo[--nundo].text);
    last_kind = 0;
}

/* ── selection & editing ──────────────────────────────────────────────────── */
static void sel_range(int *y0, int *x0, int *y1, int *x1) {
    if (ay < cy || (ay == cy && ax < cx)) { *y0 = ay; *x0 = ax; *y1 = cy; *x1 = cx; }
    else { *y0 = cy; *x0 = cx; *y1 = ay; *x1 = ax; }
}

static int has_sel(void) { return sel && (ay != cy || ax != cx); }

static void delete_sel(void) {
    if (!has_sel()) { sel = 0; return; }
    int y0, x0, y1, x1;
    sel_range(&y0, &x0, &y1, &x1);
    Line *a = &L[y0], *b = &L[y1];
    int tail = b->n - x1;
    line_reserve(a, x0 + tail + 1);
    memmove(a->s + x0, b->s + x1, (size_t)tail);
    a->n = x0 + tail;
    for (int i = y1; i > y0; i--) delete_line(i);
    cy = y0; cx = x0; sel = 0;
    modified = 1;
}

static char *sel_text(int *len) {
    int y0, x0, y1, x1;
    sel_range(&y0, &x0, &y1, &x1);
    size_t cap = 1;
    for (int i = y0; i <= y1; i++) cap += (size_t)L[i].n + 1;
    char *b = malloc(cap), *p = b;
    for (int i = y0; i <= y1; i++) {
        int s = i == y0 ? x0 : 0, e = i == y1 ? x1 : L[i].n;
        memcpy(p, L[i].s + s, (size_t)(e - s));
        p += e - s;
        if (i < y1) *p++ = '\n';
    }
    *len = (int)(p - b);
    return b;
}

static void insert_text(const char *t, int n) {
    delete_sel();
    for (int i = 0; i < n; i++) {
        if (t[i] == '\n') {
            Line *l = &L[cy];
            insert_line(cy + 1, l->s + cx, l->n - cx);
            L[cy].n = cx;
            cy++; cx = 0;
        } else if (t[i] != '\r') {
            Line *l = &L[cy];
            line_reserve(l, l->n + 2);
            memmove(l->s + cx + 1, l->s + cx, (size_t)(l->n - cx));
            l->s[cx++] = t[i];
            l->n++;
        }
    }
    modified = 1;
}

static void newline_indent(void) {
    int ind = 0;
    while (ind < L[cy].n && ind < cx && L[cy].s[ind] == ' ') ind++;
    char b[256];
    b[0] = '\n';
    if (ind > 250) ind = 250;
    memset(b + 1, ' ', (size_t)ind);
    insert_text(b, ind + 1);
}

static void backspace(void) {
    if (has_sel()) { delete_sel(); return; }
    sel = 0;
    if (cx > 0) {
        Line *l = &L[cy];
        memmove(l->s + cx - 1, l->s + cx, (size_t)(l->n - cx));
        l->n--; cx--;
    } else if (cy > 0) {
        Line *p = &L[cy - 1], *l = &L[cy];
        int at = p->n;
        line_reserve(p, p->n + l->n + 1);
        memcpy(p->s + p->n, l->s, (size_t)l->n);
        p->n += l->n;
        delete_line(cy);
        cy--; cx = at;
    } else return;
    modified = 1;
}

static void delete_fwd(void) {
    if (has_sel()) { delete_sel(); return; }
    sel = 0;
    if (cx < L[cy].n) { cx++; backspace(); }
    else if (cy < nl - 1) { cy++; cx = 0; backspace(); }
}

/* ── files ────────────────────────────────────────────────────────────────── */
static void set_title(void) {
    char t[600];
    const char *base = path[0] ? (strrchr(path, '/') ? strrchr(path, '/') + 1 : path) : "Untitled";
    snprintf(t, sizeof t, "%s%s - Text Editor", modified ? "*" : "", base);
    XStoreName(u.d, u.win, t);
}

static void say(const char *fmt, const char *arg) {
    snprintf(msg, sizeof msg, fmt, arg);
    msg_at = time(NULL);
}

static int open_file(const char *p) {
    FILE *f = fopen(p, "rb");
    if (!f) {
        if (errno == ENOENT) {               /* a new file: start empty */
            clear_text(); forget_undo();
            snprintf(path, sizeof path, "%s", p);
            modified = 0;
            say("New file %s", p);
            return 0;
        }
        snprintf(msg, sizeof msg, "Cannot open %s: %s", p, strerror(errno));
        msg_at = time(NULL);
        return -1;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0 || sz > 32L * 1024 * 1024) { fclose(f); say("%s is too big to edit here", p); return -1; }
    char *b = malloc((size_t)sz + 1);
    size_t got = fread(b, 1, (size_t)sz, f);
    fclose(f);
    load_buffer(b, (int)got);
    free(b);
    forget_undo();
    snprintf(path, sizeof path, "%s", p);
    cy = cx = top = left = 0; sel = 0; modified = 0;
    say("Opened %s", p);
    return 0;
}

static int save_file(const char *p) {
    int n;
    char *b = serialize(&n);
    FILE *f = fopen(p, "wb");
    if (!f) {
        snprintf(msg, sizeof msg, "Cannot save %s: %s", p, strerror(errno));
        msg_at = time(NULL);
        free(b);
        return -1;
    }
    int ok = fwrite(b, 1, (size_t)n, f) == (size_t)n;
    if (n && b[n - 1] != '\n') ok &= fputc('\n', f) != EOF;
    ok &= fclose(f) == 0;
    free(b);
    if (!ok) { say("Writing %s failed", p); return -1; }
    snprintf(path, sizeof path, "%s", p);
    modified = 0;
    say("Saved %s", p);
    return 0;
}

static void start_prompt(int kind) {
    prompt = kind;
    if (path[0]) snprintf(pbuf, sizeof pbuf, "%s", path);
    else {
        char cwd[400];
        if (!getcwd(cwd, sizeof cwd)) snprintf(cwd, sizeof cwd, "/root");
        snprintf(pbuf, sizeof pbuf, "%s/%s", strcmp(cwd, "/") ? cwd : "", kind == 's' ? "untitled.txt" : "");
    }
    pn = (int)strlen(pbuf);
}

static void do_save(void) {
    if (path[0]) save_file(path);
    else start_prompt('s');
}

/* "Unsaved changes" guard: returns 1 when the action may go ahead. */
static int may_discard(int what) {
    if (!modified || armed == what) { armed = 0; return 1; }
    armed = what;
    say(what == 'n' ? "Unsaved changes - Ctrl+S saves, New again discards them" :
        what == 'o' ? "Unsaved changes - Ctrl+S saves, Open again discards them" :
                      "Unsaved changes - Ctrl+S saves, close again discards them", "");
    return 0;
}

/* ── layout & drawing ─────────────────────────────────────────────────────── */
#define TB_H 42
#define ST_H 26
static const char *TB_LABELS[] = { "New", "Open", "Save", "Save As" };
static Rect tb_button(int i) {
    int x = 10;
    for (int k = 0; k < i; k++) x += ui_text_w(&u, TB_LABELS[k], -1) + 28 + 6;
    Rect r = { x, 7, ui_text_w(&u, TB_LABELS[i], -1) + 28, TB_H - 14 };
    return r;
}

static int gutter_w(void) {
    int digits = 1, n = nl;
    while (n >= 10) { n /= 10; digits++; }
    if (digits < 3) digits = 3;
    return digits * u.cw + 18;
}
static int text_x(void) { return gutter_w() + 6; }
static int rows(void) { int r = (u.h - TB_H - ST_H - 8) / u.ch; return r < 1 ? 1 : r; }
static int cols(void) { int c = (u.w - text_x() - 8) / u.cw; return c < 1 ? 1 : c; }

static void ensure_visible(void) {
    if (cy < top) top = cy;
    if (cy >= top + rows()) top = cy - rows() + 1;
    if (cx < left) left = cx;
    if (cx >= left + cols()) left = cx - cols() + 1;
    if (top < 0) top = 0;
    if (left < 0) left = 0;
}

static void draw(void) {
    ui_fill(&u, 0, 0, u.w, u.h, C_BG);
    /* toolbar */
    ui_fill(&u, 0, 0, u.w, TB_H, C_PANEL);
    ui_fill(&u, 0, TB_H - 1, u.w, 1, C_LINE);
    for (int i = 0; i < 4; i++) {
        Rect r = tb_button(i);
        ui_button(&u, r, TB_LABELS[i], rect_has(r, u.mx, u.my), press_btn == i, C_BTN, C_TEXT);
    }
    const char *base = path[0] ? path : "Untitled";
    char name[300];
    snprintf(name, sizeof name, "%s%s", base, modified ? "  (modified)" : "");
    int nw = ui_text_w(&u, name, -1), room = u.w - tb_button(3).x - tb_button(3).w - 24;
    if (nw <= room) ui_text(&u, u.w - 14 - nw, (TB_H - u.ch) / 2, name, -1, C_DIM);

    /* text */
    int y0 = TB_H + 4, gx = gutter_w(), tx = text_x();
    ui_fill(&u, 0, TB_H, gx, u.h - TB_H - ST_H, 0x1B1916);
    int sy0 = 0, sx0 = 0, sy1 = 0, sx1 = 0, hs = has_sel();
    if (hs) sel_range(&sy0, &sx0, &sy1, &sx1);
    for (int r = 0; r < rows() && top + r < nl; r++) {
        int ln = top + r, y = y0 + r * u.ch;
        Line *l = &L[ln];
        char num[16];
        int k = snprintf(num, sizeof num, "%d", ln + 1);
        ui_text(&u, gx - 10 - k * u.cw, y, num, k, ln == cy ? C_TEXT : C_FAINT);
        if (ln == cy && !hs) ui_fill(&u, gx, y, u.w - gx, u.ch, 0x262320);
        if (hs && ln >= sy0 && ln <= sy1) {
            int a = ln == sy0 ? sx0 : 0, b = ln == sy1 ? sx1 : l->n + 1;
            a -= left; b -= left;
            if (a < 0) a = 0;
            if (b > cols()) b = cols();
            if (b > a) ui_fill(&u, tx + a * u.cw, y, (b - a) * u.cw, u.ch, C_SEL);
        }
        if (l->n > left) {
            int n = l->n - left;
            if (n > cols()) n = cols();
            ui_text(&u, tx, y, l->s + left, n, C_TEXT);
        }
    }
    /* cursor */
    if (cy >= top && cy < top + rows() && cx >= left && cx <= left + cols() && !prompt)
        ui_fill(&u, tx + (cx - left) * u.cw - 1, y0 + (cy - top) * u.ch, 2, u.ch, C_ACCENT);

    /* status bar / prompt */
    int sy = u.h - ST_H;
    ui_fill(&u, 0, sy, u.w, ST_H, C_PANEL);
    ui_fill(&u, 0, sy, u.w, 1, C_LINE);
    int ty = sy + (ST_H - u.ch) / 2;
    if (prompt) {
        const char *lab = prompt == 'o' ? "Open file: " : "Save as: ";
        int lw = ui_text_w(&u, lab, -1);
        ui_text(&u, 10, ty, lab, -1, C_ACCENT);
        int vis = (u.w - 20 - lw) / u.cw - 1, off = pn > vis ? pn - vis : 0;
        ui_text(&u, 10 + lw, ty, pbuf + off, pn - off, C_TEXT);
        ui_fill(&u, 10 + lw + (pn - off) * u.cw, ty, 2, u.ch, C_ACCENT);
    } else {
        char pos[64];
        snprintf(pos, sizeof pos, "Ln %d, Col %d   %d lines", cy + 1, cx + 1, nl);
        ui_text(&u, u.w - 12 - ui_text_w(&u, pos, -1), ty, pos, -1, C_DIM);
        if (msg[0] && time(NULL) - msg_at < 6) ui_text(&u, 10, ty, msg, -1, C_TEXT);
        else if (!msg[0] || time(NULL) - msg_at >= 6)
            ui_text(&u, 10, ty, "Ctrl+S save  Ctrl+O open  Ctrl+Z undo", -1, C_FAINT);
    }
    ui_present(&u);
}

/* text-area pixel -> line/byte */
static void hit(int px, int py, int *ly, int *lx) {
    int r = (py - TB_H - 4) / u.ch;
    if (py < TB_H + 4) r = -1;
    int y = top + r;
    if (y < 0) y = 0;
    if (y >= nl) y = nl - 1;
    int c = (px - text_x() + u.cw / 2) / u.cw + left;
    if (c < 0) c = 0;
    if (c > L[y].n) c = L[y].n;
    *ly = y; *lx = c;
}

/* ── input ────────────────────────────────────────────────────────────────── */
static void move(int dy, int dx, int extend) {
    if (extend && !sel) { sel = 1; ay = cy; ax = cx; }
    if (!extend) sel = 0;
    if (dx) {
        cx += dx;
        if (cx < 0) { if (cy > 0) { cy--; cx = L[cy].n; } else cx = 0; }
        else if (cx > L[cy].n) { if (cy < nl - 1) { cy++; cx = 0; } else cx = L[cy].n; }
    }
    if (dy) {
        cy += dy;
        if (cy < 0) cy = 0;
        if (cy >= nl) cy = nl - 1;
        if (cx > L[cy].n) cx = L[cy].n;
    }
}

static int prompt_key(KeySym ks, const char *t, int n) {
    if (ks == XK_Escape) { prompt = 0; return 1; }
    if (ks == XK_Return || ks == XK_KP_Enter) {
        int k = prompt;
        prompt = 0;
        if (!pn) return 1;
        if (k == 'o') open_file(pbuf);
        else save_file(pbuf);
        return 1;
    }
    if (ks == XK_BackSpace) { if (pn) pbuf[--pn] = 0; return 1; }
    if (n == 1 && (unsigned char)t[0] >= 32 && pn < (int)sizeof pbuf - 1) { pbuf[pn++] = t[0]; pbuf[pn] = 0; }
    return 1;
}

static int key(XEvent *ev) {               /* returns 0 to quit */
    char t[16]; int n;
    KeySym ks = ui_key(ev, t, &n);
    int ctrl = ev->xkey.state & ControlMask, shift = ev->xkey.state & ShiftMask;
    if (prompt) return prompt_key(ks, t, n);
    if (ks != XK_q && ks != XK_n && ks != XK_o) armed = 0;
    if (ctrl) {
        switch (ks) {
        case XK_s: case XK_S: if (shift) start_prompt('s'); else do_save(); return 1;
        case XK_o: if (may_discard('o')) start_prompt('o'); return 1;
        case XK_n: if (may_discard('n')) { clear_text(); forget_undo(); path[0] = 0; modified = 0; } return 1;
        case XK_q: return !may_discard('c') ? 1 : 0;
        case XK_a: ay = 0; ax = 0; cy = nl - 1; cx = L[cy].n; sel = 1; return 1;
        case XK_z: do_undo(); return 1;
        case XK_c: case XK_x:
            if (has_sel()) {
                free(clip);
                clip = sel_text(&clip_n);
                if (ks == XK_x) { snapshot(0); delete_sel(); }
                else say("Copied", "");
            }
            return 1;
        case XK_v: if (clip) { snapshot(0); insert_text(clip, clip_n); } return 1;
        case XK_Home: move(-nl, 0, shift); cx = 0; return 1;
        case XK_End: move(nl, 0, shift); cx = L[cy].n; return 1;
        }
        return 1;
    }
    switch (ks) {
    case XK_Left: case XK_KP_Left:   move(0, -1, shift); return 1;
    case XK_Right: case XK_KP_Right: move(0, 1, shift); return 1;
    case XK_Up: case XK_KP_Up:       move(-1, 0, shift); return 1;
    case XK_Down: case XK_KP_Down:   move(1, 0, shift); return 1;
    case XK_Prior: case XK_KP_Prior: move(-rows(), 0, shift); return 1;
    case XK_Next: case XK_KP_Next:   move(rows(), 0, shift); return 1;
    case XK_Home: case XK_KP_Home: if (shift && !sel) { sel = 1; ay = cy; ax = cx; } if (!shift) sel = 0; cx = 0; return 1;
    case XK_End: case XK_KP_End:   if (shift && !sel) { sel = 1; ay = cy; ax = cx; } if (!shift) sel = 0; cx = L[cy].n; return 1;
    case XK_BackSpace: snapshot(2); backspace(); return 1;
    case XK_Delete: case XK_KP_Delete: snapshot(2); delete_fwd(); return 1;
    case XK_Return: case XK_KP_Enter: snapshot(3); newline_indent(); return 1;
    case XK_Tab: snapshot(1); insert_text("    ", 4); return 1;
    case XK_Escape: sel = 0; return 1;
    }
    if (n >= 1 && (unsigned char)t[0] >= 32 && t[0] != 127) { snapshot(1); insert_text(t, n); }
    return 1;
}

int main(int argc, char **argv) {
    clear_text();
    if (ui_open(&u, "Text Editor", "lot-textedit", 720, 480, -1, -1, 360, 220)) return 1;
    if (argc > 1) open_file(argv[1]);
    set_title();
    int was_modified = -1;
    char was_path[512] = "";
    for (;;) {
        XEvent ev;
        int got = ui_next_event(&u, &ev, msg[0] ? 1000 : -1);
        int redraw = !got;                      /* timeout: let the message fade */
        if (got) {
            switch (ev.type) {
            case Expose: if (ev.xexpose.count == 0) redraw = 1; break;
            case ConfigureNotify: redraw = 1; break;
            case LeaveNotify: redraw = 1; break;
            case MotionNotify:
                if (dragging) {
                    int ly, lx;
                    hit(ev.xmotion.x, ev.xmotion.y, &ly, &lx);
                    cy = ly; cx = lx;
                    ensure_visible();
                }
                redraw = 1;
                break;
            case ButtonPress:
                if (ev.xbutton.button == 4 || ev.xbutton.button == 5) {
                    top += ev.xbutton.button == 4 ? -3 : 3;
                    if (top > nl - 1) top = nl - 1;
                    if (top < 0) top = 0;
                    redraw = 1;
                    break;
                }
                if (ev.xbutton.button != 1) break;
                if (ev.xbutton.y < TB_H) {
                    for (int i = 0; i < 4; i++) if (rect_has(tb_button(i), ev.xbutton.x, ev.xbutton.y)) press_btn = i;
                } else if (ev.xbutton.y < u.h - ST_H && !prompt) {
                    int ly, lx;
                    hit(ev.xbutton.x, ev.xbutton.y, &ly, &lx);
                    if (ev.xbutton.state & ShiftMask) { if (!sel) { sel = 1; ay = cy; ax = cx; } }
                    else { sel = 1; ay = ly; ax = lx; }
                    cy = ly; cx = lx;
                    dragging = 1;
                }
                redraw = 1;
                break;
            case ButtonRelease:
                dragging = 0;
                if (press_btn >= 0 && rect_has(tb_button(press_btn), ev.xbutton.x, ev.xbutton.y)) {
                    switch (press_btn) {
                    case 0: if (may_discard('n')) { clear_text(); forget_undo(); path[0] = 0; modified = 0; } break;
                    case 1: if (may_discard('o')) start_prompt('o'); break;
                    case 2: do_save(); break;
                    case 3: start_prompt('s'); break;
                    }
                }
                press_btn = -1;
                redraw = 1;
                break;
            case KeyPress:
                if (!key(&ev)) goto done;
                if (!prompt) ensure_visible();
                redraw = 1;
                break;
            }
        }
        if (u.want_close) {
            u.want_close = 0;
            if (may_discard('c')) break;
            redraw = 1;
        }
        if (modified != was_modified || strcmp(path, was_path)) {
            was_modified = modified;
            snprintf(was_path, sizeof was_path, "%s", path);
            set_title();
        }
        if (msg[0] && time(NULL) - msg_at >= 6 && !got) { msg[0] = 0; redraw = 1; }
        if (redraw) draw();
    }
done:
    ui_close(&u);
    return 0;
}
