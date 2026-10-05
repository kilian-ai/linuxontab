/* lot-calc — a pocket calculator for the xtiny desktop.
 * Immediate execution like a desk calculator: 12 + 3 x 2 = 30. Keyboard:
 * digits . + - * / x % Enter/= Backspace, Esc/Delete clears, n negates. */
#include "ui.h"
#include <math.h>

static Ui u;
static char entry[32] = "0";        /* the number being typed / shown */
static double acc;                  /* left operand */
static char op;                     /* pending operator, 0 = none */
static int fresh = 1;               /* next digit starts a new entry */
static int error;
static char history[64];            /* small line above the display */

typedef struct { const char *label; char key; unsigned long color; } Key;
static const Key KEYS[5][4] = {
    {{"C",'c',C_BTN},  {"<-",'b',C_BTN}, {"%",'%',C_BTN}, {"/",'/',0x4A4038}},
    {{"7",'7',0},      {"8",'8',0},      {"9",'9',0},     {"x",'*',0x4A4038}},
    {{"4",'4',0},      {"5",'5',0},      {"6",'6',0},     {"-",'-',0x4A4038}},
    {{"1",'1',0},      {"2",'2',0},      {"3",'3',0},     {"+",'+',0x4A4038}},
    {{"+/-",'n',0},    {"0",'0',0},      {".",'.',0},     {"=",'=',C_ACCENT}},
};
static int pressed_r = -1, pressed_c = -1;

static void format(double v, char *out, size_t cap) {
    if (isnan(v) || isinf(v)) { snprintf(out, cap, "Error"); error = 1; return; }
    if (v == 0) v = 0;                                      /* no "-0" */
    snprintf(out, cap, "%.12g", v);
    if (strlen(out) > 14) snprintf(out, cap, "%.8e", v);
    /* trim a mantissa's trailing zeros: 1.50000000e+20 -> 1.5e+20 */
    char *e = strchr(out, 'e');
    if (e && strchr(out, '.')) {
        char *z = e;
        while (z > out && z[-1] == '0') z--;
        if (z > out && z[-1] == '.') z--;
        memmove(z, e, strlen(e) + 1);
    }
}

static double apply(double a, char o, double b) {
    switch (o) {
    case '+': return a + b;
    case '-': return a - b;
    case '*': return a * b;
    case '/': return b == 0 ? NAN : a / b;
    }
    return b;
}

static const char *op_sym(char o) {
    return o == '*' ? "x" : o == '/' ? "/" : o == '+' ? "+" : o == '-' ? "-" : "";
}

static void clear_all(void) {
    snprintf(entry, sizeof entry, "0");
    acc = 0; op = 0; fresh = 1; error = 0; history[0] = 0;
}

static void press(char k) {
    if (error && k != 'c') clear_all();
    if (k >= '0' && k <= '9') {
        if (fresh) { entry[0] = 0; fresh = 0; }
        if (!strcmp(entry, "0")) entry[0] = 0;
        if (strlen(entry) < 15) { size_t n = strlen(entry); entry[n] = k; entry[n + 1] = 0; }
    } else if (k == '.') {
        if (fresh) { snprintf(entry, sizeof entry, "0"); fresh = 0; }
        if (!strchr(entry, '.') && !strchr(entry, 'e') && strlen(entry) < 15) strcat(entry, ".");
    } else if (k == 'b') {
        if (!fresh) {
            size_t n = strlen(entry);
            if (n) entry[n - 1] = 0;
            if (!entry[0] || !strcmp(entry, "-")) snprintf(entry, sizeof entry, "0");
        }
    } else if (k == 'c') {
        clear_all();
    } else if (k == 'n') {
        double v = -atof(entry);
        format(v, entry, sizeof entry);
    } else if (k == '%') {
        double v = atof(entry);
        v = op ? acc * v / 100.0 : v / 100.0;   /* 200 + 10% = 220 */
        format(v, entry, sizeof entry);
        fresh = 1;
    } else if (k == '+' || k == '-' || k == '*' || k == '/') {
        if (op && !fresh) acc = apply(acc, op, atof(entry));
        else if (!op) acc = atof(entry);
        op = k;
        format(acc, entry, sizeof entry);
        char a[32];
        format(acc, a, sizeof a);
        snprintf(history, sizeof history, "%s %s", a, op_sym(op));
        fresh = 1;
    } else if (k == '=') {
        if (op) {
            char a[32], b[32];
            format(acc, a, sizeof a);
            snprintf(b, sizeof b, "%s", entry);
            double v = apply(acc, op, atof(entry));
            snprintf(history, sizeof history, "%s %s %s =", a, op_sym(op), b);
            format(v, entry, sizeof entry);
            acc = v; op = 0;
        }
        fresh = 1;
    }
}

