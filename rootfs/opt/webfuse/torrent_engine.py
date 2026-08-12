"""Minimal TCP-only BitTorrent leecher for the LinuxOnTab wasm guest.

The guest has no general UDP (slirp forwards only port 53), so DHT, uTP and
UDP trackers are out. But the peer wire protocol is TCP and arbitrary outbound
TCP works here — verified: portquiz.net:6881 and bt1.archive.org:6969 both
connect. So with a .torrent (metadata + an HTTP tracker) we can announce over
HTTP, dial peers over TCP, and actually download.

Deliberately single-threaded and non-blocking (selectors): thread-per-anything
does not service sockets reliably on this kernel, and parked threads can be
impossible to wake. Call tick() repeatedly from the caller's loop.

Scope: leech only, sequential piece picking (good for streaming and matches
WebFuse's sequential_download intent). No DHT, no uTP, no seeding, no inbound.
"""
import hashlib
import os
import random
import selectors
import socket
import struct
import time
import urllib.parse
import urllib.request

BLOCK = 16384
MAX_PIPELINE = 6
MAX_PEERS = 12
PEER_TIMEOUT = 30
REQUEST_TIMEOUT = 20   # re-request a block if a peer never sends it
HANDSHAKE_PSTR = b"BitTorrent protocol"


# ── bencode ────────────────────────────────────────────────────────────────


def bdecode(data, i=0):
    c = data[i : i + 1]
    if c == b"i":
        j = data.index(b"e", i)
        return int(data[i + 1 : j]), j + 1
    if c == b"l":
        out, i = [], i + 1
        while data[i : i + 1] != b"e":
            v, i = bdecode(data, i)
            out.append(v)
        return out, i + 1
    if c == b"d":
        out, i = {}, i + 1
        while data[i : i + 1] != b"e":
            k, i = bdecode(data, i)
            v, i = bdecode(data, i)
            out[k] = v
        return out, i + 1
    j = data.index(b":", i)
    n = int(data[i:j])
    return data[j + 1 : j + 1 + n], j + 1 + n


def _raw_info(raw):
    """Exact bencoded bytes of the info dict (re-encoding risks a wrong hash)."""
    k = raw.find(b"4:info")
    if k < 0:
        raise ValueError("no info dict")
    start = k + 6
    _, end = bdecode(raw, start)
    return raw[start:end]


# ── peer ───────────────────────────────────────────────────────────────────


class Peer:
    def __init__(self, addr, tor):
        self.addr = addr
        self.tor = tor
        self.sock = socket.socket()
        self.sock.setblocking(False)
        self.inbuf = b""
        self.outbuf = b""
        self.handshaken = False
        self.got_handshake = False
        self.choked = True
        self.have = set()
        self.pending = {}          # (piece, begin) -> requested_at
        self.last = time.time()
        self.dead = False
        try:
            self.sock.connect_ex(addr)
        except OSError:
            self.dead = True
        self.outbuf += self._handshake()

    def _handshake(self):
        return (bytes([len(HANDSHAKE_PSTR)]) + HANDSHAKE_PSTR + b"\x00" * 8
                + self.tor.info_hash + self.tor.peer_id)

    def close(self):
        self.dead = True
        try:
            self.sock.close()
        except OSError:
            pass

    def send_msg(self, mid, payload=b""):
        self.outbuf += struct.pack(">IB", 1 + len(payload), mid) + payload

    def on_readable(self):
        try:
            b = self.sock.recv(65536)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            return self.close()
        if not b:
            return self.close()
        self.last = time.time()
        self.inbuf += b
        self._parse()

    def on_writable(self):
        if not self.outbuf:
            return
        try:
            n = self.sock.send(self.outbuf)
            self.outbuf = self.outbuf[n:]
        except (BlockingIOError, InterruptedError):
            pass
        except OSError:
            self.close()

    def _parse(self):
        if not self.got_handshake:
            if len(self.inbuf) < 68:
                return
            if self.inbuf[1:20] != HANDSHAKE_PSTR or self.inbuf[28:48] != self.tor.info_hash:
                return self.close()
            self.inbuf = self.inbuf[68:]
            self.got_handshake = True
            self.send_msg(2)                    # interested
        while len(self.inbuf) >= 4:
            (ln,) = struct.unpack(">I", self.inbuf[:4])
            if ln == 0:                          # keep-alive
                self.inbuf = self.inbuf[4:]
                continue
            if len(self.inbuf) < 4 + ln:
                return
            mid = self.inbuf[4]
            body = self.inbuf[5 : 4 + ln]
            self.inbuf = self.inbuf[4 + ln :]
            self._msg(mid, body)

    def _msg(self, mid, body):
        t = self.tor
        if mid == 0:
            self.choked = True
        elif mid == 1:
            self.choked = False
        elif mid == 4 and len(body) >= 4:
            self.have.add(struct.unpack(">I", body[:4])[0])
        elif mid == 5:
            for i in range(t.piece_count):
                if body[i >> 3] & (0x80 >> (i & 7)):
                    self.have.add(i)
        elif mid == 7 and len(body) >= 8:
            idx, begin = struct.unpack(">II", body[:8])
            t.on_block(idx, begin, body[8:])
            self.pending.pop((idx, begin), None)

    def maybe_request(self):
        if self.choked or not self.got_handshake or self.dead:
            return
        t = self.tor
        while len(self.pending) < MAX_PIPELINE:
            nxt = t.next_block(self.have)
            if nxt is None:
                return
            idx, begin, length = nxt
            self.send_msg(6, struct.pack(">III", idx, begin, length))
            self.pending[(idx, begin)] = time.time()
            t.inflight.add((idx, begin))


