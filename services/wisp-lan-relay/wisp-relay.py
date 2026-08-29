#!/usr/bin/env python3
"""Minimal WISP v1 relay — raw WebSocket, pure stdlib (no pip deps).

Gives the LinuxOnTab wasm guest real TCP egress from *inside this host's*
network, so it can reach LAN services (e.g. this box's own smbd on :445) that
the cloud fly.dev relay can't route to.

Point the guest at it:  ws://<this-host>:4000/wisp

Protocol (matches shell/wasm.html WispSlirp, little-endian):
  CONNECT  0x01 [id u32][0x01 TCP][port u16][host bytes...]   client->relay
  DATA     0x02 [id u32][payload...]                          both directions
  CONTINUE 0x03 [id u32][buffer u32]                          relay->client (client ignores)
  CLOSE    0x04 [id u32][reason u8]                            both directions
"""
import asyncio
import base64
import hashlib
import struct
import sys

HOST = "0.0.0.0"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4000
WS_MAGIC = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TCP_READ = 32 * 1024

# WISP close reasons
R_VOLUNTARY, R_UNEXPECTED, R_UNREACH = 0x01, 0x02, 0x42


# ── WebSocket framing ───────────────────────────────────────────────────────


async def ws_handshake(reader, writer):
    # Read the HTTP upgrade request (headers up to blank line).
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await reader.read(1024)
        if not chunk:
            return False
        data += chunk
        if len(data) > 65536:
            return False
    key = None
    for line in data.split(b"\r\n"):
        if line.lower().startswith(b"sec-websocket-key:"):
            key = line.split(b":", 1)[1].strip()
    if not key:
        writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        await writer.drain()
        return False
    accept = base64.b64encode(hashlib.sha1(key + WS_MAGIC).digest())
    writer.write(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n"
    )
    await writer.drain()
    return True


async def ws_read_message(reader):
    """Read one (possibly fragmented) WS message. Returns (opcode, bytes) or None."""
    frames = []
    first_opcode = None
    while True:
        hdr = await reader.readexactly(2)
        b0, b1 = hdr[0], hdr[1]
        fin = b0 & 0x80
        opcode = b0 & 0x0F
        masked = b1 & 0x80
        ln = b1 & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", await reader.readexactly(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", await reader.readexactly(8))[0]
        mask = await reader.readexactly(4) if masked else b""
        payload = await reader.readexactly(ln) if ln else b""
        if masked:
            payload = bytes(payload[i] ^ mask[i & 3] for i in range(len(payload)))
        if opcode == 0x8:                       # close
            return (0x8, b"")
        if opcode == 0x9:                       # ping -> pong (handled by caller loop)
            return (0x9, payload)
        if opcode == 0xA:                       # pong
            return (0xA, payload)
        if opcode != 0x0:                       # new message
            first_opcode = opcode
        frames.append(payload)
        if fin:
            return (first_opcode, b"".join(frames))


def ws_build(payload, opcode=0x2):
    """Server->client frame (never masked)."""
    n = len(payload)
    if n < 126:
        hdr = bytes([0x80 | opcode, n])
    elif n < 65536:
        hdr = bytes([0x80 | opcode, 126]) + struct.pack(">H", n)
    else:
        hdr = bytes([0x80 | opcode, 127]) + struct.pack(">Q", n)
    return hdr + payload


# ── WISP session ────────────────────────────────────────────────────────────


class Session:
    def __init__(self, ws_reader, ws_writer, peer):
        self.wr = ws_reader
        self.ww = ws_writer
        self.peer = peer
        self.streams = {}        # id -> (tcp_reader, tcp_writer, task)
        self.wlock = asyncio.Lock()

    async def send(self, payload):
        async with self.wlock:
            self.ww.write(ws_build(payload))
            await self.ww.drain()

    async def wisp(self, sid, typ, extra=b""):
        await self.send(struct.pack("<BI", typ, sid) + extra)

    async def run(self):
        # Initial CONTINUE on stream 0 (client ignores it, but spec-compliant).
        try:
            await self.wisp(0, 0x03, struct.pack("<I", 0xFFFF))
        except Exception:
            pass
        while True:
            # Only a real WS EOF/close ends the whole session. Reading the next
            # frame is the ONLY place a broken socket should tear us down.
            try:
                msg = await ws_read_message(self.wr)
            except (asyncio.IncompleteReadError, ConnectionResetError,
                    ConnectionAbortedError, BrokenPipeError, OSError):
                break
            if msg is None:
                break
            opcode, buf = msg
            if opcode == 0x8:
                break
            # A per-frame error must NOT kill the WebSocket — that would drop
            # every other stream and force the guest to reconnect. Log + continue.
            try:
                if opcode == 0x9:               # ping -> pong
                    await self.send_control(0xA, buf)
                    continue
                if opcode == 0xA:
                    continue
                if len(buf) < 5:
                    continue
                typ = buf[0]
                sid = struct.unpack("<I", buf[1:5])[0]
                if typ == 0x01:                 # CONNECT
                    await self.on_connect(sid, buf[5:])
                elif typ == 0x02:               # DATA client->target
                    st = self.streams.get(sid)
                    if st:
                        st[1].write(buf[5:])
                        await st[1].drain()
                elif typ == 0x04:               # CLOSE
                    await self.close_stream(sid, R_VOLUNTARY, tell_client=False)
            except Exception as e:
                print("[wisp] frame error (continuing):", repr(e), flush=True)
        if True:
            for sid in list(self.streams):
                await self.close_stream(sid, R_UNEXPECTED, tell_client=False)
            try:
                self.ww.close()
            except Exception:
                pass

    async def send_control(self, opcode, payload):
        async with self.wlock:
            self.ww.write(ws_build(payload, opcode))
            await self.ww.drain()

    async def on_connect(self, sid, body):
        if len(body) < 3:
            return await self.wisp(sid, 0x04, bytes([R_UNREACH]))
        stype = body[0]
        port = struct.unpack("<H", body[1:3])[0]
        host = body[3:].decode("utf-8", "replace")
        if stype != 0x01:                       # only TCP
            return await self.wisp(sid, 0x04, bytes([R_UNREACH]))
        try:
            tr, tw = await asyncio.wait_for(asyncio.open_connection(host, port), 12)
        except Exception as e:
            print("[wisp] %s CONNECT %d -> %s:%d FAILED %r" % (self.peer, sid, host, port, e), flush=True)
            return await self.wisp(sid, 0x04, bytes([R_UNREACH]))
        print("[wisp] %s CONNECT %d -> %s:%d ok" % (self.peer, sid, host, port), flush=True)
        task = asyncio.ensure_future(self.pump(sid, tr))
        self.streams[sid] = (tr, tw, task)

    async def pump(self, sid, tr):
        """Forward target->client as WISP DATA until EOF."""
        total = 0
        why = "eof"
        try:
            while True:
                data = await tr.read(TCP_READ)
                if not data:
                    break
                total += len(data)
                await self.wisp(sid, 0x02, data)
        except Exception as e:
            why = repr(e)
        finally:
            print("[wisp] %s pump %d done total=%d why=%s" % (self.peer, sid, total, why), flush=True)
            await self.close_stream(sid, R_VOLUNTARY)

    async def close_stream(self, sid, reason, tell_client=True):
        st = self.streams.pop(sid, None)
        if st is None:
            return
        tr, tw, task = st
        try:
            tw.close()
        except Exception:
            pass
        if task and not task.done():
            task.cancel()
        if tell_client:
            try:
                await self.wisp(sid, 0x04, bytes([reason]))
            except Exception:
                pass


