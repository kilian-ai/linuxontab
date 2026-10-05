/*
 * lotplay.c — a small video player for the LinuxOnTab X desktop.
 *
 * ffmpeg's libraries decode (libavformat + libavcodec, single-threaded, no
 * asm), libswscale scales each frame straight to the window size in the
 * X server's pixel format, and plain Xlib XPutImage puts it on screen — the
 * core-protocol path xtiny implements (no MIT-SHM, no XVideo). Sound goes
 * to xtiny's sound socket (/tmp/.lot-audio, s16le stereo 48 kHz via
 * libswresample), which forwards it to the browser over the X display's
 * RFB connection; without that socket the video plays silently.
 *
 *   lotplay [-l] [file]      # no file: the bundled sample, looped
 *
 * Keys: Space pause · ←/→ seek 10 s · L loop · Q/Esc quit. A click toggles
 * pause; resizing or maximising the window rescales the picture.
 *
 * Pacing: one clock maps media time to the monotonic clock. Video frames
 * are drawn when due; audio is written A_LEAD ahead of its time, which is
 * the cushion the viewer keeps before playing it, so both arrive together.
 * When decoding falls behind, frames are decoded but not drawn (drawing —
 * scale, PutImage, and the trip to the browser — costs more than
 * decoding), and the deblocking filter is skipped until it catches up.
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
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>

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

/* ── sound out: xtiny's sound socket ──────────────────────────────────────── */
#define AUDIO_SOCK "/tmp/.lot-audio"
#define A_RATE     48000            /* = librfb RFB_AUDIO_RATE, stereo s16le */
/* Audio is sent this far ahead of its time. The viewer holds ~0.10 s
 * (its jitter cushion); the extra 40 ms is how much quicker the picture
 * reaches the screen than sound does (measured with a flash/tick clip:
 * at 0.10 the audio trailed the picture by a median 51 ms). */
#define A_LEAD     0.14
#define A_AHEAD    0.50             /* keep this much decoded audio queued */

static int afd = -1;
static double a_last_try;           /* reconnect throttle — only after failures */
static uint8_t *aq;                 /* queued PCM bytes, aq[head..len) unsent */
static size_t aq_len, aq_head, aq_cap;
static double aq_t0;                /* media time of aq[0] */

static double aq_time(size_t off) { return aq_t0 + (double)(off / 4) / A_RATE; }

static void aq_clear(void) { aq_len = aq_head = 0; }

static void aq_push(const uint8_t *pcm, size_t n, double t) {
    if (aq_head == aq_len) { aq_len = aq_head = 0; aq_t0 = t; }   /* re-anchor when empty */
    size_t shift = aq_head & ~(size_t)3;                         /* compact by whole frames */
    if (shift > 65536) {
        memmove(aq, aq + shift, aq_len - shift);
        aq_t0 += (double)(shift / 4) / A_RATE;
        aq_len -= shift; aq_head -= shift;
    }
    if (aq_len + n > aq_cap) {
        size_t nc = aq_cap ? aq_cap : 262144;
        while (nc < aq_len + n) nc *= 2;
        uint8_t *na = realloc(aq, nc);
        if (!na) return;
        aq = na; aq_cap = nc;
    }
    memcpy(aq + aq_len, pcm, n);
    aq_len += n;
}

/* Closing the socket ends the stream: xtiny tells the viewer to drop what
 * it still has queued (pause, seek, loop). */
static void audio_close(void) {
    if (afd >= 0) close(afd);
    afd = -1;
    a_last_try = 0;                 /* a deliberate close reconnects at once */
}

static void audio_open(void) {
    double t = now_s();
    if (afd >= 0 || (a_last_try && t - a_last_try < 2)) return;
    a_last_try = t;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, AUDIO_SOCK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) { close(fd); return; }
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    afd = fd;
}

/* Send the queued audio that is due by media time `upto`; anything older
 * than `stale` (a stall, or no sound server) is dropped, not sent late. */
