#!/usr/bin/env python3
"""LAN media gateway for WebFuse-on-tab — serves video bytes at wire speed.

The wasm guest's bulk-RX path tops out at ~30 KB/s (and stalls after ~870 KB
per TCP conn), so streaming movie bytes THROUGH the guest is a non-starter.
This gateway runs on the SMB host itself (briquette) and range-serves the same
files straight from the filesystem over LAN HTTP. The wf-sw.js service worker
rewrites /api/stream/<id> to this gateway (resolved by filename) and only falls
back to the in-guest bridge if the gateway is unreachable. The guest keeps
doing library/scan/metadata over pysmb — only the media bytes bypass it.

Run:  python3 wf-media-gw.py 8901 /var/storage
Test: curl -s -H 'Range: bytes=0-99' http://<host>:8901/media/<filename> -o /dev/null -w '%{http_code}'

Security: serves ONLY basenames found under the root (no paths, no traversal);
LAN use only, no auth — same trust model as the guest-ok SMB share it mirrors.
"""
import http.server
import os
import socketserver
import sys
import time
import urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8901
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/var/storage"
INDEX_TTL = 60  # seconds between filesystem re-walks

VIDEO_EXT = {".mp4", ".m4v", ".mov", ".webm", ".mkv", ".avi", ".ts", ".m2ts",
             ".mpg", ".mpeg", ".wmv", ".flv"}
CONTENT_TYPES = {
    ".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime",
    ".webm": "video/webm", ".mkv": "video/x-matroska", ".avi": "video/x-msvideo",
    ".ts": "video/mp2t", ".m2ts": "video/mp2t", ".mpg": "video/mpeg",
    ".mpeg": "video/mpeg", ".wmv": "video/x-ms-wmv", ".flv": "video/x-flv",
}

_index = {}          # basename -> full path
_index_time = 0.0


def file_index():
    global _index, _index_time
    now = time.time()
    if now - _index_time > INDEX_TTL:
        idx = {}
        for dirpath, dirnames, filenames in os.walk(ROOT):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for f in filenames:
                if os.path.splitext(f)[1].lower() in VIDEO_EXT:
                    idx.setdefault(f, os.path.join(dirpath, f))
        _index, _index_time = idx, now
    return _index


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _cors(self):
        # The requesting page sits behind COEP: require-corp, so cross-origin
        # media MUST carry CORP; Range triggers a CORS preflight from fetch().
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "range")
        self.send_header("Access-Control-Expose-Headers",
                         "content-range, content-length, accept-ranges")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self._serve(head_only=True)

    def do_GET(self):
        if self.path == "/health":
            body = b"ok\n"
            self.send_response(200)
            self._cors()
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._serve()

    def _fail(self, code, msg=b""):
        self.send_response(code)
        self._cors()
        self.send_header("Content-Length", str(len(msg)))
        self.end_headers()
        if msg:
            self.wfile.write(msg)

    def _serve(self, head_only=False):
        parsed = urllib.parse.urlparse(self.path)
        if not parsed.path.startswith("/media/"):
            return self._fail(404)
        name = urllib.parse.unquote(parsed.path[len("/media/"):])
        # Basenames only — no separators, no traversal.
        if not name or "/" in name or "\\" in name or name.startswith("."):
            return self._fail(400)
        path = file_index().get(name)
        if not path or not os.path.isfile(path):
            return self._fail(404)
        size = os.path.getsize(path)
        ctype = CONTENT_TYPES.get(os.path.splitext(name)[1].lower(),
                                  "application/octet-stream")
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        status = 200
        if rng and rng.startswith("bytes="):
            try:
                s, _, e = rng[len("bytes="):].partition("-")
                if s == "":                    # suffix: last N bytes
                    start = max(0, size - int(e))
                else:
                    start = int(s)
                    if e:
                        end = min(int(e), size - 1)
                if start > end or start >= size:
                    self.send_response(416)
                    self._cors()
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = 206
            except ValueError:
                return self._fail(400)
        length = end - start + 1
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if head_only:
            return
        try:
            with open(path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass  # player seeked/closed — normal

    def log_message(self, fmt, *args):
        sys.stderr.write("[gw] %s %s\n" % (self.address_string(), fmt % args))


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print("wf-media-gw on :%d root=%s" % (PORT, ROOT), flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
