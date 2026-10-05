/*
 * lotplay.c — a small video player for the LinuxOnTab X desktop.
 *
 * ffmpeg's libraries decode (libavformat + libavcodec, single-threaded, no
 * asm), libswscale scales each frame straight to the window size in the
 * X server's pixel format, and plain Xlib XPutImage puts it on screen — the
 * core-protocol path xtiny implements (no MIT-SHM, no XVideo). Video only:
 * the page has no audio device yet.
 *
 *   lotplay [-l] [file]      # no file: the bundled sample, looped
 *
 * Keys: Space pause · ←/→ seek 10 s · L loop · Q/Esc quit. A click toggles
 * pause; resizing or maximising the window rescales the picture.
 *
 * Pacing follows the stream's timestamps against a monotonic clock. When
 * decoding falls behind, frames are decoded but not drawn (drawing — scale,
 * PutImage, and the trip to the browser — costs more than decoding), and
 * the deblocking filter is skipped until it catches up.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>

#define SAMPLE "/usr/local/share/lotplay/sample.mp4"
#define MAX_W  800          /* initial window: video size, capped */
#define MAX_H  520

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ── X window ───────────────────────────────────────────────────────────── */
static Display *dpy;
static Window win;
static GC gc;
static Atom wm_delete;
static XImage *img;
/* ww*wh*4: B,G,R,A bytes = X pixel 0x00RRGGBB (the server ignores A).
 * BGRA, not BGR0: swscale maps BGR0 to BGRA internally, so a BGR0 target
 * never matches sws_getCachedContext and rebuilt the scaler every frame. */
static uint8_t *pix;
static int ww, wh;                 /* image size (window size / put_k) */
static int dx, dy, dw, dh;         /* picture rect inside it (letterboxed) */
static int put_k = 1;              /* xtiny _LOT_PUTIMAGE_SCALE in effect */
static int is_xtiny;               /* server understands it */
static Atom a_scale;

static void layout(int vw, int vh) {
    /* fit the picture, keep its aspect, even sizes for the scaler */
    double s = (double)ww / vw;
    if (vh * s > wh) s = (double)wh / vh;
    dw = ((int)(vw * s)) & ~1;
    dh = ((int)(vh * s)) & ~1;
    if (dw < 2) dw = 2;
    if (dh < 2) dh = 2;
    dx = (ww - dw) / 2;
    dy = (wh - dh) / 2;
}

/* On xtiny a big window is drawn at 1/k size and expanded by the server
 * (_LOT_PUTIMAGE_SCALE): pick k so the picture is about the video's own
 * size and never more than ~420k pixels per frame through the socket. */
static int pick_k(int w, int h, int vw, int vh) {
    if (!is_xtiny) return 1;
    int k = 1;
    int kr = w / vw < h / vh ? w / vw : h / vh;    /* window ≥ k× the video */
    if (kr > k) k = kr;
    while ((long)(w / k) * (h / k) > 420000) k++;
    return k > 4 ? 4 : k;
}

static void alloc_image(int w, int h, int vw, int vh) {
    if (img) { img->data = NULL; XDestroyImage(img); img = NULL; }
    free(pix);
    int k = pick_k(w, h, vw, vh);
    if (k != put_k || is_xtiny) {
        long kv = k;
        XChangeProperty(dpy, win, a_scale, XA_CARDINAL, 32, PropModeReplace,
                        (unsigned char *)&kv, 1);
        put_k = k;
    }
    w = (w + k - 1) / k;
    h = (h + k - 1) / k;
    ww = w; wh = h;
    pix = calloc((size_t)ww * wh, 4);           /* black bars */
    img = XCreateImage(dpy, DefaultVisual(dpy, DefaultScreen(dpy)), 24, ZPixmap, 0,
                       (char *)pix, ww, wh, 32, ww * 4);
    layout(vw, vh);
}

static void put_all(void) {
    XPutImage(dpy, win, gc, img, 0, 0, 0, 0, ww, wh);
    XFlush(dpy);
}

/* On-screen progress strip (paused, or for a moment after a key). */
static void draw_osd(double pos, double dur, int paused) {
    int bh = 4, y = dy + dh - 14;
    if (dh < 40) return;
    for (int j = y - 6; j < dy + dh; j++)                     /* darken */
        for (int i = dx; i < dx + dw; i++) {
            uint8_t *p = pix + ((size_t)j * ww + i) * 4;
            p[0] = p[0] * 2 / 5; p[1] = p[1] * 2 / 5; p[2] = p[2] * 2 / 5;
        }
    int x0 = dx + 12, x1 = dx + dw - 12;
    int fill = dur > 0 ? x0 + (int)((x1 - x0) * (pos / dur)) : x0;
    for (int j = y; j < y + bh; j++)
        for (int i = x0; i < x1; i++) {
            uint8_t *p = pix + ((size_t)j * ww + i) * 4;
            if (i < fill) { p[0] = 0xFF; p[1] = 0xA2; p[2] = 0x5E; }   /* accent */
            else          { p[0] = 0x70; p[1] = 0x70; p[2] = 0x70; }
        }
    if (paused) {                                              /* ❚❚ */
        int cx = dx + dw / 2, cy = dy + dh / 2;
        for (int j = cy - 16; j < cy + 16; j++)
            for (int i = cx - 14; i < cx + 14; i++) {
                if (i > cx - 4 && i < cx + 4) continue;
                uint8_t *p = pix + ((size_t)j * ww + i) * 4;
                p[0] = p[1] = p[2] = 0xF0;
            }
    }
}