# ── /lan/<room>: Ethernet-frame broadcast rooms (cross-machine tab LAN) ──────
# Every member's binary WS messages (raw guest Ethernet frames) are relayed to
# every OTHER member of the same room — a hub, exactly like the in-browser
# BroadcastChannel bridge, but across machines. Rooms are just shared secrets:
# pick an unguessable name.
LAN_ROOMS = {}          # room -> list of member dicts {writer, lock}


async def lan_session(reader, writer, peer, room):
    me = {"writer": writer, "lock": asyncio.Lock()}
    members = LAN_ROOMS.setdefault(room, [])
    members.append(me)
    print("[lan] %s joined room %r (%d members)" % (peer, room, len(members)), flush=True)
    try:
        while True:
            msg = await ws_read_message(reader)
            if msg is None:
                break
            opcode, payload = msg
            if opcode == 0x8:          # close
                break
            if opcode not in (0x1, 0x2) or not payload:
                continue
            if len(payload) > 65536:   # bigger than any Ethernet frame — drop
                continue
            frame = ws_build(payload, 0x2)
            for m in list(members):
                if m is me:
                    continue
                try:
                    async with m["lock"]:
                        m["writer"].write(frame)
                        await m["writer"].drain()
                except Exception:
                    if m in members: members.remove(m)
                    try: m["writer"].close()
                    except Exception: pass
    except Exception:
        pass
    finally:
        if me in members: members.remove(me)
        if not members:
            LAN_ROOMS.pop(room, None)
        try: writer.close()
        except Exception: pass
        print("[lan] %s left room %r (%d members)" % (peer, room, len(members)), flush=True)


async def handle(reader, writer):
    peer = writer.get_extra_info("peername")
    # Only accept the /wisp path (also serve a trivial /health for curl checks).
    try:
        peek = await asyncio.wait_for(reader.read(4096), 5)
    except Exception:
        writer.close(); return
    if peek.startswith(b"GET /health"):
        writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok\n")
        await writer.drain(); writer.close(); return
    lan_room = None
    if peek.startswith(b"GET /lan/"):
        try:
            lan_room = peek.split(b" ", 2)[1][len(b"/lan/"):].decode()[:64]
        except Exception:
            lan_room = None
        if not lan_room:
            writer.close(); return
    # Re-drive the handshake with the bytes we already peeked.
    class Prefixed:
        def __init__(self, first, r): self.buf = first; self.r = r
        async def read(self, n=-1):
            if self.buf:
                b, self.buf = self.buf, b""; return b
            return await self.r.read(n)
        async def readexactly(self, n):
            out = b""
            while len(out) < n:
                if self.buf:
                    take = self.buf[:n-len(out)]; self.buf = self.buf[len(take):]; out += take
                else:
                    out += await self.r.readexactly(n-len(out))
            return out
    pr = Prefixed(peek, reader)
    if not await ws_handshake(pr, writer):
        writer.close(); return
    if lan_room is not None:
        await lan_session(pr, writer, peer, lan_room)
        return
    print("[wisp] client %s connected" % (peer,), flush=True)
    await Session(pr, writer, peer).run()
    print("[wisp] client %s gone" % (peer,), flush=True)


async def main():
    srv = await asyncio.start_server(handle, HOST, PORT)
    print("wisp-relay listening on %s:%d  (path /wisp)" % (HOST, PORT), flush=True)
    async with srv:
        await srv.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
