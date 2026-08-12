/* ws-proxy.c — minimal WebSocket ↔ TCP bridge for @tombl/linux WASM kernel
 *
 * Usage: ws-proxy WS_HOST WS_PORT WS_PATH TCP_HOST TCP_PORT
 * Example:
 *   ws-proxy linuxontab-tunnel.fly.dev 4344 \
 *     /port/guest?code=XXXX&port=22 127.0.0.1 22
 *
 * Connects to ws://WS_HOST:WS_PORT/WS_PATH (plain TCP, no TLS) and to
 * TCP_HOST:TCP_PORT, then proxies binary data bidirectionally using select().
 *
 * Compiled for @tombl/linux WASM kernel.  build-rootfs.sh applies
 * wasm-opt --asyncify so select() (blocking) works correctly.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <stdint.h>
#include <errno.h>

#define BUF_SIZE 16384

/* WS frame constants */
#define WS_FIN          0x80
#define WS_OPCODE_CONT  0x00
#define WS_OPCODE_BIN   0x02
#define WS_OPCODE_CLOSE 0x08
#define WS_OPCODE_PING  0x09
#define WS_OPCODE_PONG  0x0A
#define WS_MASK_BIT     0x80

static uint8_t buf[BUF_SIZE];

/* --- TCP connect (blocking, DNS-resolving) --- */
static int tcp_connect(const char *host, int port)
{
    struct addrinfo hints, *res, *p;
    char portstr[16];
    int fd = -1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(portstr, sizeof(portstr), "%d", port);

    if (getaddrinfo(host, portstr, &hints, &res) != 0) {
        fprintf(stderr, "ws-proxy: getaddrinfo %s failed\n", host);
        return -1;
    }
    for (p = res; p; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, p->ai_addr, p->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

/* --- Write all bytes, retry on EINTR/partial --- */
static int write_all(int fd, const uint8_t *p, size_t n)
{
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        if (w == 0) return -1;
        p += w; n -= w;
    }
    return 0;
}

/* --- Read exactly n bytes --- */
static int read_exact(int fd, uint8_t *p, size_t n)
{
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;  /* EOF */
        p += r; n -= r;
    }
    return 0;
}

/* --- WebSocket HTTP Upgrade --- */
static int ws_upgrade(int fd, const char *host, int port, const char *path)
{
    char req[2048];
    /* Static key — server validates but we don't check the accept hash */
    const char *key = "dGhlIHNhbXBsZSBub25jZQ==";
    int n = snprintf(req, sizeof(req),
        "GET %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n",
        path, host, port, key);
    if (write_all(fd, (uint8_t *)req, n) < 0) {
        fprintf(stderr, "ws-proxy: upgrade write failed\n");
        return -1;
    }
    /* Read response until \r\n\r\n */
    char resp[2048];
    int rlen = 0;
    while (rlen < (int)sizeof(resp) - 1) {
        ssize_t r = read(fd, resp + rlen, 1);
        if (r <= 0) { fprintf(stderr, "ws-proxy: upgrade read failed\n"); return -1; }
        rlen++;
        if (rlen >= 4 && memcmp(resp + rlen - 4, "\r\n\r\n", 4) == 0) break;
    }
    resp[rlen] = '\0';
    if (!strstr(resp, " 101 ")) {
        fprintf(stderr, "ws-proxy: upgrade failed: %.200s\n", resp);
        return -1;
    }
    return 0;
}

/* --- Send a masked binary WebSocket frame (client → server) --- */
static uint32_t mask_ctr = 0;

static int ws_send_binary(int fd, const uint8_t *data, size_t len)
{
    uint8_t hdr[14];
    int hlen = 0;

    /* Simple pseudo-random mask — good enough for WS masking requirement */
    mask_ctr = mask_ctr * 1664525u + 1013904223u;
    uint8_t mask[4];
    mask[0] = (mask_ctr)       & 0xff;
    mask[1] = (mask_ctr >>  8) & 0xff;
    mask[2] = (mask_ctr >> 16) & 0xff;
    mask[3] = (mask_ctr >> 24) & 0xff;

    hdr[hlen++] = WS_FIN | WS_OPCODE_BIN; /* 0x82 */
    if (len <= 125) {
        hdr[hlen++] = WS_MASK_BIT | (uint8_t)len;
    } else {
        hdr[hlen++] = WS_MASK_BIT | 126;
        hdr[hlen++] = (len >> 8) & 0xff;
        hdr[hlen++] =  len       & 0xff;
    }
    hdr[hlen++] = mask[0];
    hdr[hlen++] = mask[1];
    hdr[hlen++] = mask[2];
    hdr[hlen++] = mask[3];

    if (write_all(fd, hdr, hlen) < 0) return -1;

    /* Send masked payload in chunks */
    uint8_t chunk[512];
    size_t off = 0;
    while (off < len) {
        size_t cn = len - off < sizeof(chunk) ? len - off : sizeof(chunk);
        for (size_t i = 0; i < cn; i++)
            chunk[i] = data[off + i] ^ mask[(off + i) & 3];
        if (write_all(fd, chunk, cn) < 0) return -1;
        off += cn;
    }
    return 0;
}

/* --- Read a WebSocket frame header from fd ---
 *   Returns payload length (0..N), or -1 on error/close.
 *   Sets *opcode.  Reads mask key into mkey[4] if masked.
 */