/* layout */
#define PAD 12
#define DISP_H 92
static Rect key_rect(int r, int c) {
    int gw = u.w - 2 * PAD, gh = u.h - DISP_H - 2 * PAD - 8;
    int kw = (gw - 3 * 8) / 4, kh = (gh - 4 * 8) / 5;
    Rect k = { PAD + c * (kw + 8), DISP_H + PAD + 8 + r * (kh + 8), kw, kh };
    return k;
}

static void draw(void) {
    ui_fill(&u, 0, 0, u.w, u.h, C_BG);
    ui_rrect(&u, PAD, PAD, u.w - 2 * PAD, DISP_H, 8, C_PANEL);
    ui_text(&u, u.w - PAD - 10 - ui_text_w(&u, history, -1), PAD + 8, history, -1, C_DIM);
    /* the biggest scale at which the number fits */
    int s = 6;
    while (s > 2 && big_width(error ? "Error" : entry, s) > u.w - 2 * PAD - 20) s--;
    const char *shown = error ? "Error" : entry;
    int bw = big_width(shown, s);
    big_text(&u, u.w - PAD - 12 - bw, PAD + DISP_H - 12 - 7 * s, shown, s, error ? 0xFF7A6A : C_TEXT);
    for (int r = 0; r < 5; r++)
        for (int c = 0; c < 4; c++) {
            const Key *k = &KEYS[r][c];
            Rect kr = key_rect(r, c);
            unsigned long base = k->color ? k->color : C_BTN;
            if (!k->color) base = 0x3A3530;
            unsigned long fg = k->color == C_ACCENT ? C_ON_ACCENT : C_TEXT;
            ui_button(&u, kr, k->label, rect_has(kr, u.mx, u.my), r == pressed_r && c == pressed_c, base, fg);
        }
    ui_present(&u);
}

int main(void) {
    if (ui_open(&u, "Calculator", "lot-calc", 300, 400, -1, -1, 240, 320)) return 1;
    for (;;) {
        XEvent ev;
        if (!ui_next_event(&u, &ev, -1)) continue;
        int redraw = 0;
        switch (ev.type) {
        case Expose: if (ev.xexpose.count == 0) redraw = 1; break;
        case ConfigureNotify: redraw = 1; break;
        case MotionNotify: case LeaveNotify: redraw = 1; break;
        case ButtonPress:
            if (ev.xbutton.button != 1) break;
            for (int r = 0; r < 5; r++)
                for (int c = 0; c < 4; c++)
                    if (rect_has(key_rect(r, c), ev.xbutton.x, ev.xbutton.y)) { pressed_r = r; pressed_c = c; }
            redraw = 1;
            break;
        case ButtonRelease:
            if (pressed_r >= 0 && rect_has(key_rect(pressed_r, pressed_c), ev.xbutton.x, ev.xbutton.y))
                press(KEYS[pressed_r][pressed_c].key);
            pressed_r = pressed_c = -1;
            redraw = 1;
            break;
        case KeyPress: {
            char t[16]; int n;
            KeySym ks = ui_key(&ev, t, &n);
            if (ks == XK_Return || ks == XK_KP_Enter) press('=');
            else if (ks == XK_BackSpace) press('b');
            else if (ks == XK_Escape || ks == XK_Delete) press('c');
            else if (ks == XK_KP_Add) press('+');
            else if (ks == XK_KP_Subtract) press('-');
            else if (ks == XK_KP_Multiply) press('*');
            else if (ks == XK_KP_Divide) press('/');
            else if (ks == XK_KP_Decimal || ks == XK_comma) press('.');
            else if (ks >= XK_KP_0 && ks <= XK_KP_9) press((char)('0' + (ks - XK_KP_0)));
            else if (ks == XK_q && (ev.xkey.state & ControlMask)) goto done;
            else if (n == 1) {
                char k = t[0];
                if (k == 'x' || k == 'X') k = '*';
                if (k == 'C') k = 'c';
                if (strchr("0123456789.+-*/%=cn", k)) press(k);
            }
            redraw = 1;
            break;
        }
        }
        if (u.want_close) break;
        if (redraw) draw();
    }
done:
    ui_close(&u);
    return 0;
}
