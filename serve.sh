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

PORT="${1:-8000}"
DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$DIR" || exit 1

echo "linuxontab dev server"
echo "  branch:  $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
echo "  commit:  $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  serving: $DIR"
echo "  url:     http://localhost:$PORT/shell/"
echo

exec python3 -c '
import http.server, socketserver, sys
port = int(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # Required for SharedArrayBuffer (v86 needs it)
        self.send_header("Cross-Origin-Opener-Policy",   "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # Avoid stale cached HTML/JS during iteration
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
    def log_message(self, fmt, *args):
        sys.stderr.write("  %s %s\n" % (self.command, self.path))
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", port), H) as srv:
    print("ready on :%d (Ctrl+C to stop)\n" % port)
    try: srv.serve_forever()
    except KeyboardInterrupt: print("\nbye")
' "$PORT"
