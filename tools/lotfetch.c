/* lotfetch — minimal HTTP GET for the LinuxOnTab wasm guest.
 *
 *   lotfetch <url> <outfile|->
 *
 * Always connects to the JS gateway (192.168.86.1:80) over plain TCP and
 * sends an absolute-form request line. The gateway proxies any http:// or
 * https:// URL upstream via the page's fetch() — so the guest needs no DNS
 * and no TLS.
 *
 * Reliability model: bulk TCP into the guest wedges probabilistically (a
 * transfer's segments start getting lost every retransmit round and never
 * recover — see xvfb/lean-boot notes). So the body is pulled as small Range
 * slices, each on a fresh connection, each read under a poll() deadline, and
 * a wedged/short slice is simply retried at the same offset. A slice is
 * buffered in memory and written to the output only when complete, so
 * retries never corrupt the file. Servers that ignore Range (reply 200) get
 * a best-effort single-shot stream instead.
 *
 * Built for the lean image (busybox has no wget applet); apk prefers this
 * over wget when present. Build: tools/build-lotfetch.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <time.h>

#define GW_IP      "192.168.86.1"
#define GW_PORT    80
#define CHUNK      (32 * 1024L)  /* per-slice payload */
#define READ_TO_MS 2000          /* per-read deadline inside a slice */
#define RETRIES    10            /* attempts per slice (fresh conn each) */

static int die(const char *msg) {
    fprintf(stderr, "lotfetch: %s\n", msg);
    return 1;
}

/* Non-blocking read with a nanosleep-polling deadline. Blocking reads are a
 * trap in this kernel: the wakeup for arriving data is occasionally LOST, the
 * task sleeps forever, the rcv window freezes, and neither poll() timeouts
 * nor SIGALRM nor an incoming RST rouse it. Timer wakeups (nanosleep) are
 * reliable, so we poll: read → EAGAIN → sleep 50 ms → again, up to the
 * deadline. The socket is O_NONBLOCK (set after connect). */
static ssize_t tread(int fd, void *b, size_t n) {
    long waited = 0;
    for (;;) {
        ssize_t r = read(fd, b, n);
        if (r >= 0) return r;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return -1;
        if (waited >= READ_TO_MS) return -1;    /* deadline → caller retries */
        struct timespec ts = { 0, 100 * 1000 * 1000 };  /* 100 ms: fewer syscall
            round-trips = less worker churn = fewer lost RX frames */
        nanosleep(&ts, 0);
        waited += 100;
    }
}

/* Non-blocking write with the same EAGAIN/nanosleep loop. */
static int twrite_all(int fd, const void *b, long n) {
    long off = 0, waited = 0;
    while (off < n) {
        ssize_t w = write(fd, (const char *)b + off, n - off);
        if (w > 0) { off += w; waited = 0; continue; }
        if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK) return -1;
        if (waited >= READ_TO_MS) return -1;
        struct timespec ts = { 0, 50 * 1000 * 1000 };
        nanosleep(&ts, 0);
        waited += 50;
    }
    return 0;
}

static int gw_connect(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(GW_PORT);
    sa.sin_addr.s_addr = inet_addr(GW_IP);
    /* Non-blocking BEFORE connect: a blocking connect can also hit the
     * lost-wakeup bug and sleep forever. Poll completion with nanosleep. */
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    int r = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    if (r < 0 && errno != EINPROGRESS) { close(fd); return -1; }
    long waited = 0;
    while (r < 0) {
        struct timespec ts = { 0, 50 * 1000 * 1000 };
        nanosleep(&ts, 0);
        waited += 50;
        if (waited >= READ_TO_MS) { close(fd); return -1; }
        r = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
        if (r == 0 || errno == EISCONN) break;
        if (errno == EALREADY || errno == EINPROGRESS) { r = -1; continue; }
        close(fd); return -1;
    }
    return fd;
}

/* One attempt at [start, start+CHUNK) of url. On 206: fills slice[] and
 * returns its length (also sets *total from Content-Range). On 200 (server
 * ignored Range): streams the whole body straight to out_fd, sets *got200,
 * returns bytes streamed. Returns -1 on any failure/timeout/short slice. */