static void audio_pump(double upto, double stale) {
    size_t lim = aq_len;
    double span = upto - aq_t0;
    if (span < 0) lim = 0;
    else if ((size_t)(span * A_RATE) * 4 < aq_len) lim = (size_t)(span * A_RATE) * 4;
    if (lim <= aq_head) return;
    if (aq_time(aq_head) < stale) {                      /* skip what's too late */
        size_t skip = (size_t)((stale - aq_t0) * A_RATE) * 4;
        if (skip > lim) skip = lim;
        if (skip > aq_head) aq_head = skip;
        if (lim <= aq_head) return;
    }
    audio_open();
    if (afd < 0) { aq_head = lim; return; }              /* silent playback */
    ssize_t w = send(afd, aq + aq_head, lim - aq_head, MSG_NOSIGNAL);
    if (w > 0) aq_head += (size_t)w;
    else if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) audio_close();
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

    /* video */
    const AVCodec *vcodec = NULL;
    int vs = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &vcodec, 0);
    AVCodecContext *vdec = NULL;
    if (vs >= 0 && vcodec) {
        vdec = avcodec_alloc_context3(vcodec);
        avcodec_parameters_to_context(vdec, fmt->streams[vs]->codecpar);
        vdec->thread_count = 1;
        vdec->flags2 |= AV_CODEC_FLAG2_FAST;
        if (avcodec_open2(vdec, vcodec, NULL) < 0) { avcodec_free_context(&vdec); vs = -1; }
    } else vs = -1;

    /* audio → s16 stereo 48 kHz */
    const AVCodec *acodec = NULL;
    int as = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, vs, &acodec, 0);
    AVCodecContext *adec = NULL;
    SwrContext *swr = NULL;
    if (as >= 0 && acodec) {
        adec = avcodec_alloc_context3(acodec);
        avcodec_parameters_to_context(adec, fmt->streams[as]->codecpar);
        adec->thread_count = 1;
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        if (avcodec_open2(adec, acodec, NULL) < 0 ||
            swr_alloc_set_opts2(&swr, &stereo, AV_SAMPLE_FMT_S16, A_RATE,
                                &adec->ch_layout, adec->sample_fmt, adec->sample_rate, 0, NULL) < 0 ||
            swr_init(swr) < 0) {
            avcodec_free_context(&adec); swr_free(&swr); as = -1;
        }
    } else as = -1;

    if (vs < 0 && as < 0) {
        fprintf(stderr, "lotplay: nothing playable in %s\n", path);
        return 1;
    }
    for (unsigned i = 0; i < fmt->nb_streams; i++)
        if ((int)i != vs && (int)i != as) fmt->streams[i]->discard = AVDISCARD_ALL;
    double vtb = vs >= 0 ? av_q2d(fmt->streams[vs]->time_base) : 0;
    double atb = as >= 0 ? av_q2d(fmt->streams[as]->time_base) : 0;
    double dur = fmt->duration > 0 ? fmt->duration / (double)AV_TIME_BASE : 0;
    int vw = vdec ? vdec->width : 480, vh = vdec ? vdec->height : 270;
    printf("lotplay: %s — %s %dx%d%s%s, %.1f s\n", path,
           vdec ? vcodec->name : "no video", vw, vh,
           adec ? ", audio " : "", adec ? acodec->name : "", dur);
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

    AVPacket *pkt = av_packet_alloc(), *held = av_packet_alloc();
    AVFrame *frm = av_frame_alloc(), *afrm = av_frame_alloc();
    struct SwsContext *sws = NULL;
    uint8_t *apcm = NULL; int apcm_cap = 0;

    int paused = 0, quit = 0, finished = 0;
    int vready = 0, have_held = 0, demux_eof = 0, drain_sent = 0;
    int v_eof = vs < 0, a_eof = as < 0;
    double vpts = 0, pos = 0;
    double clock0 = -1, pts0 = 0;          /* wall time ↔ media time anchor */
    double osd_until = 0, pause_at = 0, last_osd = 0;
    int shown = 0, dropped = 0;
    double stat_t = now_s();