/* ── main ───────────────────────────────────────────────────────────────── */
int main(int argc, char **argv) {
    const char *path = NULL;
    int loop = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-l")) loop = 1;
        else if (argv[i][0] == '-') {
            fprintf(stderr, "usage: lotplay [-l] [file]\n");
            return 2;
        } else path = argv[i];
    }
    if (!path) { path = SAMPLE; loop = 1; }
    if (!getenv("DISPLAY")) setenv("DISPLAY", ":1", 1);
    av_log_set_level(AV_LOG_ERROR);

    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) {
        fprintf(stderr, "lotplay: cannot open %s\n", path);
        return 1;
    }
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        fprintf(stderr, "lotplay: no stream info in %s\n", path);
        return 1;
    }
    const AVCodec *codec = NULL;
    int vs = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (vs < 0 || !codec) {
        fprintf(stderr, "lotplay: no decodable video stream in %s\n", path);
        return 1;
    }
    AVStream *st = fmt->streams[vs];
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(dec, st->codecpar);
    dec->thread_count = 1;
    dec->flags2 |= AV_CODEC_FLAG2_FAST;
    if (avcodec_open2(dec, codec, NULL) < 0) {
        fprintf(stderr, "lotplay: cannot open the %s decoder\n", codec->name);
        return 1;
    }
    for (unsigned i = 0; i < fmt->nb_streams; i++)            /* demux video only */
        if ((int)i != vs) fmt->streams[i]->discard = AVDISCARD_ALL;
    double tb = av_q2d(st->time_base);
    double dur = fmt->duration > 0 ? fmt->duration / (double)AV_TIME_BASE : 0;
    int vw = dec->width, vh = dec->height;
    printf("lotplay: %s — %s %dx%d, %.1f s\n", path, codec->name, vw, vh, dur);
    fflush(stdout);

    dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "lotplay: cannot open display %s\n", getenv("DISPLAY")); return 1; }
    int w0 = vw, h0 = vh;
    if (w0 > MAX_W) { h0 = h0 * MAX_W / w0; w0 = MAX_W; }
    if (h0 > MAX_H) { w0 = w0 * MAX_H / h0; h0 = MAX_H; }
    int scr = DefaultScreen(dpy);
    win = XCreateSimpleWindow(dpy, RootWindow(dpy, scr), 0, 0, w0, h0, 0,
                              BlackPixel(dpy, scr), BlackPixel(dpy, scr));
    const char *base = strrchr(path, '/');
    char title[160];
    snprintf(title, sizeof title, "Videos - %s", base ? base + 1 : path);   /* WM_NAME is Latin-1 */
    XStoreName(dpy, win, title);
    wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    is_xtiny = strstr(ServerVendor(dpy), "xtiny") != NULL;
    a_scale = XInternAtom(dpy, "_LOT_PUTIMAGE_SCALE", False);
    XSetWMProtocols(dpy, win, &wm_delete, 1);
    XSelectInput(dpy, win, KeyPressMask | ButtonPressMask | StructureNotifyMask | ExposureMask);
    gc = XCreateGC(dpy, win, 0, NULL);
    XMapWindow(dpy, win);
    int win_w = w0, win_h = h0;
    alloc_image(w0, h0, vw, vh);

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frm = av_frame_alloc();
    struct SwsContext *sws = NULL;

    int paused = 0, quit = 0, eof = 0;
    double clock0 = -1, pts0 = 0, pos = 0;   /* wall time of pts0 */
    double osd_until = 0, pause_at = 0;
    int shown = 0, dropped = 0;
    double stat_t = now_s();

    while (!quit) {
        /* ── events ── */
        int redraw = 0;
        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);
            if (ev.type == ConfigureNotify &&
                (ev.xconfigure.width != win_w || ev.xconfigure.height != win_h)) {
                win_w = ev.xconfigure.width; win_h = ev.xconfigure.height;
                alloc_image(ev.xconfigure.width, ev.xconfigure.height, vw, vh);
                /* Paint the bars now: frames already queued at the old size
                 * landed top-left of the grown window, and while playing
                 * only the picture rect is redrawn. */
                put_all();
                redraw = 1;
            } else if (ev.type == Expose) {
                redraw = 1;
            } else if (ev.type == ClientMessage && (Atom)ev.xclient.data.l[0] == wm_delete) {
                quit = 1;
            } else if (ev.type == ButtonPress && ev.xbutton.button == 1) {
                paused = !paused;
                if (paused) pause_at = now_s();
                else if (clock0 >= 0) clock0 += now_s() - pause_at;
                osd_until = now_s() + 2;
                redraw = 1;
            } else if (ev.type == KeyPress) {
                KeySym k = XLookupKeysym(&ev.xkey, 0);
                double seek = 0;
                if (k == XK_q || k == XK_Escape) quit = 1;
                else if (k == XK_space) {
                    paused = !paused;
                    if (paused) pause_at = now_s();
                    else if (clock0 >= 0) clock0 += now_s() - pause_at;
                } else if (k == XK_Left)  seek = -10;
                else if (k == XK_Right) seek = 10;
                else if (k == XK_l || k == XK_L) loop = !loop;
                if (seek) {
                    double t = pos + seek;
                    if (t < 0) t = 0;
                    if (dur > 0 && t > dur - 1) t = dur - 1;
                    av_seek_frame(fmt, vs, (int64_t)(t / tb), AVSEEK_FLAG_BACKWARD);
                    avcodec_flush_buffers(dec);
                    clock0 = -1; eof = 0;
                }
                osd_until = now_s() + 2;
                redraw = 1;
            }
        }
        if (quit) break;
        if (redraw && (paused || eof)) {
            /* repaint the last picture (letterbox or OSD changed) */
            if (sws && frm->data[0]) {
                memset(pix, 0, (size_t)ww * wh * 4);
                sws = sws_getCachedContext(sws, vw, vh, frm->format, dw, dh,
                                           AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, NULL, NULL, NULL);
                uint8_t *dst[4] = { pix + ((size_t)dy * ww + dx) * 4 };
                int dls[4] = { ww * 4 };
                sws_scale(sws, (const uint8_t * const *)frm->data, frm->linesize, 0, vh, dst, dls);
                if (paused || now_s() < osd_until) draw_osd(pos, dur, paused);
            }
            put_all();
        }
        if (paused || eof) { usleep(30000); continue; }

        /* ── decode one frame ── */
        int got = 0;
        while (!got && !eof) {
            int r = avcodec_receive_frame(dec, frm);
            if (r == 0) { got = 1; break; }
            if (r == AVERROR_EOF) {
                if (loop) {
                    av_seek_frame(fmt, vs, 0, AVSEEK_FLAG_BACKWARD);
                    avcodec_flush_buffers(dec);
                    clock0 = -1;
                    continue;
                }
                eof = 1;
                break;
            }
            if (r != AVERROR(EAGAIN)) { eof = 1; break; }
            r = av_read_frame(fmt, pkt);
            if (r < 0) {
                avcodec_send_packet(dec, NULL);             /* drain */
                continue;
            }
            if (pkt->stream_index == vs) avcodec_send_packet(dec, pkt);
            av_packet_unref(pkt);
        }
        if (!got) continue;

        /* ── pace ── */
        int64_t ts = frm->best_effort_timestamp != AV_NOPTS_VALUE ? frm->best_effort_timestamp : frm->pts;
        double pts = ts != AV_NOPTS_VALUE ? ts * tb : pos;
        pos = pts;
        double t = now_s();
        if (clock0 < 0) { clock0 = t; pts0 = pts; }
        double due = clock0 + (pts - pts0);
        double late = t - due;
        if (late < -0.002) {
            /* early: sleep in slices so key presses stay responsive */
            double wait = -late;
            if (wait > 0.5) wait = 0.5;
            usleep((useconds_t)(wait * 1e6));
            late = 0;
        }
        /* Behind by more than a few frames: skip drawing; far behind: also
         * skip the loop filter (cheap decode, slightly blockier picture). */
        dec->skip_loop_filter = late > 0.25 ? AVDISCARD_ALL : AVDISCARD_DEFAULT;
        if (late > 0.08) {
            dropped++;
            usleep(1000);   /* still yield: the asyncify scheduler needs it */
        } else {
            sws = sws_getCachedContext(sws, vw, vh, frm->format, dw, dh,
                                       AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, NULL, NULL, NULL);
            uint8_t *dst[4] = { pix + ((size_t)dy * ww + dx) * 4 };
            int dls[4] = { ww * 4 };
            sws_scale(sws, (const uint8_t * const *)frm->data, frm->linesize, 0, vh, dst, dls);
            if (now_s() < osd_until) draw_osd(pos, dur, 0);
            XPutImage(dpy, win, gc, img, dx, dy, dx, dy, dw, dh);
            XFlush(dpy);
            shown++;
        }
        if (late > 1.5) clock0 += late - 0.1;    /* hopelessly behind: re-anchor */

        double ns = now_s();
        if (ns - stat_t >= 5) {
            printf("lotplay: %.1f fps shown, %.1f dropped/s (%dx%d, k=%d)\n",
                   shown / (ns - stat_t), dropped / (ns - stat_t), dw, dh, put_k);
            fflush(stdout);
            shown = dropped = 0;
            stat_t = ns;
        }
    }

    sws_freeContext(sws);
    av_frame_free(&frm);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    XCloseDisplay(dpy);
    return 0;
}
