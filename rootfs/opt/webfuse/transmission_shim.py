#!/usr/bin/env python3
"""Transmission-RPC endpoint for the LinuxOnTab wasm guest, backed by a real
TCP-only BitTorrent leecher (torrent_engine.py).

The guest has no general UDP — slirp forwards only port 53 — so DHT, uTP and
UDP trackers are unavailable. That does NOT rule out downloading: the peer wire
protocol is TCP, arbitrary outbound TCP works here (verified portquiz.net:6881
and bt1.archive.org:6969), and HTTP/HTTPS trackers are TCP. So any torrent
carrying an HTTP tracker downloads for real.

What still doesn't work:
  * bare magnet links — without DHT there's no way to find peers unless the
    magnet lists an HTTP tracker, and metadata would need BEP-9. Paste a
    .torrent URL instead (WebFuse fetches it and sends us the metainfo).
  * seeding / inbound peers — no port forwarding into the guest.

Single-threaded on purpose: thread-per-connection doesn't service sockets on
this kernel, and parked threads can be impossible to wake. The main loop
interleaves RPC handling with engine I/O.

Run:  python3 /opt/webfuse/transmission_shim.py &
"""
import base64
import json
import os
import re
import secrets
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, "/opt/webfuse")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from torrent_engine import Torrent  # noqa: E402

HOST, PORT = "127.0.0.1", 9091
RPC_PATH = "/transmission/rpc"
VERSION = "4.0.0 (linuxontab)"
DOWNLOAD_DIR = os.environ.get("LOT_TR_DOWNLOAD_DIR", "/opt/webfuse/testmedia/Downloads")
STATE_DIR = os.environ.get("LOT_TR_STATE_DIR", "/opt/webfuse/data/torrents")
SESSION_ID = secrets.token_hex(12)

MAGNET_UNSUPPORTED = (
    "magnet links need DHT to find peers, and this guest has no UDP "
    "(slirp forwards only port 53). Paste a .torrent URL instead."
)

RECORDS = {}     # id -> dict (metadata + last known stats)
ENGINES = {}     # id -> Torrent
NEXT_ID = 1


# ── persistence ────────────────────────────────────────────────────────────


def _state_file():
    return os.path.join(STATE_DIR, "state.json")


def save():
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(_state_file() + ".tmp", "w") as fh:
            json.dump({"next_id": NEXT_ID, "records": list(RECORDS.values())}, fh)
        os.replace(_state_file() + ".tmp", _state_file())
    except Exception:
        pass


def load():
    global NEXT_ID
    try:
        with open(_state_file()) as fh:
            s = json.load(fh)
    except Exception:
        return
    NEXT_ID = s.get("next_id", 1)
    for rec in s.get("records", []):
        RECORDS[rec["id"]] = rec
        blob = os.path.join(STATE_DIR, "%d.torrent" % rec["id"])
        if rec.get("hasMeta") and os.path.exists(blob):
            try:
                ENGINES[rec["id"]] = Torrent(open(blob, "rb").read(),
                                             rec.get("downloadDir") or DOWNLOAD_DIR)
            except Exception as e:
                rec["errorString"] = "resume failed: %s" % e


# ── add ────────────────────────────────────────────────────────────────────


def _magnet_meta(link):
    q = parse_qs(urlparse(link).query)
    xt = (q.get("xt") or [""])[0]
    m = re.search(r"urn:btih:([0-9a-zA-Z]+)", xt)
    ih = (m.group(1).lower() if m else secrets.token_hex(20))
    return unquote((q.get("dn") or [""])[0]) or ("magnet:" + ih[:12]), ih


