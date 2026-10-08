/*
 * lot-audio-probe — measure end-to-end latency of the X desktop's sound
 * path (app write → xtiny /tmp/.lot-audio → RFB → viewer → speaker).
 *
 *   lot-audio-probe [-l lead_ms] [-n clicks] [-L target_ms]
 *   lot-audio-probe -c          # print CLOCK_REALTIME every 200 ms (clock check)
 *
 * Streams silence in 5 ms chunks, paced by the clock to stay lead_ms ahead
 * of real time (default 20), with a 5 ms full-scale click once a second.
 * For each click it prints "CLICK <n> <write_ms>": the wall-clock time the
 * click was written. The page (wasm.html, window.__xAudioProbe) records the
 * wall-clock time each click is scheduled to leave the speaker; the
 * difference is the latency an interactive app sees. -L asks the viewer for
 * a playback cushion of target_ms (the LOTA header, see xtiny audio_poll).
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define RATE  48000
#define CHUNK 240                       /* frames: 5 ms */

static double now_s(clockid_t c) {
    struct timespec ts;
    clock_gettime(c, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    int lead_ms = 20, clicks = 10, target_ms = -1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-c")) {
            for (int k = 0; k < 50; k++) {
                printf("RT %.1f\n", now_s(CLOCK_REALTIME) * 1000);
                fflush(stdout);
                usleep(200000);
            }
            return 0;
        }
        if (!strcmp(argv[i], "-l") && i + 1 < argc) lead_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) clicks = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-L") && i + 1 < argc) target_ms = atoi(argv[++i]);
        else { fprintf(stderr, "usage: lot-audio-probe [-l lead_ms] [-n clicks] [-L target_ms] | -c\n"); return 2; }
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    strcpy(a.sun_path, "/tmp/.lot-audio");
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        perror("lot-audio-probe: /tmp/.lot-audio (is xtiny running?)");
        return 1;
    }
    if (target_ms >= 0) {
        uint8_t h[8] = { 'L', 'O', 'T', 'A',
                         (uint8_t)(target_ms >> 24), (uint8_t)(target_ms >> 16),
                         (uint8_t)(target_ms >> 8), (uint8_t)target_ms };
        if (write(fd, h, 8) != 8) { perror("lot-audio-probe: header"); return 1; }
    }
    int16_t silence[CHUNK * 2], click[CHUNK * 2];
    memset(silence, 0, sizeof silence);
    for (int i = 0; i < CHUNK * 2; i++) click[i] = (i / 2) % 48 < 24 ? 30000 : -30000;

    double t0 = now_s(CLOCK_MONOTONIC);
    long sent = 0, next_click = RATE;   /* first click after 1 s of silence */
    int n = 0;
    while (n < clicks) {
        double el = now_s(CLOCK_MONOTONIC) - t0;
        long want = (long)((el + lead_ms / 1000.0) * RATE);
        while (sent < want && n < clicks) {
            const int16_t *c = silence;
            if (sent >= next_click) {
                c = click;
                printf("CLICK %d %.1f\n", ++n, now_s(CLOCK_REALTIME) * 1000);
                fflush(stdout);
                next_click += RATE;
            }
            const uint8_t *p = (const uint8_t *)c;
            size_t left = sizeof silence;
            while (left) {
                ssize_t w = write(fd, p, left);
                if (w < 0 && errno == EINTR) continue;
                if (w < 0 && errno == EAGAIN) { usleep(1000); continue; }
                if (w <= 0) { perror("lot-audio-probe: write"); return 1; }
                p += w; left -= (size_t)w;
            }
            sent += CHUNK;
        }
        usleep(2000);
    }
    usleep(300000);
    return 0;
}
