/* lotfm — a tiny two-pane file manager for LinuxOnTab (wasm32 guest).
 *
 * No ncurses (initscr() is broken on this target — wasm call_indirect
 * signature traps deep in the library). Raw ANSI escapes + termios only,
 * both proven to work in this guest.
 *
 * Keys:
 *   up/down or j/k   move selection
 *   PgUp/PgDn        page
 *   enter or l       enter directory / view file (built-in pager)
 *   left, h, or ..   parent directory
 *   Tab              switch pane
 *   c                copy selected file to other pane's directory
 *   m                move selected file to other pane's directory
 *   D                delete file (asks y/N)
 *   r                refresh
 *   q                quit
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <termios.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <ctype.h>

#define MAXENTRIES 4096
#define NAMELEN    256

typedef struct {
    char name[NAMELEN];
    off_t size;
    unsigned is_dir:1;
    unsigned is_link:1;
} entry_t;

typedef struct {
    char path[1024];
    entry_t ents[MAXENTRIES];
    int count;
    int sel;      /* selected index */
    int top;      /* first visible index */
} pane_t;

static pane_t panes[2];
static int active = 0;
static int rows = 24, cols = 80;
static struct termios orig_tio;
static char status[256] = "";

/* ---------- terminal ---------- */

static void term_raw(void)
{
    struct termios t;
    tcgetattr(STDIN_FILENO, &orig_tio);
    t = orig_tio;
    t.c_lflag &= ~(ICANON | ECHO);
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &t);
}

static void term_restore(void)
{
    tcsetattr(STDIN_FILENO, TCSANOW, &orig_tio);
    printf("\033[?25h\033[0m\033[2J\033[H");
    fflush(stdout);
}

static void term_size(void)
{
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 4 && ws.ws_col > 20) {
        rows = ws.ws_row;
        cols = ws.ws_col;
    }
}

/* ---------- directory loading ---------- */

static int cmp_entries(const void *a, const void *b)
{
    const entry_t *x = a, *y = b;
    if (x->is_dir != y->is_dir)
        return y->is_dir - x->is_dir;   /* dirs first */
    return strcmp(x->name, y->name);
}

static void load_pane(pane_t *p)
{
    DIR *d;
    struct dirent *de;

    p->count = 0;
    d = opendir(p->path);
    if (d == NULL) {
        snprintf(status, sizeof(status), "opendir %s: %s", p->path, strerror(errno));
        return;
    }
    while ((de = readdir(d)) != NULL && p->count < MAXENTRIES) {
        entry_t *e;
        char full[1300];
        struct stat st;

        if (strcmp(de->d_name, ".") == 0)
            continue;
        if (strcmp(de->d_name, "..") == 0 && strcmp(p->path, "/") == 0)
            continue;
        e = &p->ents[p->count];
        snprintf(e->name, NAMELEN, "%s", de->d_name);
        snprintf(full, sizeof(full), "%s/%s", strcmp(p->path, "/") ? p->path : "", de->d_name);
        e->size = 0;
        e->is_dir = 0;
        e->is_link = 0;
        if (lstat(full, &st) == 0) {
            e->is_link = S_ISLNK(st.st_mode);
            if (e->is_link) {
                struct stat st2;
                if (stat(full, &st2) == 0)
                    st = st2;
            }
            e->is_dir = S_ISDIR(st.st_mode);
            e->size = st.st_size;
        }
        p->count++;
    }
    closedir(d);
    qsort(p->ents, p->count, sizeof(entry_t), cmp_entries);
    if (p->sel >= p->count)
        p->sel = p->count ? p->count - 1 : 0;
    if (p->top > p->sel)
        p->top = p->sel;
}

/* ---------- drawing ---------- */

static void human_size(off_t n, char *buf, size_t len)
{
    if (n < 1024)
        snprintf(buf, len, "%5ld", (long) n);
    else if (n < 1024 * 1024)
        snprintf(buf, len, "%4ldK", (long) (n / 1024));
    else if (n < 1024L * 1024 * 1024)
        snprintf(buf, len, "%4ldM", (long) (n / (1024 * 1024)));
    else
        snprintf(buf, len, "%4ldG", (long) (n / (1024L * 1024 * 1024)));
}

