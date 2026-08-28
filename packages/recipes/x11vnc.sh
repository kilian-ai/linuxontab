#!/bin/sh
# Recipe: x11vnc — minimal X11→VNC bridge
# Captures an X display (Xvfb) via XGetImage and serves RFB 3.8 on port 5900.
# Mouse/keyboard forwarded to X via XWarpPointer + XSendEvent.
# No libjpeg/libpng required — RAW encoding only.

NAME="x11vnc"
VERSION="1.0.0"
DESCRIPTION="Minimal X11-to-VNC bridge (RAW RFB 3.8)"
# x11vnc captures an X display, so it needs the Xvfb server running.
DEPENDS="xvfb"
# Source is embedded in build() — we use xorgproto as a placeholder archive
SOURCE_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-2024.1/xorgproto-xorgproto-2024.1.tar.gz"
SOURCE_SHA256=""

build() {
    # ── dependency check ────────────────────────────────────────────────────
    for dep in libX11 libXext libXfixes; do
        ls /tmp/lot-build/$dep/stage/usr/lib/*.a >/dev/null 2>&1 || {
            echo "Missing /tmp/lot-build/$dep. Run ./packages/build-package.sh $dep first." >&2
            exit 1
        }
    done

    DEPS_PREFIX="/tmp/lot-build/x11vnc-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
    for dep in libX11 libXext libXfixes libXdamage libXrandr libXau libxcb; do
        if ls /tmp/lot-build/$dep/stage/usr/lib/*.a >/dev/null 2>&1; then
            cp -Rn /tmp/lot-build/$dep/stage/usr/include/* "$DEPS_PREFIX/include/" 2>/dev/null || true
            cp -f /tmp/lot-build/$dep/stage/usr/lib/*.a "$DEPS_PREFIX/lib/" 2>/dev/null || true
        fi
    done

    # ── write x11vnc.c ──────────────────────────────────────────────────────
    # ($SRC was populated from xorgproto tarball as placeholder; we write our
    #  own source file here which is all that gets compiled)
    cat > "$SRC/x11vnc.c" << 'CSRC'
/*
 * x11vnc.c — minimal X11-to-VNC bridge
 * RFB 3.8, Security Type = None, RAW encoding, one client at a time.
 * Uses XGetImage (ZPixmap) for framebuffer capture.
 * Forwards PointerEvent via XWarpPointer + XSendEvent (ButtonPress/Release).
 * Forwards KeyEvent via XSendEvent KeyPress/KeyRelease on root window.
 *
 * Usage: x11vnc [-display :N] [-port P] [-rate Hz]
 * Default: DISPLAY env var, port 5900, 10 fps
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>

/* ── libX11 i18n stubs (only referenced by locale conversion code, unused here) */
long _Xi18n_lock[8];    /* pthread_mutex_t placeholder */
long _conv_lock[8];     /* pthread_mutex_t placeholder */
Bool _XrmInitParseInfo(XPointer *state) { (void)state; return False; }

/* ── wire helpers ──────────────────────────────────────────────────────────── */
static int write_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n) {
        ssize_t r = write(fd, p, n);
        if (r <= 0) { if (errno == EINTR) continue; return 0; }
        p += r; n -= r;
    }
    return 1;
}
static int read_all(int fd, void *buf, size_t n) {
    char *p = buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r == 0) return 0;
        if (r < 0) { if (errno == EINTR) continue; return 0; }
        p += r; n -= r;
    }
    return 1;
}
static uint16_t hton16(uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v>>8), (uint8_t)(v) };
    uint16_t r; memcpy(&r, b, 2); return r;
}
static uint32_t hton32(uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v>>24),(uint8_t)(v>>16),(uint8_t)(v>>8),(uint8_t)(v) };
    uint32_t r; memcpy(&r, b, 4); return r;
}
static uint16_t ntoh16(const uint8_t *p) { return ((uint16_t)p[0]<<8)|p[1]; }
static uint32_t ntoh32(const uint8_t *p) {
    return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
}

/* ── RFB handshake & ServerInit ─────────────────────────────────────────────
 *
 * PixelFormat we advertise: 32bpp, 24 depth, bigendian=0, truecolour=1
 * Red  max=255  shift=16  (X11 ZPixmap on little-endian: BGRA → byte order B G R A)
 * Green max=255 shift=8
 * Blue  max=255 shift=0
 */
