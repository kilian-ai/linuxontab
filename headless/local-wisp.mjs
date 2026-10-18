// An in-process Wisp server that looks like a WebSocket to its client.
//
// In the browser, WispSlirp (the guest's user-mode TCP/IP stack, in
// shell/wasm.html) opens guest connections as Wisp streams over a WebSocket to
// a relay, which makes the real TCP/UDP connections. On a server there is no
// reason for a relay: this object is handed to WispSlirp in place of that
// WebSocket and serves the same protocol straight onto node:net / node:dgram
// sockets, so the guest reaches the network the host is on (a VPC on EC2).
//
// Protocol: Wisp v2 with the UDP extension when the client offers "wisp-v2",
// plain v1 otherwise. Packets are type u8, stream id u32 LE, payload.
import net from "node:net";
import dgram from "node:dgram";

const CONNECT = 0x01, DATA = 0x02, CONTINUE = 0x03, CLOSE = 0x04, INFO = 0x05;
const TCP = 0x01, UDP = 0x02;
const BUFFER_PACKETS = 128;      // advertised in CONTINUE; the client ignores it

const CLOSE_VOLUNTARY = 0x01, CLOSE_NETWORK = 0x41, CLOSE_UNREACHABLE = 0x42,
  CLOSE_TIMEOUT = 0x43, CLOSE_REFUSED = 0x44, CLOSE_BLOCKED = 0x48;

function closeReason(err) {
  switch (err && err.code) {
    case "ECONNREFUSED": return CLOSE_REFUSED;
    case "ETIMEDOUT": return CLOSE_TIMEOUT;
    case "ENOTFOUND": case "EAI_AGAIN": case "EHOSTUNREACH": case "ENETUNREACH":
      return CLOSE_UNREACHABLE;
    default: return CLOSE_NETWORK;
  }
}

/**
 * Returns a WebSocket-shaped object (binaryType, protocol, readyState,
 * onopen/onmessage/onclose/onerror, send, close) backed by real sockets.
 *
 * `allow(proto, host, port)` is the egress policy hook (security groups);
 * returning false refuses the stream.
 */
export function openLocalWisp(protocols, { log = () => {}, allow = () => true } = {}) {
  const v2 = Array.isArray(protocols) && protocols.includes("wisp-v2");
  const streams = new Map();   // id -> { kind: 'tcp'|'udp', sock }
  const sock = {
    binaryType: "arraybuffer",
    protocol: v2 ? "wisp-v2" : "",
    readyState: 0,
    bufferedAmount: 0,
    onopen: null, onmessage: null, onclose: null, onerror: null,
    send(data) {
      if (sock.readyState !== 1) return;
      const buf = data instanceof Uint8Array ? data
        : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
        : new Uint8Array(data);
      try { onClientPacket(buf); } catch (e) { log("[wisp] bad packet: " + (e && e.stack || e)); }
    },
    close() {
      if (sock.readyState >= 2) return;
      sock.readyState = 3;
      for (const s of streams.values()) destroy(s);
      streams.clear();
      queueMicrotask(() => sock.onclose && sock.onclose({ type: "close", code: 1000 }));
    },
  };

  // Server -> client. The client reads ev.data as an ArrayBuffer of exactly
  // this packet, so hand it a fresh one (never a pooled Buffer's backing store).
  function emit(type, id, payload) {
    if (sock.readyState !== 1) return;
    const len = payload ? payload.byteLength : 0;
    const out = new Uint8Array(5 + len);
    out[0] = type;
    new DataView(out.buffer).setUint32(1, id, true);
    if (len) out.set(payload, 5);
    sock.onmessage && sock.onmessage({ data: out.buffer });
  }
  const u32 = (n) => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b; };
  const emitContinue = (id) => emit(CONTINUE, id, u32(BUFFER_PACKETS));
  const emitClose = (id, reason) => { streams.delete(id); emit(CLOSE, id, new Uint8Array([reason])); };

  function destroy(s) {
    try { s.kind === "tcp" ? s.sock.destroy() : s.sock.close(); } catch {}
  }

  function onClientPacket(buf) {
    if (buf.byteLength < 5) return;
    const type = buf[0];
    const id = new DataView(buf.buffer, buf.byteOffset, buf.byteLength).getUint32(1, true);
    const payload = buf.subarray(5);
    switch (type) {
      case CONNECT: return connect(id, payload);
      case DATA: {
        const s = streams.get(id);
        if (!s) return;
        if (s.kind === "tcp") s.sock.write(Buffer.from(payload));   // copy: caller may reuse
        else if (s.pending) s.pending.push(Buffer.from(payload));   // dgram still connecting
        else s.sock.send(Buffer.from(payload));
        return;
      }
      case CLOSE: {
        const s = streams.get(id);
        if (s) { streams.delete(id); destroy(s); }
        return;
      }
      case INFO:
        // The client's v2 INFO answers ours; the session opens on CONTINUE 0.
        if (id === 0) emitContinue(0);
        return;
      case CONTINUE:
        return;   // client-side flow control: nothing to do in-process
    }
  }

  function connect(id, p) {
    if (p.byteLength < 3) return emitClose(id, CLOSE_NETWORK);
    const kind = p[0] === UDP ? "udp" : "tcp";
    const port = p[1] | (p[2] << 8);
    const host = new TextDecoder().decode(p.subarray(3));
    if (!allow(kind, host, port)) {
      log(`[wisp] refused ${kind} ${host}:${port} (policy)`);
      return emitClose(id, CLOSE_BLOCKED);
    }
    log(`[wisp] CONNECT ${kind} ${host}:${port} sid=${id}`);
    if (kind === "tcp") {
      const s = net.connect({ host, port });
      s.setNoDelay(true);
      streams.set(id, { kind, sock: s });
      emitContinue(id);
      s.on("data", (chunk) => emit(DATA, id, chunk));
      s.on("error", (err) => {
        log(`[wisp] tcp ${host}:${port} sid=${id} ${err.code || err.message}`);
        if (streams.has(id)) emitClose(id, closeReason(err));
      });
      s.on("close", () => { if (streams.has(id)) emitClose(id, CLOSE_VOLUNTARY); });
    } else {
      if (!v2) return emitClose(id, CLOSE_NETWORK);
      const family = net.isIPv6(host) ? "udp6" : "udp4";
      const s = dgram.createSocket(family);
      const stream = { kind, sock: s, pending: [] };
      streams.set(id, stream);
      s.on("message", (msg) => emit(DATA, id, msg));
      s.on("error", (err) => {
        log(`[wisp] udp ${host}:${port} sid=${id} ${err.code || err.message}`);
        if (streams.has(id)) { emitClose(id, closeReason(err)); try { s.close(); } catch {} }
      });
      s.connect(port, host, () => {
        const queued = stream.pending;
        stream.pending = null;
        for (const b of queued) s.send(b);
        emitContinue(id);
      });
    }
  }

  // Open asynchronously, like a real WebSocket. A v2 server speaks first with
  // INFO (version 2.0 + the UDP extension); a v1 server with CONTINUE 0.
  setTimeout(() => {
    sock.readyState = 1;
    sock.onopen && sock.onopen({ type: "open" });
    if (v2) emit(INFO, 0, new Uint8Array([2, 0, 0x01, 0, 0, 0, 0]));
    else emitContinue(0);
  }, 0);
  return sock;
}