static void draw(void)
{
    int list_rows = rows - 3;           /* header + status + keybar */
    int half = cols / 2;
    int pi, i;
    char line[512];

    printf("\033[?25l\033[H");

    /* header: both paths */
    for (pi = 0; pi < 2; pi++) {
        int w = (pi == 0) ? half : cols - half;
        const char *marker = (pi == active) ? "\033[7m" : "\033[44;97m";
        snprintf(line, sizeof(line), " %.*s", w - 2, panes[pi].path);
        printf("%s%-*.*s\033[0m", marker, w, w, line);
    }
    printf("\r\n");

    for (pi = 0; pi < 2; pi++) {
        pane_t *p = &panes[pi];
        if (p->sel < p->top)
            p->top = p->sel;
        if (p->sel >= p->top + list_rows)
            p->top = p->sel - list_rows + 1;
    }

    for (i = 0; i < list_rows; i++) {
        for (pi = 0; pi < 2; pi++) {
            pane_t *p = &panes[pi];
            int w = (pi == 0) ? half : cols - half;
            int idx = p->top + i;

            if (idx < p->count) {
                entry_t *e = &p->ents[idx];
                char sz[8];
                const char *color = e->is_dir ? "\033[1;97m" : "\033[0m";
                const char *tag = e->is_dir ? "/" : (e->is_link ? "@" : " ");
                int sel = (idx == p->sel);
                int namew = w - 9;

                human_size(e->size, sz, sizeof(sz));
                if (sel && pi == active)
                    printf("\033[46;30m");
                else if (sel)
                    printf("\033[100;97m");
                else
                    printf("%s", color);
                snprintf(line, sizeof(line), "%s%-*.*s %s", tag, namew, namew, e->name,
                         e->is_dir ? "  DIR" : sz);
                printf("%-*.*s\033[0m", w, w, line);
            } else {
                printf("%-*s", w, "");
            }
        }
        printf("\r\n");
    }

    /* status line */
    printf("\033[33m%-*.*s\033[0m\r\n", cols, cols, status);
    /* key bar */
    printf("\033[7m%-*.*s\033[0m", cols, cols,
           " Tab:pane  Enter:open  h/..:up  c:copy  m:move  D:del  r:refresh  q:quit");
    fflush(stdout);
}

/* ---------- pager (F3-lite) ---------- */

static void view_file(const char *path)
{
    FILE *f = fopen(path, "r");
    char buf[4096];
    int line = 0, ch;

    if (f == NULL) {
        snprintf(status, sizeof(status), "open %s: %s", path, strerror(errno));
        return;
    }
    printf("\033[2J\033[H\033[0m");
    while (fgets(buf, sizeof(buf), f) != NULL) {
        fputs(buf, stdout);
        if (buf[strlen(buf) - 1] == '\n')
            fputs("\r", stdout);
        if (++line >= rows - 1) {
            printf("\033[7m-- more (q to stop, any key) --\033[0m");
            fflush(stdout);
            ch = getchar();
            printf("\r\033[K");
            if (ch == 'q')
                break;
            line = 0;
        }
    }
    fclose(f);
    printf("\033[7m-- end: press any key --\033[0m");
    fflush(stdout);
    getchar();
    printf("\033[2J");
}

/* ---------- file ops ---------- */

static int copy_file(const char *src, const char *dst)
{
    int in, out;
    char buf[65536];
    ssize_t n;

    in = open(src, O_RDONLY);
    if (in < 0)
        return -1;
    out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) {
        close(in);
        return -1;
    }
    while ((n = read(in, buf, sizeof(buf))) > 0) {
        if (write(out, buf, n) != n) {
            n = -1;
            break;
        }
    }
    close(in);
    close(out);
    return n < 0 ? -1 : 0;
}

static void full_path(pane_t *p, const char *name, char *out, size_t len)
{
    snprintf(out, len, "%s/%s", strcmp(p->path, "/") ? p->path : "", name);
}

/* ---------- input ---------- */

static int read_key(void)
{
    int c = getchar();
    if (c != '\033')
        return c;
    c = getchar();
    if (c != '[')
        return c;
    c = getchar();
    switch (c) {
    case 'A': return 'k';       /* up */
    case 'B': return 'j';       /* down */
    case 'C': return 'l';       /* right */
    case 'D': return 'h';       /* left */
    case '5': getchar(); return 'P';    /* PgUp: ESC [ 5 ~ */
    case '6': getchar(); return 'N';    /* PgDn */
    }
    return c;
}