static int rfb_handshake(int fd, int w, int h, const char *name) {
    /* Version */
    if (!write_all(fd, "RFB 003.008\n", 12)) return 0;
    char ver[13]; ver[12]=0;
    if (!read_all(fd, ver, 12)) return 0;

    /* Security types: 1 type = None (1) */
    uint8_t stypes[2] = { 1, 1 }; /* count=1, type=None */
    if (!write_all(fd, stypes, 2)) return 0;
    uint8_t chosen;
    if (!read_all(fd, &chosen, 1)) return 0;
    if (chosen != 1) { fprintf(stderr, "[x11vnc] client chose auth %u\n", chosen); return 0; }

    /* SecurityResult: OK */
    uint32_t secres = 0;
    if (!write_all(fd, &secres, 4)) return 0;

    /* ClientInit */
    uint8_t shared;
    if (!read_all(fd, &shared, 1)) return 0;

    /* ServerInit: width(2) height(2) pixelformat(16) namelen(4) name */
    uint8_t si[24 + 256];
    int off = 0;
    /* width, height */
    uint16_t W = hton16((uint16_t)w), H = hton16((uint16_t)h);
    memcpy(si+off, &W, 2); off+=2;
    memcpy(si+off, &H, 2); off+=2;
    /* PixelFormat (16 bytes):
     * bits-per-pixel(1) depth(1) big-endian(1) true-colour(1)
     * red-max(2) green-max(2) blue-max(2)
     * red-shift(1) green-shift(1) blue-shift(1) padding(3) */
    si[off++] = 32;  /* bpp */
    si[off++] = 24;  /* depth */
    si[off++] = 0;   /* little-endian */
    si[off++] = 1;   /* true colour */
    uint16_t rmax=hton16(255), gmax=hton16(255), bmax=hton16(255);
    memcpy(si+off,&rmax,2); off+=2;
    memcpy(si+off,&gmax,2); off+=2;
    memcpy(si+off,&bmax,2); off+=2;
    si[off++] = 16;  /* red-shift   (BGRA: R is byte [2]) */
    si[off++] = 8;   /* green-shift */
    si[off++] = 0;   /* blue-shift  */
    si[off++] = 0; si[off++] = 0; si[off++] = 0; /* padding */
    /* name */
    uint32_t nlen = hton32((uint32_t)strlen(name));
    memcpy(si+off, &nlen, 4); off+=4;
    memcpy(si+off, name, strlen(name)); off += strlen(name);
    return write_all(fd, si, off);
}

