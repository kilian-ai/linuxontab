#!/usr/bin/env sh
# Serve LinuxOnTab locally with the COOP/COEP headers v86 needs for
# SharedArrayBuffer. Open http://localhost:8000/shell/ after start.
#
# Usage:
#   ./serve.sh           # default port 8000
#   ./serve.sh 9000      # custom port
#
# Notes:
#   • file:// URLs do NOT work for v86 — browsers block SharedArrayBuffer
#     and WASM there. Always use http://localhost:<port>/shell/.
#   • External services (relay.linuxontab.com, tunnel.linuxontab.com,
#     linuxontab-net.fly.dev) accept WebSocket from any origin, so the
#     v86 NIC and port tunnels Just Work from localhost.

# Prefer the harness-assigned PORT env (autoPort), then a CLI arg, else 8000.
PORT="${PORT:-${1:-8000}}"
DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$DIR" || exit 1

echo "linuxontab dev server"
echo "  branch:  $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
echo "  commit:  $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  serving: $DIR"
echo "  url:     http://localhost:$PORT/shell/"
echo

exec python3 -c '
import http.server, socketserver, sys, os, datetime
port = int(sys.argv[1])
log_file = "/tmp/wasm-kernel-debug.log"
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # Required for SharedArrayBuffer (v86 needs it)
        self.send_header("Cross-Origin-Opener-Policy",   "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # Avoid stale cached HTML/JS during iteration
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()
    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()
    def do_POST(self):
        if self.path == "/log":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
            line = "[%s] %s\n" % (ts, body)
            with open(log_file, "a") as f:
                f.write(line)
            sys.stderr.write(line)
            self.send_response(204)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, fmt, *args):
        if self.path != "/log":
            sys.stderr.write("  %s %s\n" % (self.command, self.path))
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", port), H) as srv:
    print("ready on :%d (log -> %s)\n" % (port, log_file))
    try: srv.serve_forever()
    except KeyboardInterrupt: print("\nbye")
' "$PORT"