def add_metainfo(raw, download_dir):
    global NEXT_ID
    tor = Torrent(raw, download_dir)
    tid = NEXT_ID
    NEXT_ID += 1
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(os.path.join(STATE_DIR, "%d.torrent" % tid), "wb") as fh:
        fh.write(raw)
    rec = {"id": tid, "name": tor.name, "hashString": tor.info_hash.hex(),
           "downloadDir": download_dir, "hasMeta": True,
           "addedDate": int(time.time()), "errorString": ""}
    RECORDS[tid] = rec
    ENGINES[tid] = tor
    save()
    return rec


def add_magnet(link, download_dir):
    global NEXT_ID
    name, ih = _magnet_meta(link)
    for r in RECORDS.values():
        if r["hashString"] == ih:
            return r, True
    tid = NEXT_ID
    NEXT_ID += 1
    rec = {"id": tid, "name": name, "hashString": ih, "downloadDir": download_dir,
           "hasMeta": False, "addedDate": int(time.time()),
           "errorString": MAGNET_UNSUPPORTED}
    RECORDS[tid] = rec
    save()
    return rec, False


# ── view ───────────────────────────────────────────────────────────────────


def _bitfield(tor):
    bits = bytearray((tor.piece_count + 7) // 8)
    for i, h in enumerate(tor.have):
        if h:
            bits[i >> 3] |= 0x80 >> (i & 7)
    return base64.b64encode(bytes(bits)).decode()


def view(tid):
    rec = RECORDS[tid]
    tor = ENGINES.get(tid)
    if tor is None:
        return {
            "id": tid, "name": rec["name"], "hashString": rec["hashString"],
            "percentDone": 0.0, "status": 0, "rateDownload": 0, "rateUpload": 0,
            "totalSize": 0, "downloadDir": rec["downloadDir"], "eta": -1,
            "peersSendingToUs": 0, "pieceCount": 0, "pieceSize": 0, "pieces": "",
            "sequential_download": True, "files": [],
            "errorString": rec.get("errorString", ""),
            "addedDate": rec.get("addedDate", 0),
        }
    remaining = tor.total - int(tor.percent * tor.total)
    eta = int(remaining / tor.rate) if tor.rate > 0 and not tor.done else -1
    return {
        "id": tid, "name": tor.name, "hashString": tor.info_hash.hex(),
        "percentDone": round(tor.percent, 4),
        "status": 6 if tor.done else 4,
        "rateDownload": tor.rate, "rateUpload": 0,
        "totalSize": tor.total, "downloadDir": rec["downloadDir"],
        "eta": eta, "peersSendingToUs": tor.peers_active,
        "pieceCount": tor.piece_count, "pieceSize": tor.piece_length,
        "pieces": _bitfield(tor), "sequential_download": True,
        "files": [{"name": os.path.relpath(p, rec["downloadDir"]),
                   "length": ln,
                   "bytesCompleted": int(tor.percent * ln)}
                  for p, _, ln in tor.files],
        "errorString": tor.error or rec.get("errorString", ""),
        "addedDate": rec.get("addedDate", 0),
    }


def _ids(arguments):
    ids = arguments.get("ids")
    if ids is None:
        return list(RECORDS)
    if isinstance(ids, int):
        ids = [ids]
    out = []
    for t in ids:
        for tid, rec in RECORDS.items():
            if tid == t or rec["hashString"] == t:
                out.append(tid)
    return out


# ── RPC ────────────────────────────────────────────────────────────────────


def rpc(method, arguments):
    if method == "session-get":
        return {"version": VERSION, "rpc-version": 17,
                "download-dir": DOWNLOAD_DIR, "seedRatioLimited": False}

    if method == "session-stats":
        return {"torrentCount": len(RECORDS),
                "activeTorrentCount": sum(1 for t in ENGINES.values() if not t.done),
                "downloadSpeed": sum(t.rate for t in ENGINES.values()), "uploadSpeed": 0}

    if method == "torrent-add":
        ddir = arguments.get("download-dir") or DOWNLOAD_DIR
        if arguments.get("metainfo"):
            raw = base64.b64decode(arguments["metainfo"])
            for tid, tor in ENGINES.items():
                if tor.info_hash.hex() == _peek_hash(raw):
                    r = RECORDS[tid]
                    return {"torrent-duplicate": {"id": r["id"], "name": r["name"],
                                                  "hashString": r["hashString"]}}
            rec = add_metainfo(raw, ddir)
            return {"torrent-added": {"id": rec["id"], "name": rec["name"],
                                      "hashString": rec["hashString"]}}
        rec, dup = add_magnet(arguments.get("filename", ""), ddir)
        key = "torrent-duplicate" if dup else "torrent-added"
        return {key: {"id": rec["id"], "name": rec["name"],
                      "hashString": rec["hashString"]}}

    if method == "torrent-get":
        fields = arguments.get("fields") or []
        rows = []
        for tid in _ids(arguments):
            v = view(tid)
            rows.append({f: v.get(f) for f in fields} if fields else v)
        return {"torrents": rows}

    if method == "torrent-set":
        return {}                       # sequential is always on here

    if method in ("torrent-start", "torrent-start-now", "torrent-stop"):
        return {}

    if method == "torrent-remove":
        delete = bool(arguments.get("delete-local-data"))
        for tid in _ids(arguments):
            tor = ENGINES.pop(tid, None)
            if tor:
                for p in tor.peers:
                    p.close()
                if delete:
                    for path, _, _ in tor.files:
                        try:
                            os.remove(path)
                        except OSError:
                            pass
            RECORDS.pop(tid, None)
            try:
                os.remove(os.path.join(STATE_DIR, "%d.torrent" % tid))
            except OSError:
                pass
        save()
        return {}

    raise KeyError(method)


def _peek_hash(raw):
    try:
        from torrent_engine import _raw_info
        import hashlib
        return hashlib.sha1(_raw_info(raw)).hexdigest()
    except Exception:
        return ""


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.0 => one request per connection. Deliberate: this server is
    # single-threaded, so a kept-alive connection would leave us blocked in
    # handle_one_request() and never back in accept() — the client's *second*
    # RPC call would hang forever, and because WebFuse runs sync handlers
    # inline on its event loop, that freezes WebFuse entirely.
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def _send(self, code, body=b"", extra=None):
        self.close_connection = True
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self):
        if urlparse(self.path).path != RPC_PATH:
            return self._send(404, b'{"result":"no such path"}')
        if self.headers.get("X-Transmission-Session-Id", "") != SESSION_ID:
            return self._send(409, b"<h1>409: Conflict</h1>",
                              {"X-Transmission-Session-Id": SESSION_ID})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send(400, b'{"result":"bad request"}')
        tag = req.get("tag")
        try:
            resp = {"result": "success",
                    "arguments": rpc(req.get("method", ""), req.get("arguments") or {})}
        except KeyError as e:
            resp = {"result": "method not supported: %s" % e.args[0], "arguments": {}}
        except Exception as e:
            resp = {"result": "error: %s" % e, "arguments": {}}
        if tag is not None:
            resp["tag"] = tag
        self._send(200, json.dumps(resp).encode())

    def do_GET(self):
        self._send(405, b'{"result":"use POST"}')


def main():
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    load()
    srv = HTTPServer((HOST, PORT), Handler)
    srv.timeout = 0.05                       # interleave RPC with engine I/O
    print("transmission %s on http://%s:%d%s — real TCP BitTorrent, %d torrent(s)"
          % (VERSION, HOST, PORT, RPC_PATH, len(RECORDS)), flush=True)
    last_save = time.time()
    while True:
        srv.handle_request()                 # returns after srv.timeout if idle
        for tor in list(ENGINES.values()):
            try:
                tor.tick(None)
                tor.poll(0.02)
            except Exception as e:
                tor.error = "engine: %s" % e
        if time.time() - last_save > 10:
            last_save = time.time()
            save()


if __name__ == "__main__":
    main()