#define MEDIA_NOW(t) (clock0 < 0 ? pts0 : (t) - clock0 + pts0)
#define RESTART(to) do {                                                    \
        av_seek_frame(fmt, vs >= 0 ? vs : as, (int64_t)((to) / (vs >= 0 ? vtb : atb)), \
                      AVSEEK_FLAG_BACKWARD);                                \
        if (vdec) avcodec_flush_buffers(vdec);                              \
        if (adec) avcodec_flush_buffers(adec);                              \
        if (swr) swr_init(swr);                                             \
        aq_clear(); audio_close();                                          \
        av_packet_unref(held); have_held = 0;                               \
        vready = 0; demux_eof = 0; drain_sent = 0;                          \
        v_eof = vs < 0; a_eof = as < 0; finished = 0;                       \
        clock0 = -1;                                                        \
    } while (0)

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
                if (paused) { pause_at = now_s(); audio_close(); }
                else if (clock0 >= 0) clock0 += now_s() - pause_at;
                osd_until = now_s() + 2;
                redraw = 1;
            } else if (ev.type == KeyPress) {
                KeySym k = XLookupKeysym(&ev.xkey, 0);
                double seek = 0;
                if (k == XK_q || k == XK_Escape) quit = 1;
                else if (k == XK_space) {
                    paused = !paused;
                    if (paused) { pause_at = now_s(); audio_close(); }
                    else if (clock0 >= 0) clock0 += now_s() - pause_at;
                } else if (k == XK_Left)  seek = -10;
                else if (k == XK_Right) seek = 10;
                else if (k == XK_l || k == XK_L) loop = !loop;
                if (seek) {
                    double t = pos + seek;
                    if (t < 0) t = 0;
                    if (dur > 0 && t > dur - 1) t = dur - 1;
                    RESTART(t);
                }
                osd_until = now_s() + 2;
                redraw = 1;
            }
        }
        if (quit) break;
        if (redraw && (paused || finished || vs < 0)) {
            /* repaint the last picture (letterbox or OSD changed) */
            memset(pix, 0, (size_t)ww * wh * 4);
            if (sws && frm->data[0]) {
                sws = sws_getCachedContext(sws, vw, vh, frm->format, dw, dh,
                                           AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, NULL, NULL, NULL);
                uint8_t *dst[4] = { pix + ((size_t)dy * ww + dx) * 4 };
                int dls[4] = { ww * 4 };
                sws_scale(sws, (const uint8_t * const *)frm->data, frm->linesize, 0, vh, dst, dls);
            }
            if (paused || vs < 0 || now_s() < osd_until) draw_osd(pos, dur, paused);
            put_all();
        }
        if (paused || finished) { usleep(30000); continue; }

        /* ── keep the decoders fed: one video frame ready, A_AHEAD of audio ── */
        for (int iter = 0; iter < 32; iter++) {
            double mnow = MEDIA_NOW(now_s());
            int need_v = vs >= 0 && !vready && !v_eof;
            int need_a = as >= 0 && !a_eof && aq_time(aq_len) - mnow < A_AHEAD;
            if (!need_v && !need_a) break;
            if (need_v) {
                int r = avcodec_receive_frame(vdec, frm);
                if (r == 0) {
                    int64_t ts = frm->best_effort_timestamp != AV_NOPTS_VALUE ? frm->best_effort_timestamp : frm->pts;
                    vpts = ts != AV_NOPTS_VALUE ? ts * vtb : vpts + 1.0 / 25;
                    vready = 1;
                    continue;
                }
                if (r == AVERROR_EOF) { v_eof = 1; continue; }
            }
            if (have_held) {                  /* a video packet the decoder refused */
                if (avcodec_send_packet(vdec, held) == AVERROR(EAGAIN)) break;
                av_packet_unref(held); have_held = 0;
                continue;
            }
            if (demux_eof) {
                if (!drain_sent) {
                    if (vdec) avcodec_send_packet(vdec, NULL);
                    if (adec) avcodec_send_packet(adec, NULL);
                    drain_sent = 1;
                }
                if (as >= 0 && !a_eof) {      /* drain the audio decoder */
                    int r;
                    while ((r = avcodec_receive_frame(adec, afrm)) == 0) {
                        int maxo = swr_get_out_samples(swr, afrm->nb_samples);
                        if (maxo * 4 > apcm_cap) { apcm_cap = maxo * 4; apcm = realloc(apcm, apcm_cap); }
                        uint8_t *o[1] = { apcm };
                        int n = swr_convert(swr, o, maxo, (const uint8_t **)afrm->extended_data, afrm->nb_samples);
                        if (n > 0) aq_push(apcm, (size_t)n * 4, aq_time(aq_len));
                    }
                    a_eof = 1;
                }
                if (vs >= 0 && !v_eof && !need_v) break;
                if (vs < 0 || v_eof) break;
                continue;
            }
            if (av_read_frame(fmt, pkt) < 0) { demux_eof = 1; continue; }
            if (pkt->stream_index == vs) {
                if (avcodec_send_packet(vdec, pkt) == AVERROR(EAGAIN)) {
                    av_packet_move_ref(held, pkt); have_held = 1;
                }
            } else if (pkt->stream_index == as) {
                if (avcodec_send_packet(adec, pkt) == 0) {
                    while (avcodec_receive_frame(adec, afrm) == 0) {
                        int64_t ts = afrm->best_effort_timestamp;
                        double t = ts != AV_NOPTS_VALUE ? ts * atb : aq_time(aq_len);
                        int maxo = swr_get_out_samples(swr, afrm->nb_samples);
                        if (maxo * 4 > apcm_cap) { apcm_cap = maxo * 4; apcm = realloc(apcm, apcm_cap); }
                        uint8_t *o[1] = { apcm };
                        int n = swr_convert(swr, o, maxo, (const uint8_t **)afrm->extended_data, afrm->nb_samples);
                        if (n > 0) aq_push(apcm, (size_t)n * 4, t);
                    }
                }
            }
            av_packet_unref(pkt);
        }

        /* ── clock ── */
        double t = now_s();
        if (clock0 < 0 && (vready || aq_len > aq_head)) {
            pts0 = vready ? vpts : aq_time(aq_head);
            if (vready && aq_len > aq_head && aq_time(aq_head) < pts0) pts0 = aq_time(aq_head);
            clock0 = t + 0.05;               /* a moment for the first sends */
        }
        double mnow = MEDIA_NOW(t);
        if (as >= 0) audio_pump(mnow + A_LEAD, mnow - 0.2);
        if (vs < 0) {
            pos = mnow;
            if (t - last_osd > 0.5) {         /* audio only: a moving progress bar */
                last_osd = t;
                memset(pix, 0, (size_t)ww * wh * 4);
                draw_osd(pos, dur, 0);
                put_all();
            }
        }

        /* ── video ── */
        if (vready) {
            double due = clock0 + (vpts - pts0);
            double late = t - due;
            if (late >= -0.003) {
                pos = vpts;
                /* Behind by more than a few frames: skip drawing; far behind:
                 * also skip the loop filter (cheap decode, blockier picture). */
                vdec->skip_loop_filter = late > 0.25 ? AVDISCARD_ALL : AVDISCARD_DEFAULT;
                if (late > 0.08) {
                    dropped++;
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
                vready = 0;
                if (late > 1.5) clock0 += late - 0.1;   /* hopelessly behind: re-anchor */
                usleep(1000);   /* still yield: the asyncify scheduler needs it */
                continue;
            }
        }

        /* ── end of stream ── */
        if (!vready && v_eof && a_eof && aq_head >= aq_len) {
            if (loop) RESTART(0);
            else finished = 1;
            continue;
        }

        double ns = now_s();
        if (ns - stat_t >= 5) {
            printf("lotplay: %.1f fps shown, %.1f dropped/s (%dx%d, k=%d)%s\n",
                   shown / (ns - stat_t), dropped / (ns - stat_t), dw, dh, put_k,
                   as < 0 ? "" : afd >= 0 ? ", sound on" : ", no sound server");
            fflush(stdout);
            shown = dropped = 0;
            stat_t = ns;
        }

        /* ── sleep until the next frame is due, in short slices for audio ── */
        double wait = 0.01;
        if (vready) {
            double until = clock0 + (vpts - pts0) - ns;
            if (until < wait) wait = until;
        }
        if (wait > 0.001) usleep((useconds_t)(wait * 1e6));
        else usleep(500);
    }

    audio_close();
    sws_freeContext(sws);
    swr_free(&swr);
    av_frame_free(&frm);
    av_frame_free(&afrm);
    av_packet_free(&pkt);
    av_packet_free(&held);
    if (vdec) avcodec_free_context(&vdec);
    if (adec) avcodec_free_context(&adec);
    avformat_close_input(&fmt);
    XCloseDisplay(dpy);
    return 0;
}
