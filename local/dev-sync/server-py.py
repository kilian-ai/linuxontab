#!/usr/bin/env python3
"""Small Python static server with CORS header fallback.
Usage: HOST_DIR=/usr/local/dev PORT=3000 python3 server-py.py
"""
import http.server
import socketserver
import os

PORT = int(os.environ.get('PORT', '3000'))
HOST_DIR = os.environ.get('HOST_DIR', os.getcwd())

class CORSHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()

if __name__ == '__main__':
    os.chdir(HOST_DIR)
    print(f'Serving {HOST_DIR} on port {PORT} (py fallback, CORS: *)')
    with socketserver.TCPServer(('', PORT), CORSHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print('shutting down')