static int64_t ws_recv_frame_hdr(int fd, uint8_t *opcode, uint8_t mkey[4], int *is_masked)
{
    uint8_t b[2];
    if (read_exact(fd, b, 2) < 0) return -1;

    *opcode    = b[0] & 0x0f;
    *is_masked = (b[1] & WS_MASK_BIT) ? 1 : 0;
    uint64_t plen = b[1] & 0x7f;

    if (plen == 126) {
        uint8_t ext[2];
        if (read_exact(fd, ext, 2) < 0) return -1;
        plen = ((uint64_t)ext[0] << 8) | ext[1];
    } else if (plen == 127) {
        uint8_t ext[8];
        if (read_exact(fd, ext, 8) < 0) return -1;
        plen = 0;
        for (int i = 0; i < 8; i++) plen = (plen << 8) | ext[i];
    }

    if (*is_masked) {
        if (read_exact(fd, mkey, 4) < 0) return -1;
    }
    return (int64_t)plen;
}

/* --- Discard n bytes from fd --- */
static int discard(int fd, int64_t n)
{
    while (n > 0) {
        size_t cn = n < (int64_t)sizeof(buf) ? (size_t)n : sizeof(buf);
        if (read_exact(fd, buf, cn) < 0) return -1;
        n -= cn;
    }
    return 0;
}

/* --- Bidirectional proxy: ws_fd ↔ tcp_fd --- */
static void run_proxy(int ws_fd, int tcp_fd)
{
    int ws_done = 0, tcp_done = 0;

    for (;;) {
        if (ws_done && tcp_done) break;

        fd_set rfds;
        FD_ZERO(&rfds);
        if (!ws_done)  FD_SET(ws_fd,  &rfds);
        if (!tcp_done) FD_SET(tcp_fd, &rfds);
        int maxfd = (ws_fd > tcp_fd ? ws_fd : tcp_fd) + 1;

        int n = select(maxfd, &rfds, NULL, NULL, NULL);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }

        /* ── TCP → WebSocket ── */
        if (!tcp_done && FD_ISSET(tcp_fd, &rfds)) {
            ssize_t r = read(tcp_fd, buf, sizeof(buf));
            if (r <= 0) {
                tcp_done = 1;
                /* Send WS close */
                uint8_t cf[6] = { WS_FIN | WS_OPCODE_CLOSE, WS_MASK_BIT, 0,0,0,0 };
                write_all(ws_fd, cf, sizeof(cf));
            } else {
                if (ws_send_binary(ws_fd, buf, (size_t)r) < 0)
                    ws_done = 1;
            }
        }

        /* ── WebSocket → TCP ── */
        if (!ws_done && FD_ISSET(ws_fd, &rfds)) {
            uint8_t opcode, mkey[4];
            int is_masked;
            int64_t plen = ws_recv_frame_hdr(ws_fd, &opcode, mkey, &is_masked);
            if (plen < 0) { ws_done = 1; continue; }

            if (opcode == WS_OPCODE_CLOSE) { ws_done = 1; discard(ws_fd, plen); continue; }
            if (opcode == WS_OPCODE_PING)  {
                /* Reply with pong */
                uint8_t pong_hdr[6] = { WS_FIN | WS_OPCODE_PONG, WS_MASK_BIT, 0,0,0,0 };
                write_all(ws_fd, pong_hdr, sizeof(pong_hdr));
                discard(ws_fd, plen);
                continue;
            }
            if (opcode != WS_OPCODE_BIN && opcode != WS_OPCODE_CONT) {
                discard(ws_fd, plen);
                continue;
            }

            /* Binary: forward to TCP */
            int64_t rem = plen;
            while (rem > 0 && !tcp_done) {
                size_t cn = rem < (int64_t)sizeof(buf) ? (size_t)rem : sizeof(buf);
                if (read_exact(ws_fd, buf, cn) < 0) { ws_done = 1; break; }
                if (is_masked)
                    for (size_t i = 0; i < cn; i++) buf[i] ^= mkey[i & 3];
                if (write_all(tcp_fd, buf, cn) < 0) { tcp_done = 1; break; }
                rem -= cn;
            }
            if (rem > 0) discard(ws_fd, rem);
        }
    }
}

int main(int argc, char *argv[])
{
    if (argc != 6) {
        fprintf(stderr,
            "usage: ws-proxy WS_HOST WS_PORT WS_PATH TCP_HOST TCP_PORT\n"
            "example:\n"
            "  ws-proxy linuxontab-tunnel.fly.dev 4344 "
            "'/port/guest?code=XXXX&port=22' 127.0.0.1 22\n");
        return 1;
    }
    const char *ws_host  = argv[1];
    int         ws_port  = atoi(argv[2]);
    const char *ws_path  = argv[3];
    const char *tcp_host = argv[4];
    int         tcp_port = atoi(argv[5]);

    /* Seed the mask counter (any non-zero seed will do) */
    mask_ctr = (uint32_t)(uintptr_t)argv ^ 0xdeadbeef;

    fprintf(stderr, "ws-proxy: connecting to ws://%s:%d%s\n",
            ws_host, ws_port, ws_path);
    int ws_fd = tcp_connect(ws_host, ws_port);
    if (ws_fd < 0) return 1;

    if (ws_upgrade(ws_fd, ws_host, ws_port, ws_path) < 0) {
        close(ws_fd); return 1;
    }
    fprintf(stderr, "ws-proxy: WS connected\n");

    fprintf(stderr, "ws-proxy: connecting tcp://%s:%d\n", tcp_host, tcp_port);
    int tcp_fd = tcp_connect(tcp_host, tcp_port);
    if (tcp_fd < 0) { close(ws_fd); return 1; }
    fprintf(stderr, "ws-proxy: TCP connected — bridging\n");

    run_proxy(ws_fd, tcp_fd);

    close(ws_fd);
    close(tcp_fd);
    fprintf(stderr, "ws-proxy: done\n");
    return 0;
}