/* ── capture & send a sub-rectangle ─────────────────────────────────────── */
static int send_rect(int fd, Display *dpy, Window root,
                     int x, int y, int w, int h) {
    XImage *img = XGetImage(dpy, root, x, y, w, h, AllPlanes, ZPixmap);
    if (!img) { fprintf(stderr, "[x11vnc] XGetImage failed\n"); return 0; }

    /* FramebufferUpdate header: type=0 padding(1) nrects(2) */
    uint8_t hdr[4] = { 0, 0, 0, 1 };
    if (!write_all(fd, hdr, 4)) { XDestroyImage(img); return 0; }

    /* Rectangle header: x(2) y(2) w(2) h(2) encoding(4=RAW=0) */
    uint8_t rhdr[12];
    uint16_t rx=hton16((uint16_t)x), ry=hton16((uint16_t)y),
             rw=hton16((uint16_t)w), rh=hton16((uint16_t)h);
    memcpy(rhdr+0,&rx,2); memcpy(rhdr+2,&ry,2);
    memcpy(rhdr+4,&rw,2); memcpy(rhdr+6,&rh,2);
    uint32_t enc=0; memcpy(rhdr+8,&enc,4);
    if (!write_all(fd, rhdr, 12)) { XDestroyImage(img); return 0; }

    /* Pixel data: img->data is BGRA 32-bit (wasm32 little-endian) */
    /* VNC client expects our advertised format: 32bpp, R-shift=16, G-shift=8, B-shift=0 → BGRA */
    int ret = write_all(fd, img->data, w * h * 4);
    XDestroyImage(img);
    return ret;
}

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(int argc, char *argv[]) {
    const char *disp_name = NULL;
    int port = 5900;
    int rate_hz = 10;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-display") && i+1 < argc) disp_name = argv[++i];
        else if (!strcmp(argv[i], "-port") && i+1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-rate") && i+1 < argc) rate_hz = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("Usage: x11vnc [-display :N] [-port P] [-rate Hz]\n"); return 0;
        }
    }

    Display *dpy = XOpenDisplay(disp_name);
    if (!dpy) {
        fprintf(stderr, "[x11vnc] cannot open display %s\n",
                disp_name ? disp_name : "(default)");
        return 1;
    }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    int fb_w = DisplayWidth(dpy, screen);
    int fb_h = DisplayHeight(dpy, screen);

    fprintf(stderr, "[x11vnc] display %s: %dx%d, serving VNC on :%d\n",
            DisplayString(dpy), fb_w, fb_h, port);

    /* ── listen socket ──────────────────────────────────────────────────── */
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); XCloseDisplay(dpy); return 1; }
    int optval = 1; setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = htons((uint16_t)port);
    if (bind(srv, (struct sockaddr*)&sa, sizeof(sa)) < 0) {
        perror("bind"); XCloseDisplay(dpy); return 1;
    }
    listen(srv, 4);
    fprintf(stderr, "[x11vnc] listening on port %d\n", port);

    long frame_us = (rate_hz > 0) ? 1000000L / rate_hz : 100000L;

    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) { perror("accept"); continue; }
        fprintf(stderr, "[x11vnc] client connected\n");

        if (!rfb_handshake(fd, fb_w, fb_h, "x11vnc")) {
            fprintf(stderr, "[x11vnc] handshake failed\n");
            close(fd); continue;
        }

        /* Main client loop */
        int pending_full = 0, pending_incr = 0;
        int pr_x=0, pr_y=0, pr_w=0, pr_h=0;
        int connected = 1;
        long last_frame_us = 0;  /* not used in minimal version */

        while (connected) {
            /* Non-blocking: try to read a message from client */
            uint8_t msg_type;
            /* Use MSG_DONTWAIT / non-blocking read with select() */
            fd_set rfds; FD_ZERO(&rfds); FD_SET(fd, &rfds);
            struct timeval tv = { 0, frame_us };
            int sel = select(fd+1, &rfds, NULL, NULL, &tv);
            if (sel < 0) { if (errno == EINTR) continue; break; }

            if (sel > 0) {
                if (!read_all(fd, &msg_type, 1)) { connected=0; break; }
                switch (msg_type) {
                case 0: { /* SetPixelFormat — ignore, keep our format */
                    uint8_t tmp[19]; read_all(fd, tmp, 19); break; }
                case 2: { /* SetEncodings */
                    uint8_t hdr2[3]; read_all(fd, hdr2, 3);
                    uint16_t nc = ntoh16(hdr2+1);
                    uint8_t tmp[4]; for (uint16_t i=0;i<nc;i++) read_all(fd,tmp,4);
                    break; }
                case 3: { /* FramebufferUpdateRequest */
                    uint8_t req[9]; read_all(fd, req, 9);
                    uint8_t incr = req[0];
                    pr_x = ntoh16(req+1); pr_y = ntoh16(req+3);
                    pr_w = ntoh16(req+5); pr_h = ntoh16(req+7);
                    if (incr) pending_incr = 1; else pending_full = 1;
                    break; }
                case 4: { /* KeyEvent */
                    uint8_t ke[7]; read_all(fd, ke, 7);
                    uint8_t down = ke[0];
                    uint32_t keysym = ntoh32(ke+3);
                    KeyCode kc = XKeysymToKeycode(dpy, (KeySym)keysym);
                    if (kc) {
                        XKeyEvent ev;
                        memset(&ev,0,sizeof(ev));
                        ev.display=dpy; ev.window=root; ev.root=root;
                        ev.type = down ? KeyPress : KeyRelease;
                        ev.keycode = kc;
                        ev.state = 0;
                        ev.subwindow=None; ev.time=CurrentTime; ev.same_screen=True;
                        XSendEvent(dpy, InputFocus, True, KeyPressMask|KeyReleaseMask, (XEvent*)&ev);
                        XFlush(dpy);
                    }
                    break; }
                case 5: { /* PointerEvent */
                    uint8_t pe[5]; read_all(fd, pe, 5);
                    uint8_t mask = pe[0];
                    int mx = ntoh16(pe+1), my = ntoh16(pe+3);
                    XWarpPointer(dpy, None, root, 0,0,0,0, mx, my);
                    /* Send button events */
                    for (int b=1; b<=5; b++) {
                        int bit = (1<<(b-1));
                        int pressed = (mask & bit) != 0;
                        XButtonEvent bev; memset(&bev,0,sizeof(bev));
                        bev.display=dpy; bev.window=root; bev.root=root;
                        bev.type = pressed ? ButtonPress : ButtonRelease;
                        bev.button = b; bev.x=mx; bev.y=my; bev.x_root=mx; bev.y_root=my;
                        bev.subwindow=None; bev.time=CurrentTime; bev.same_screen=True;
                        XSendEvent(dpy, PointerWindow, True,
                                   ButtonPressMask|ButtonReleaseMask, (XEvent*)&bev);
                    }
                    XFlush(dpy);
                    break; }
                case 6: { /* ClientCutText */
                    uint8_t tmp2[7]; read_all(fd, tmp2, 7);
                    uint32_t len = ntoh32(tmp2+3);
                    /* read and discard text */
                    uint8_t cb[256];
                    while (len > 0) {
                        uint32_t chunk = len > 256 ? 256 : len;
                        if (!read_all(fd, cb, chunk)) { connected=0; break; }
                        len -= chunk;
                    }
                    break; }
                default:
                    fprintf(stderr, "[x11vnc] unknown msg %u\n", msg_type);
                    connected = 0;
                    break;
                }
            }

            /* Send frame if client requested */
            if ((pending_full || pending_incr) && connected) {
                int rx=0, ry=0, rw=fb_w, rh=fb_h;
                if (pending_incr && !pending_full) {
                    /* honour client's requested rect */
                    rx=pr_x; ry=pr_y; rw=pr_w; rh=pr_h;
                    /* clamp */
                    if (rx+rw > fb_w) rw=fb_w-rx;
                    if (ry+rh > fb_h) rh=fb_h-ry;
                }
                if (rw>0 && rh>0)
                    if (!send_rect(fd, dpy, root, rx, ry, rw, rh)) connected=0;
                pending_full = pending_incr = 0;
            }
        }

        fprintf(stderr, "[x11vnc] client disconnected\n");
        close(fd);
    }

    XCloseDisplay(dpy);
    close(srv);
    return 0;
}
CSRC

    # ── compile ─────────────────────────────────────────────────────────────
    mkdir -p "$STAGE/usr/local/bin"

    # xorgproto headers are in $SRC/include (the placeholder tarball we extracted)
    XPROTO_INC="$SRC/include"

    WASM_LD_DIR=$(dirname "$WASM_LD")
    PATH="$WASM_LD_DIR:$PATH" \
    "$CLANG" -target wasm32 --sysroot="$SYSROOT" -fuse-ld=lld \
        $CFLAGS $LDFLAGS \
        -I"$XPROTO_INC" -I"$DEPS_PREFIX/include" \
        -Wno-implicit-function-declaration \
        -Wno-unused-value \
        "$SRC/x11vnc.c" \
        -L"$DEPS_PREFIX/lib" \
        -o "$STAGE/usr/local/bin/x11vnc" \
        -lX11 -lxcb -lXau -lXext -lXfixes \
        $LIBS_TRAIL

    echo "==> Verifying x11vnc binary"
    chmod +x "$STAGE/usr/local/bin/x11vnc"
    wasm-objdump -x "$STAGE/usr/local/bin/x11vnc" | grep -i "memory" | head -3

    echo "==> Asyncifying x11vnc"
    wasm-opt --asyncify -O1 "$STAGE/usr/local/bin/x11vnc" \
        -o "$STAGE/usr/local/bin/x11vnc.asyncified"
    mv "$STAGE/usr/local/bin/x11vnc.asyncified" "$STAGE/usr/local/bin/x11vnc"
}

# Tell build-package.sh not to re-asyncify (we already did it in build())
WASM_OPT_SKIP_RECIPE="usr/local/bin/x11vnc"