static long fetch_range(const char *url, const char *host, long start,
                        char *slice, int out_fd, long *total, int *got200) {
    int fd = gw_connect();
    if (fd < 0) return -1;
    char req[2048];
    int rn = snprintf(req, sizeof(req),
        "GET %s HTTP/1.0\r\nHost: %s\r\nRange: bytes=%ld-%ld\r\n"
        "Connection: close\r\n\r\n",
        url, host, start, start + CHUNK - 1);
    if (rn <= 0 || rn >= (int)sizeof(req)) { close(fd); return -1; }
    if (twrite_all(fd, req, rn) < 0) { close(fd); return -1; }

    static char buf[65536];
    size_t have = 0;
    char *body = NULL;
    while (!body) {
        if (have >= sizeof(buf) - 1) { close(fd); return -1; }
        ssize_t r = tread(fd, buf + have, sizeof(buf) - 1 - have);
        if (r <= 0) { close(fd); return -1; }
        have += r;
        buf[have] = 0;
        body = strstr(buf, "\r\n\r\n");
    }
    int status = 0;
    if (sscanf(buf, "HTTP/%*d.%*d %d", &status) != 1) { close(fd); return -1; }
    if (status != 200 && status != 206) {
        fprintf(stderr, "lotfetch: HTTP %d for %s\n", status, url);
        close(fd);
        return -1;
    }
    long content_len = -1;
    for (char *p = buf; p < body; p++) {
        if (!strncasecmp(p, "content-length:", 15)) content_len = atol(p + 15);
        if (!strncasecmp(p, "content-range:", 14)) {
            const char *slash = strchr(p, '/');
            if (slash) *total = atol(slash + 1);
        }
    }
    body += 4;
    long body_have = (long)(have - (size_t)(body - buf));

    if (status == 200) {
        /* Server ignored Range — best-effort single-shot stream to out_fd. */
        *got200 = 1;
        if (content_len >= 0) *total = content_len;
        long written = 0;
        for (long off = 0; off < body_have; ) {
            ssize_t w = write(out_fd, body + off, body_have - off);
            if (w <= 0) { close(fd); return -1; }
            off += w; written += w;
        }
        while (content_len < 0 || written < content_len) {
            ssize_t r = tread(fd, buf, sizeof(buf));
            if (r == 0) break;
            if (r < 0) { close(fd); return -1; }
            for (ssize_t off = 0; off < r; ) {
                ssize_t w = write(out_fd, buf + off, r - off);
                if (w <= 0) { close(fd); return -1; }
                off += w;
            }
            written += r;
        }
        close(fd);
        if (content_len >= 0 && written != content_len) return -1;
        return written;
    }

    /* 206: collect exactly content_len bytes into slice[]. */
    if (content_len < 0 || content_len > CHUNK) { close(fd); return -1; }
    long got = 0;
    if (body_have > content_len) body_have = content_len;  /* paranoia */
    memcpy(slice, body, body_have);
    got = body_have;
    while (got < content_len) {
        ssize_t r = tread(fd, slice + got, content_len - got);
        if (r <= 0) { close(fd); return -1; }   /* timeout/EOF-short → retry */
        got += r;
    }
    close(fd);
    return got;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: lotfetch <url> <outfile|->\n");
        return 2;
    }
    const char *url = argv[1], *outpath = argv[2];
    if (strncmp(url, "http://", 7) && strncmp(url, "https://", 8))
        return die("url must be http:// or https://");

    const char *hstart = strstr(url, "://") + 3;
    const char *hend = strchr(hstart, '/');
    char host[256];
    size_t hlen = hend ? (size_t)(hend - hstart) : strlen(hstart);
    if (hlen >= sizeof(host)) return die("host too long");
    memcpy(host, hstart, hlen); host[hlen] = 0;

    int out = 1;
    if (strcmp(outpath, "-")) {
        out = open(outpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (out < 0) return die("cannot open output file");
    }

    static char slice[CHUNK];
    long total = -1, pos = 0;
    int got200 = 0;
    for (;;) {
        long n = -1;
        for (int a = 1; a <= RETRIES; a++) {
            n = fetch_range(url, host, pos, slice, out, &total, &got200);
            if (n >= 0) break;
            if (isatty(2))
                fprintf(stderr, "\rlotfetch: retry %d/%d at %ld KB   ", a, RETRIES, pos >> 10);
        }
        if (n < 0) return die("slice failed after retries");
        if (got200) { pos += n; break; }   /* whole body already streamed */
        for (long off = 0; off < n; ) {
            ssize_t w = write(out, slice + off, n - off);
            if (w <= 0) return die("output write failed");
            off += w;
        }
        pos += n;
        if (total >= 0 && pos >= total) break;
        if (n == 0) return die("empty slice before end of file");
        if (isatty(2))
            fprintf(stderr, "\rlotfetch: %ld/%ld KB   ", pos >> 10, total >> 10);
    }
    if (isatty(2) && pos > CHUNK) fprintf(stderr, "\n");
    if (out != 1) close(out);
    if (total >= 0 && pos != total) {
        fprintf(stderr, "lotfetch: truncated: %ld/%ld bytes\n", pos, total);
        return 1;
    }
    return 0;
}