# ── torrent ────────────────────────────────────────────────────────────────


class Torrent:
    def __init__(self, raw, download_dir):
        meta, _ = bdecode(raw)
        info = meta[b"info"]
        self.info_hash = hashlib.sha1(_raw_info(raw)).digest()
        self.peer_id = b"-LT0001-" + bytes(random.randint(0, 255) for _ in range(12))
        self.name = info[b"name"].decode("utf-8", "replace")
        self.piece_length = int(info[b"piece length"])
        self.piece_hashes = [info[b"pieces"][i : i + 20]
                             for i in range(0, len(info[b"pieces"]), 20)]
        self.piece_count = len(self.piece_hashes)

        if b"files" in info:
            self.files, off = [], 0
            for f in info[b"files"]:
                parts = [p.decode("utf-8", "replace") for p in f[b"path"]]
                ln = int(f[b"length"])
                self.files.append((os.path.join(download_dir, self.name, *parts), off, ln))
                off += ln
            self.total = off
        else:
            ln = int(info[b"length"])
            self.files = [(os.path.join(download_dir, self.name), 0, ln)]
            self.total = ln

        self.trackers = self._trackers(meta)
        self.have = bytearray(self.piece_count)
        self.buffers = {}
        self.inflight = set()
        self.downloaded = 0
        self.peers = []
        self.known = set()
        self.last_announce = 0
        self.error = ""
        self.done = False
        self._rate_mark = (time.time(), 0)
        self.rate = 0
        for path, _, ln in self.files:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if not os.path.exists(path):
                with open(path, "wb") as fh:
                    fh.truncate(ln)

    @staticmethod
    def _trackers(meta):
        out = []
        for tier in meta.get(b"announce-list") or []:
            for u in tier:
                out.append(u.decode())
        if meta.get(b"announce"):
            out.append(meta[b"announce"].decode())
        # TCP only: UDP trackers cannot work on this guest.
        return [u for u in dict.fromkeys(out) if u.startswith(("http://", "https://"))]

    # ── pieces ─────────────────────────────────────────────────────────────

    def piece_size(self, idx):
        if idx == self.piece_count - 1:
            r = self.total % self.piece_length
            return r or self.piece_length
        return self.piece_length

    def next_block(self, peer_has):
        """Sequential: first missing piece this peer has."""
        for idx in range(self.piece_count):
            if self.have[idx] or idx not in peer_has:
                continue
            size = self.piece_size(idx)
            for begin in range(0, size, BLOCK):
                if (idx, begin) in self.inflight:
                    continue
                if self.buffers.get(idx, {}).get(begin) is not None:
                    continue
                return idx, begin, min(BLOCK, size - begin)
        return None

    def on_block(self, idx, begin, data):
        self.inflight.discard((idx, begin))
        if self.have[idx]:
            return
        buf = self.buffers.setdefault(idx, {})
        if begin in buf:
            return
        buf[begin] = data
        self.downloaded += len(data)
        size = self.piece_size(idx)
        if sum(len(v) for v in buf.values()) < size:
            return
        piece = b"".join(buf[o] for o in sorted(buf))
        if hashlib.sha1(piece).digest() != self.piece_hashes[idx]:
            self.buffers.pop(idx, None)           # corrupt — refetch
            return
        self._write(idx, piece)
        self.have[idx] = 1
        self.buffers.pop(idx, None)
        if all(self.have):
            self.done = True

    def _write(self, idx, piece):
        start = idx * self.piece_length
        for path, off, ln in self.files:
            a, b = max(start, off), min(start + len(piece), off + ln)
            if a >= b:
                continue
            with open(path, "r+b") as fh:
                fh.seek(a - off)
                fh.write(piece[a - start : b - start])

    @property
    def percent(self):
        return (sum(self.have) / self.piece_count) if self.piece_count else 0.0

    # ── tracker + peers ────────────────────────────────────────────────────

    def announce(self):
        self.last_announce = time.time()
        left = self.total - int(self.percent * self.total)
        for url in self.trackers:
            q = urllib.parse.urlencode({
                "peer_id": self.peer_id, "port": 6881, "uploaded": 0,
                "downloaded": self.downloaded, "left": left, "compact": 1,
                "event": "started", "numwant": 50,
            })
            full = "%s%s%s&info_hash=%s" % (
                url, "&" if "?" in url else "?", q,
                urllib.parse.quote_from_bytes(self.info_hash, safe=""))
            try:
                with urllib.request.urlopen(full, timeout=15) as r:
                    body = r.read()
                resp, _ = bdecode(body)
            except Exception as e:
                self.error = "tracker %s: %s" % (url.split("/")[2], e)
                continue
            if resp.get(b"failure reason"):
                self.error = "tracker %s: %s" % (
                    url.split("/")[2],
                    resp[b"failure reason"].decode("utf-8", "replace"))
                continue
            peers = resp.get(b"peers")
            found = 0
            if isinstance(peers, bytes):                       # compact
                for i in range(0, len(peers) - 5, 6):
                    ip = ".".join(str(b) for b in peers[i : i + 4])
                    port = struct.unpack(">H", peers[i + 4 : i + 6])[0]
                    if port:
                        self.known.add((ip, port)); found += 1
            elif isinstance(peers, list):
                for p in peers:
                    self.known.add((p[b"ip"].decode(), int(p[b"port"]))); found += 1
            if found:
                self.error = ""
                return found
        if not self.trackers:
            self.error = "no HTTP tracker in this torrent (UDP trackers can't work here)"
        return 0

    def tick(self, sel):
        now = time.time()
        if not self.done and (now - self.last_announce > 300 or
                              (not self.known and now - self.last_announce > 20)):
            self.announce()
        self.peers = [p for p in self.peers if not p.dead]
        for p in self.peers:
            if now - p.last > PEER_TIMEOUT:
                p.close()
        self.peers = [p for p in self.peers if not p.dead]
        # Expire stale block requests. Without this a dropped request pins its
        # block in `inflight` forever; sequential picking then never gets past
        # that piece and the whole download stalls at 0% with peers connected.
        # Fast peers hide it — a slow/lossy link (this guest) does not.
        for p in self.peers:
            for key, ts in list(p.pending.items()):
                if now - ts > REQUEST_TIMEOUT:
                    del p.pending[key]
                    self.inflight.discard(key)
        if not self.done:
            for addr in list(self.known):
                if len(self.peers) >= MAX_PEERS:
                    break
                if any(p.addr == addr for p in self.peers):
                    continue
                self.known.discard(addr)
                self.peers.append(Peer(addr, self))
        for p in self.peers:
            p.maybe_request()
        # rate
        if now - self._rate_mark[0] >= 1.0:
            self.rate = int((self.downloaded - self._rate_mark[1]) / (now - self._rate_mark[0]))
            self._rate_mark = (now, self.downloaded)

    def poll(self, timeout=0.1):
        """One non-blocking I/O pass over all peer sockets."""
        sel = selectors.DefaultSelector()
        live = [p for p in self.peers if not p.dead]
        if not live:
            time.sleep(min(timeout, 0.05))
            return
        for p in live:
            try:
                sel.register(p.sock, selectors.EVENT_READ | selectors.EVENT_WRITE, p)
            except (ValueError, KeyError, OSError):
                p.close()
        try:
            for key, mask in sel.select(timeout):
                p = key.data
                if mask & selectors.EVENT_WRITE:
                    p.on_writable()
                if mask & selectors.EVENT_READ:
                    p.on_readable()
        finally:
            sel.close()

    @property
    def peers_active(self):
        return sum(1 for p in self.peers if p.got_handshake and not p.choked)