int main(void)
{
    pane_t *p;

    strcpy(panes[0].path, "/");
    strcpy(panes[1].path, "/");
    {
        char *cwd = getcwd(NULL, 0);
        if (cwd != NULL) {
            snprintf(panes[0].path, sizeof(panes[0].path), "%s", cwd);
            free(cwd);
        }
    }

    term_size();
    term_raw();
    atexit(term_restore);
    load_pane(&panes[0]);
    load_pane(&panes[1]);
    printf("\033[2J");

    for (;;) {
        int key, page;

        draw();
        p = &panes[active];
        key = read_key();
        page = rows - 3;
        status[0] = '\0';

        switch (key) {
        case 'q':
            return 0;
        case '\t':
            active = 1 - active;
            break;
        case 'k':
            if (p->sel > 0)
                p->sel--;
            break;
        case 'j':
            if (p->sel < p->count - 1)
                p->sel++;
            break;
        case 'P':
            p->sel -= page;
            if (p->sel < 0)
                p->sel = 0;
            break;
        case 'N':
            p->sel += page;
            if (p->sel >= p->count)
                p->sel = p->count ? p->count - 1 : 0;
            break;
        case 'r':
            load_pane(&panes[0]);
            load_pane(&panes[1]);
            break;
        case 'h': {
            char *slash = strrchr(p->path, '/');
            if (slash != NULL && slash != p->path)
                *slash = '\0';
            else
                strcpy(p->path, "/");
            p->sel = p->top = 0;
            load_pane(p);
            break;
        }
        case '\r':
        case '\n':
        case 'l': {
            entry_t *e;
            char full[1300];
            if (p->count == 0)
                break;
            e = &p->ents[p->sel];
            if (strcmp(e->name, "..") == 0) {
                char *slash = strrchr(p->path, '/');
                if (slash != NULL && slash != p->path)
                    *slash = '\0';
                else
                    strcpy(p->path, "/");
                p->sel = p->top = 0;
                load_pane(p);
                break;
            }
            full_path(p, e->name, full, sizeof(full));
            if (e->is_dir) {
                snprintf(p->path, sizeof(p->path), "%s", full);
                p->sel = p->top = 0;
                load_pane(p);
            } else {
                view_file(full);
            }
            break;
        }
        case 'c':
        case 'm': {
            entry_t *e;
            char src[1300], dst[1300];
            pane_t *other = &panes[1 - active];
            if (p->count == 0)
                break;
            e = &p->ents[p->sel];
            if (e->is_dir) {
                snprintf(status, sizeof(status), "directories not supported for %s",
                         key == 'c' ? "copy" : "move");
                break;
            }
            full_path(p, e->name, src, sizeof(src));
            full_path(other, e->name, dst, sizeof(dst));
            if (strcmp(src, dst) == 0) {
                snprintf(status, sizeof(status), "same path");
                break;
            }
            if (copy_file(src, dst) != 0) {
                snprintf(status, sizeof(status), "%s failed: %s",
                         key == 'c' ? "copy" : "move", strerror(errno));
                break;
            }
            if (key == 'm')
                unlink(src);
            snprintf(status, sizeof(status), "%s %s -> %s",
                     key == 'c' ? "copied" : "moved", e->name, other->path);
            load_pane(other);
            if (key == 'm')
                load_pane(p);
            break;
        }
        case 'D': {
            entry_t *e;
            char full[1300];
            int ch;
            if (p->count == 0)
                break;
            e = &p->ents[p->sel];
            if (e->is_dir) {
                snprintf(status, sizeof(status), "won't delete directories");
                break;
            }
            snprintf(status, sizeof(status), "delete %s? y/N", e->name);
            draw();
            ch = getchar();
            if (ch == 'y' || ch == 'Y') {
                full_path(p, e->name, full, sizeof(full));
                if (unlink(full) == 0)
                    snprintf(status, sizeof(status), "deleted %s", e->name);
                else
                    snprintf(status, sizeof(status), "unlink: %s", strerror(errno));
                load_pane(p);
            } else {
                status[0] = '\0';
            }
            break;
        }
        default:
            break;
        }
    }
}
