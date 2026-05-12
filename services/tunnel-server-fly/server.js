// traits-tunnel-server — Node port of relay-tunnel CF Worker.
//
// Same endpoints as the Cloudflare Worker at tunnel.linuxontab.com, minus
// hibernation state handling (Node keeps everything in memory).
//
// Endpoints:
//   GET  /health
//   POST /port/register          { code?, ports:[22,8080,...] } → { code, token, ports, relay }
//   WS   /port/guest?code=X&port=N
//   WS   /port/client?code=X&port=N
//   GET  /port/http/CODE/PORT/path  (HTTP-over-WS proxy)
//   GET  /port/status?code=X
//   POST /port/unregister        { code }
//   GET  /port/debug?code=X
//
// Env:
//   PORT              listen port (default 8787)
//   TUNNEL_SECRET     optional HMAC secret for signed tokens
//   TUNNEL_PUBLIC_URL override the "relay" URL returned by /port/register
//                     (default: wss://<host> derived from request Host header)

import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import { WebSocketServer } from 'ws';
import { URL } from 'node:url';

const PORT = parseInt(process.env.PORT || '8787', 10);
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || '';
const TUNNEL_PUBLIC_URL = process.env.TUNNEL_PUBLIC_URL || ''; // e.g. wss://tunnel.linuxontab.com

// Public TCP listener pool. Each port in this range is a slot that
// can be claimed via POST /port/expose to bridge a guest's internal
// TCP service (e.g. ngircd on :6667) to a public address. The listeners
// are pre-bound at startup and remain bound; when a port has no
// assignment, incoming TCP connections are immediately closed.
//
// Fly note: each port in this range MUST also appear as a [[services]]
// block in fly.toml so the public LB forwards it to the container.
const TCP_POOL_BASE = parseInt(process.env.TCP_POOL_BASE || '6660', 10);
const TCP_POOL_SIZE = parseInt(process.env.TCP_POOL_SIZE || '10', 10);
const TCP_PUBLIC_HOST = process.env.TCP_PUBLIC_HOST || ''; // e.g. tunnel.linuxontab.com

// ── Token signing (HMAC-SHA256) ────────────────────────────────────────────

const TOKEN_TTL_SECS = 86400 * 30;

function signToken(code) {
  if (!TUNNEL_SECRET) return null;
  const now = Math.floor(Date.now() / 1000);
  const payload = { code, iat: now, exp: now + TOKEN_TTL_SECS };
  const payloadB64 = Buffer.from(JSON.stringify(payload)).toString('base64');
  const sig = crypto.createHmac('sha256', TUNNEL_SECRET)
    .update(JSON.stringify(payload))
    .digest('base64');
  return `${payloadB64}.${sig}`;
}

function verifyToken(token) {
  if (!TUNNEL_SECRET || !token) return null;
  try {
    const dot = token.lastIndexOf('.');
    if (dot < 0) return null;
    const payloadB64 = token.slice(0, dot);
    const sigB64 = token.slice(dot + 1);
    const payload = JSON.parse(Buffer.from(payloadB64, 'base64').toString('utf8'));
    if (!payload.exp || Date.now() / 1000 > payload.exp) return null;
    const expected = crypto.createHmac('sha256', TUNNEL_SECRET)
      .update(JSON.stringify(payload))
      .digest('base64');
    if (!crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(sigB64))) return null;
    return payload;
  } catch (_) { return null; }
}

// ── Helpers ────────────────────────────────────────────────────────────────

const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function generateCode() {
  let c = '';
  for (let i = 0; i < 4; i++) c += CODE_CHARS[Math.floor(Math.random() * CODE_CHARS.length)];
  return c;
}

function normalizeCode(s) {
  if (!s) return null;
  const c = String(s).toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 4);
  return c.length === 4 ? c : null;
}

function parsePort(s) {
  const n = parseInt(s, 10);
  return (n > 0 && n < 65536) ? n : null;
}

// ── Backpressure ───────────────────────────────────────────────────────────
//
// When forwarding bytes between two paired WebSockets, we have to apply
// flow control or large transfers (snapshot push: 1-2 GB) overflow the
// outbound peer's send buffer. The ws library queues forever in memory
// without complaining, so on Fly's small-RAM dynos this either OOMs the
// process or eventually triggers a close from libuv.
//
// We pause the SOURCE WS's underlying TCP socket reads when the
// DESTINATION peer's bufferedAmount exceeds HIGH, and resume it when it
// drops below LOW. Pausing the underlying read socket exerts TCP-level
// backpressure all the way back to the original sender (browser → relay
// or guest → relay), which is exactly what we want — no in-memory
// queuing in the relay.
//
// The drain check runs once per ~50ms via setInterval until the buffer
// drains, then the timer is cleared.
const BP_HIGH = 4 * 1024 * 1024;   // pause src reads above 4 MB peer buffer
const BP_LOW  = 1 * 1024 * 1024;   // resume below 1 MB

function applyBackpressure(srcWs, dstWs) {
  if (!dstWs || dstWs.readyState !== 1) return;
  const buffered = dstWs.bufferedAmount || 0;
  if (buffered <= BP_HIGH) return;
  const sock = srcWs._socket;
  if (!sock || srcWs.__bpPaused) return;
  srcWs.__bpPaused = true;
  try { sock.pause(); } catch (_) {}
  const tick = setInterval(() => {
    // Stop if either side died — let close handlers tear down.
    if (srcWs.readyState !== 1 || dstWs.readyState !== 1) {
      clearInterval(tick);
      srcWs.__bpPaused = false;
      try { sock.resume(); } catch (_) {}
      return;
    }
    if ((dstWs.bufferedAmount || 0) <= BP_LOW) {
      clearInterval(tick);
      srcWs.__bpPaused = false;
      try { sock.resume(); } catch (_) {}
    }
  }, 50);
}

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');
}

function sendJson(res, data, status = 200) {
  cors(res);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

async function readBodyJson(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch (_) { return {}; }
}

// ── PortSession (in-memory equivalent of the Durable Object) ───────────────
//
// Multi-pair queue model (matches relay-tunnel/src/index.js):
//   guestWs:  port → Set<ws>     (FIFO-ish pool of guest bridges)
//   pairs:    ws → ws            (bidirectional client↔guest map)
//
// Each guest bridge wraps exactly ONE tcp:127.0.0.1:PORT accept on the guest
// side, so it can serve at most one client end-to-end. tunnel-up.sh keeps a
// pool of standby bridges per port; each new client attach pulls a fresh,
// unpaired bridge from the pool. This supports protocols that open multiple
// concurrent TCP connections on the same port (Filezilla parallel SFTP,
// FTP control + data channels, HTTP/1.1 keep-alive bursts, etc.). The old
// 1:1 design closed each "existing" client/guest on attach — which mid-killed
// any active parallel transfer with "socket unexpectedly closed".

class PortSession {
  constructor(code) {
    this.code = code;
    this.created = Date.now();
    this.lastActivity = Date.now();
    this.registeredPorts = new Set();
    this.guestWs = new Map();   // port → Set<ws>  (idle + paired guests)
    this.clientWs = new Map();  // port → Set<ws>  (paired clients)
    this.pairs = new Map();     // ws → ws  (bidirectional pair lookup)
    this.guestAt = new Map();   // port → ts of most-recent guest attach
    this.clientAt = new Map();  // port → ts of most-recent client attach
    // Pre-pair buffer: bytes received from a guest before any client has
    // dequeued it (e.g. sshd banner sent on TCP accept). Keyed by guest WS
    // so each bridge has its own buffer; flushed on pair, dropped on close.
    this.guestBuffer = new WeakMap();
    this.BUFFER_MAX = 256;
    this.proxyCalls = new Map();  // guest ws → { feed, settle }
    this.guestLastUsed = new WeakMap(); // guest ws → ts of last HTTP response complete
  }

  touch() { this.lastActivity = Date.now(); }

  // Pick a fresh, OPEN, unpaired, idle (no in-flight HTTP proxy) guest WS
  // for this port. Used by both addClient (TCP pairing) and httpProxy.
  pickFreshGuest(port) {
    const pool = this.guestWs.get(port);
    if (!pool || !pool.size) return null;
    const IDLE_BRIDGE_MS = 120000;
    const now = Date.now();
    for (const ws of pool) {
      if (ws.readyState !== 1) continue;
      if (this.pairs.has(ws) || this.proxyCalls.has(ws)) continue;
      const lastUsed = this.guestLastUsed.get(ws);
      if (lastUsed && (now - lastUsed) > IDLE_BRIDGE_MS) {
        try { ws.close(1000, 'idle keep-alive eviction'); } catch (_) {}
        continue;
      }
      return ws;
    }
    return null;
  }

  addGuest(port, ws) {
    this.touch();
    let pool = this.guestWs.get(port);
    if (!pool) { pool = new Set(); this.guestWs.set(port, pool); }
    pool.add(ws);
    this.guestAt.set(port, Date.now());

    ws.on('message', (data, isBinary) => {
      this.touch();
      const buf = isBinary ? data : Buffer.from(data);
      // Route to in-flight HTTP proxy call bound to this ws, if any.
      const call = this.proxyCalls.get(ws);
      if (call) { call.feed(buf); return; }
      // Forward to paired client if pair exists.
      const peer = this.pairs.get(ws);
      if (peer && peer.readyState === 1) {
        if (ws.__pair) ws.__pair.g2c += buf.length;
        try { peer.send(buf, { binary: true }); } catch (e) {
          console.log(`[pair ${ws.__pair && ws.__pair.id}] g2c send failed: ${e.message}`);
        }
        // Backpressure: if peer's outbound buffer grows, pause this
        // socket's underlying TCP read so the OS NIC backs up to the
        // far end. Without this, large transfers (snapshot push) fill
        // node's per-WS buffer and Fly OOM-kills the dyno or we hit
        // ws library default close on overflow.
        applyBackpressure(ws, peer);
        return;
      }
      // Unpaired: buffer for the eventual pair (sshd banner case).
      let b = this.guestBuffer.get(ws);
      if (!b) { b = []; this.guestBuffer.set(ws, b); }
      b.push(buf);
      if (b.length > this.BUFFER_MAX) b.shift();
    });

    ws.on('close', (code, reason) => {
      const p = this.guestWs.get(port);
      if (p) {
        p.delete(ws);
        if (!p.size) {
          this.guestWs.delete(port);
          this.guestAt.delete(port);
        }
      }
      this.guestBuffer.delete(ws);
      const call = this.proxyCalls.get(ws);
      if (call) call.settle('close');
      // Break only this specific pair; siblings on the same port survive.
      const peer = this.pairs.get(ws);
      if (peer) {
        if (ws.__pair) {
          const dur = Date.now() - ws.__pair.startedAt;
          console.log(`[pair ${ws.__pair.id}] GUEST closed first ` +
            `code=${code} reason=${String(reason||'').slice(0,60)} ` +
            `c2g=${ws.__pair.c2g} g2c=${ws.__pair.g2c} dur=${dur}ms ` +
            `peerBuffered=${peer.bufferedAmount||0}`);
        }
        this.pairs.delete(peer);
        try { peer.close(code || 1000, String(reason || 'peer disconnected')); } catch (_) {}
      }
      this.pairs.delete(ws);
    });
    ws.on('error', (e) => {
      console.log(`[guest ws] error: ${e && e.message}`);
      try { ws.close(1011, 'error'); } catch (_) {}
    });
  }

  addClient(port, ws) {
    this.touch();

    // Try to pop a fresh, unpaired guest from the pool. Each new client
    // always gets its OWN bridge — concurrent clients on the same port
    // are independent end-to-end.
    const guest = this.pickFreshGuest(port);
    if (guest) return this._completeClientPair(port, ws, guest);

    // Pool is drained — but a tunnel-up.sh respawn loop is typically
    // refilling within ~100ms. Instead of failing immediately (which
    // surfaces to Filezilla as "socket unexpectedly closed" on the very
    // first parallel SFTP connection), wait briefly for a respawn before
    // giving up. This makes small POOL_SIZE values (incl. legacy 1)
    // forgiving for parallel-capable protocols.
    const start = Date.now();
    const deadline = 2500;
    const retry = () => {
      if (ws.readyState !== 1) return;  // client gave up
      const g = this.pickFreshGuest(port);
      if (g) return this._completeClientPair(port, ws, g);
      if (Date.now() - start > deadline) {
        try { ws.close(1013, 'no guest bridge available — guest pool drained'); } catch (_) {}
        return;
      }
      setTimeout(retry, 100);
    };
    setTimeout(retry, 100);
  }

  _completeClientPair(port, ws, guest) {
    let cpool = this.clientWs.get(port);
    if (!cpool) { cpool = new Set(); this.clientWs.set(port, cpool); }
    cpool.add(ws);
    this.clientAt.set(port, Date.now());
    this.pairs.set(ws, guest);
    this.pairs.set(guest, ws);

    // Per-pair counters so close logs can tell us how far the transfer got
    // and which side closed first.
    const pairId = Math.random().toString(36).slice(2, 8);
    const pairCounters = { id: pairId, c2g: 0, g2c: 0, startedAt: Date.now() };
    ws.__pair = pairCounters;
    guest.__pair = pairCounters;
    ws.__pairRole = 'client';
    guest.__pairRole = 'guest';
    console.log(`[pair ${pairId}] ${this.code}:${port} client+guest paired`);

    // Flush any pre-pair buffered bytes from the dequeued guest. Defer with
    // setImmediate so the client WS open frame is fully delivered before we
    // start sending data — synchronous ws.send() right after handleUpgrade
    // can race the client-side handshake completion and drop the early frame.
    const buf = this.guestBuffer.get(guest);
    if (buf && buf.length) {
      this.guestBuffer.delete(guest);
      const buffered = [...buf];
      setImmediate(() => {
        for (const d of buffered) { try { ws.send(d, { binary: true }); } catch (_) {} }
      });
    }

    ws.on('message', (data, isBinary) => {
      this.touch();
      const peer = this.pairs.get(ws);
      if (!peer || peer.readyState !== 1) return;
      const buf = isBinary ? data : Buffer.from(data);
      if (ws.__pair) ws.__pair.c2g += buf.length;
      try { peer.send(buf, { binary: true }); } catch (e) {
        console.log(`[pair ${ws.__pair && ws.__pair.id}] c2g send failed: ${e.message}`);
      }
      // See addGuest() for backpressure rationale.
      applyBackpressure(ws, peer);
    });
    ws.on('close', (code, reason) => {
      const cp = this.clientWs.get(port);
      if (cp) {
        cp.delete(ws);
        if (!cp.size) {
          this.clientWs.delete(port);
          this.clientAt.delete(port);
        }
      }
      // Break only this pair; close the peer guest (single-use anyway).
      const peer = this.pairs.get(ws);
      if (peer) {
        if (ws.__pair) {
          const dur = Date.now() - ws.__pair.startedAt;
          console.log(`[pair ${ws.__pair.id}] CLIENT closed first ` +
            `code=${code} reason=${String(reason||'').slice(0,60)} ` +
            `c2g=${ws.__pair.c2g} g2c=${ws.__pair.g2c} dur=${dur}ms ` +
            `peerBuffered=${peer.bufferedAmount||0}`);
        }
        this.pairs.delete(peer);
        try { peer.close(code || 1000, String(reason || 'peer disconnected')); } catch (_) {}
      }
      this.pairs.delete(ws);
    });
    ws.on('error', (e) => {
      console.log(`[client ws] error: ${e && e.message}`);
      try { ws.close(1011, 'error'); } catch (_) {}
    });
  }

  status() {
    const now = Date.now();
    const guestPorts = [...this.guestWs.keys()];
    const clientPorts = [...this.clientWs.keys()];
    const guestQueueDepth = {};
    for (const [p, pool] of this.guestWs.entries()) {
      let idle = 0;
      for (const g of pool) if (!this.pairs.has(g) && g.readyState === 1) idle++;
      guestQueueDepth[p] = idle;
    }
    const activePairs = {};
    for (const [p, pool] of this.clientWs.entries()) activePairs[p] = pool.size;
    // needsGuest: registered but ALL ports have zero idle bridges AND zero active pairs.
    const needsGuest = this.registeredPorts.size > 0 &&
      [...this.registeredPorts].every(p => (guestQueueDepth[p] || 0) === 0 && (activePairs[p] || 0) === 0);
    return {
      registered_ports: [...this.registeredPorts],
      guest_ports: guestPorts,
      client_ports: clientPorts,
      paired_ports: clientPorts.filter(p => this.guestWs.has(p)),
      guest_queue_depth: guestQueueDepth,
      active_pairs: activePairs,
      needsGuest,
      age_s: Math.floor((now - this.created) / 1000),
      idle_s: Math.floor((now - this.lastActivity) / 1000),
      active: true,
    };
  }

  debug() {
    const now = Date.now();
    const ports = {};
    for (const p of this.registeredPorts) {
      const gpool = this.guestWs.get(p);
      const cpool = this.clientWs.get(p);
      let idle = 0, paired = 0;
      if (gpool) for (const g of gpool) (this.pairs.has(g) ? paired++ : idle++);
      ports[p] = {
        guest_queue_depth: idle,
        active_pairs: cpool ? cpool.size : 0,
        guest_paired: paired,
        guest_age_s: this.guestAt.has(p) ? Math.floor((now - this.guestAt.get(p)) / 1000) : null,
        client_age_s: this.clientAt.has(p) ? Math.floor((now - this.clientAt.get(p)) / 1000) : null,
      };
    }
    return {
      created: new Date(this.created).toISOString(),
      age_s: Math.floor((now - this.created) / 1000),
      idle_s: Math.floor((now - this.lastActivity) / 1000),
      total_pairs: this.pairs.size / 2,
      ports,
    };
  }

  destroy() {
    for (const pool of this.guestWs.values()) {
      for (const ws of pool) { try { ws.close(1000, 'unregistered'); } catch (_) {} }
    }
    for (const pool of this.clientWs.values()) {
      for (const ws of pool) { try { ws.close(1000, 'unregistered'); } catch (_) {} }
    }
    this.guestWs.clear();
    this.clientWs.clear();
    this.registeredPorts.clear();
  }
}

// ── Session registry + idle GC ─────────────────────────────────────────────

const sessions = new Map(); // code → PortSession
const IDLE_TTL_MS = 30 * 60 * 1000; // 30min

function getSession(code) { return sessions.get(code) || null; }
function getOrCreateSession(code) {
  let s = sessions.get(code);
  if (!s) { s = new PortSession(code); sessions.set(code, s); }
  return s;
}

// GC only sweeps sessions that were never (or no longer) registered. A
// session with `registeredPorts` is the durable contract for a guest's
// pairing code — destroying it loses the registration even though the
// guest's tunnel-up.sh respawn loop will reconnect within seconds. We'd
// rather grow the map slightly than silently invalidate live codes.
//
// WS pools self-clean via 'close' handlers, so an idle session with no
// peers and no registered ports is just a stale create-on-WS-attach
// remnant — those we still want to drop.
setInterval(() => {
  const now = Date.now();
  for (const [code, s] of sessions) {
    const idle = now - s.lastActivity;
    const hasPeers = s.guestWs.size > 0 || s.clientWs.size > 0;
    const isRegistered = s.registeredPorts.size > 0;
    if (idle > IDLE_TTL_MS && !hasPeers && !isRegistered) {
      s.destroy();
      sessions.delete(code);
    }
  }
}, 60 * 1000).unref?.();

// ── HTTP-over-WS proxy ─────────────────────────────────────────────────────

// Streaming HTTP/1.1 response parser. Knows when a response is complete
// based on Content-Length / Transfer-Encoding: chunked / status code, so
// we can release the bridge back to the pool for the next request
// (keep-alive) instead of burning it on every call.
class HttpResponseParser {
  constructor(method) {
    this.method = method;
    this.headBuf = Buffer.alloc(0);
    this.headersDone = false;
    this.status = 0;
    this.rawHeaders = [];     // [name, value][] preserving original casing
    this.headers = {};        // lowercase keys
    this.bodyBytes = [];
    this.expectedLen = -1;
    this.chunked = false;
    this.connectionClose = false;
    this.complete = false;
    this.error = null;
    this.cbuf = Buffer.alloc(0);
    this.chunkState = 'size'; // size | data | trailer
    this.chunkRem = 0;
  }
  feed(data) {
    if (this.complete || this.error) return;
    if (!this.headersDone) {
      this.headBuf = Buffer.concat([this.headBuf, data]);
      let he = -1;
      for (let i = 0; i + 3 < this.headBuf.length; i++) {
        if (this.headBuf[i] === 13 && this.headBuf[i+1] === 10 &&
            this.headBuf[i+2] === 13 && this.headBuf[i+3] === 10) { he = i; break; }
      }
      if (he < 0) return;
      const headStr = this.headBuf.slice(0, he).toString('utf8');
      const rest = this.headBuf.slice(he + 4);
      this.headBuf = Buffer.alloc(0);
      this._parseHeaders(headStr);
      this.headersDone = true;
      // RFC 7230: HEAD, 1xx, 204, 304 → no body.
      if (this.method === 'HEAD' || this.status < 200 ||
          this.status === 204 || this.status === 304) {
        this.complete = true;
        return;
      }
      if (rest.length) this._feedBody(rest);
      return;
    }
    this._feedBody(data);
  }
  _parseHeaders(headStr) {
    const lines = headStr.split('\r\n');
    const sm = lines[0].match(/^HTTP\/\d\.\d\s+(\d+)/);
    this.status = sm ? parseInt(sm[1], 10) : 502;
    if (!sm) { this.error = 'bad status line'; return; }
    for (let i = 1; i < lines.length; i++) {
      const m = lines[i].match(/^([^:]+):\s*(.*)$/);
      if (!m) continue;
      const k = m[1].toLowerCase();
      this.rawHeaders.push([m[1], m[2]]);
      this.headers[k] = m[2];
      if (k === 'content-length') {
        const n = parseInt(m[2], 10);
        if (!isNaN(n) && n >= 0) this.expectedLen = n;
      } else if (k === 'transfer-encoding' && /chunked/i.test(m[2])) {
        this.chunked = true;
      } else if (k === 'connection' && /close/i.test(m[2])) {
        this.connectionClose = true;
      }
    }
  }
  _feedBody(data) {
    if (this.chunked) { this._feedChunked(data); return; }
    if (this.expectedLen >= 0) {
      this.bodyBytes.push(data);
      const total = this.bodyBytes.reduce((n, c) => n + c.length, 0);
      if (total >= this.expectedLen) {
        // Trim any over-read (shouldn't happen on a single bridge but be safe)
        if (total > this.expectedLen) {
          const last = this.bodyBytes[this.bodyBytes.length - 1];
          const extra = total - this.expectedLen;
          this.bodyBytes[this.bodyBytes.length - 1] = last.slice(0, last.length - extra);
        }
        this.complete = true;
      }
      return;
    }
    // No length, not chunked → must read until close. Bridge isn't reusable.
    this.bodyBytes.push(data);
    this.connectionClose = true;
  }
  _feedChunked(data) {
    this.cbuf = Buffer.concat([this.cbuf, data]);
    while (this.cbuf.length > 0 && !this.complete) {
      if (this.chunkState === 'size') {
        let nl = -1;
        for (let i = 0; i + 1 < this.cbuf.length; i++) {
          if (this.cbuf[i] === 13 && this.cbuf[i+1] === 10) { nl = i; break; }
        }
        if (nl < 0) return;
        const sizeLine = this.cbuf.slice(0, nl).toString('ascii').split(';')[0].trim();
        const sz = parseInt(sizeLine, 16);
        if (isNaN(sz)) { this.error = 'bad chunk size'; return; }
        this.cbuf = this.cbuf.slice(nl + 2);
        if (sz === 0) { this.chunkState = 'trailer'; }
        else { this.chunkRem = sz; this.chunkState = 'data'; }
      } else if (this.chunkState === 'data') {
        const take = Math.min(this.chunkRem, this.cbuf.length);
        if (take > 0) {
          this.bodyBytes.push(this.cbuf.slice(0, take));
          this.cbuf = this.cbuf.slice(take);
          this.chunkRem -= take;
        }
        if (this.chunkRem === 0) {
          if (this.cbuf.length < 2) return;
          this.cbuf = this.cbuf.slice(2);
          this.chunkState = 'size';
        }
      } else { // trailer
        let nl = -1;
        for (let i = 0; i + 1 < this.cbuf.length; i++) {
          if (this.cbuf[i] === 13 && this.cbuf[i+1] === 10) { nl = i; break; }
        }
        if (nl < 0) return;
        const line = this.cbuf.slice(0, nl);
        this.cbuf = this.cbuf.slice(nl + 2);
        if (line.length === 0) { this.complete = true; return; }
        // ignore trailer headers
      }
    }
  }
  body() { return Buffer.concat(this.bodyBytes); }
  canReuse() { return !this.connectionClose && !this.error; }
}

async function httpProxy(req, res, session, port, guestPath, code) {
  const method = req.method;
  let bodyBytes = null;
  if (method !== 'GET' && method !== 'HEAD') {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    bodyBytes = Buffer.concat(chunks);
  }

  const hdrs = [];
  hdrs.push(`${method} ${guestPath} HTTP/1.1`);
  hdrs.push(`Host: localhost:${port}`);
  hdrs.push('Connection: keep-alive');
  hdrs.push('User-Agent: traits-tunnel-proxy/1');
  for (const h of ['accept', 'accept-encoding', 'range', 'content-type', 'cache-control', 'cookie', 'authorization', 'x-csrf-token']) {
    const v = req.headers[h];
    if (v) hdrs.push(`${h}: ${v}`);
  }
  // Forward Syncthing's X-API-Key + similar custom headers
  for (const h of Object.keys(req.headers)) {
    if (h.startsWith('x-') && !h.startsWith('x-forwarded-') && h !== 'x-csrf-token') {
      hdrs.push(`${h}: ${req.headers[h]}`);
    }
  }
  if (bodyBytes) hdrs.push(`Content-Length: ${bodyBytes.length}`);
  const reqHead = Buffer.from(hdrs.join('\r\n') + '\r\n\r\n');
  const reqBytes = bodyBytes ? Buffer.concat([reqHead, bodyBytes]) : reqHead;

  // attemptOnce: pick a bridge, send the request, await response.
  // Returns { result, parser, guestWs, dur, wasReused }.
  const attemptOnce = async () => {
    const RECONNECT_WAIT_MS = 8000;
    const waitStart = Date.now();
    let guestWs = null;
    while (true) {
      guestWs = session.pickFreshGuest(port);
      if (guestWs) break;
      if (Date.now() - waitStart > RECONNECT_WAIT_MS) return { result: 'no-bridge' };
      await new Promise(r => setTimeout(r, 100));
    }
    const wasReused = session.guestLastUsed.has(guestWs);

    const parser = new HttpResponseParser(method);
    let settle;
    const done = new Promise(r => { settle = r; });
    let firstByte = false;
    // Stale keep-alive detection: a freshly-spawned bridge has never
    // served a request, so any first-byte delay is upstream legitimately
    // taking time (e.g. Syncthing /rest/events long-poll = up to 60s).
    // A REUSED bridge however may be sitting on a TCP socket that
    // upstream already closed without our v86 websocat noticing yet —
    // in that case we'll never get bytes back. Use a tight first-byte
    // timeout for reused bridges so we can fail fast and retry on a
    // fresh one. Long-polling on a reused bridge will hit the 8s limit
    // and trigger a retry with a fresh bridge — wasteful but correct.
    const FIRST_BYTE_MS = wasReused ? 8000 : 90000;
    let firstByteTimer = setTimeout(() => settle('no-headers'), FIRST_BYTE_MS);
    let overallTimer = setTimeout(() => settle('timeout'), 300000);

    session.proxyCalls.set(guestWs, {
      feed: (buf) => {
        if (!firstByte) { firstByte = true; clearTimeout(firstByteTimer); }
        try { parser.feed(buf); }
        catch (_) { settle('parse-error'); return; }
        if (parser.error) { settle('parse-error'); return; }
        if (parser.complete) { settle('done'); }
      },
      settle,
    });

    try { guestWs.send(reqBytes, { binary: true }); }
    catch (_) {
      session.proxyCalls.delete(guestWs);
      clearTimeout(firstByteTimer); clearTimeout(overallTimer);
      try { guestWs.close(1011, 'send failed'); } catch (_) {}
      return { result: 'send-failed', parser, guestWs, dur: 0, wasReused };
    }

    const t0 = Date.now();
    const result = await done;
    clearTimeout(firstByteTimer);
    clearTimeout(overallTimer);
    session.proxyCalls.delete(guestWs);
    const dur = Date.now() - t0;
    return { result, parser, guestWs, dur, wasReused };
  };

  // First attempt. If it fails on a REUSED bridge with no headers (likely
  // a stale keep-alive), kill that bridge and retry once on a fresh one.
  let { result, parser, guestWs, dur, wasReused } = await attemptOnce();
  let retried = false;
  if (result === 'no-headers' && wasReused && guestWs) {
    // Mark this bridge dead so siblings don't pick it.
    try { guestWs.close(1000, 'stale keep-alive'); } catch (_) {}
    console.log(`[httpProxy] stale keep-alive on ${method} ${guestPath} — retrying with fresh bridge`);
    const retry = await attemptOnce();
    result = retry.result; parser = retry.parser; guestWs = retry.guestWs;
    dur = (dur || 0) + (retry.dur || 0); wasReused = retry.wasReused;
    retried = true;
  }

  if (result === 'no-bridge') {
    cors(res);
    res.writeHead(503);
    res.end(`guest not connected on port ${port}`);
    return;
  }
  if (result === 'send-failed') {
    cors(res);
    res.writeHead(502);
    res.end('failed to send to guest');
    return;
  }

  if (result !== 'done' || dur > 5000 || (parser && parser.status >= 400)) {
    const bodyLen = parser ? parser.bodyBytes.reduce((n,c)=>n+c.length,0) : 0;
    console.log(`[httpProxy] ${method} ${guestPath} port=${port} → ` +
      `result=${result} status=${parser ? parser.status : 0} dur=${dur}ms ` +
      `bodyLen=${bodyLen} retried=${retried} wasReused=${wasReused}`);
  }

  // Bridge fate: reuse iff response framed cleanly AND upstream didn't
  // say `Connection: close`. Otherwise close so websocat respawns.
  const reuse = result === 'done' && parser && parser.canReuse() && guestWs && guestWs.readyState === 1;
  if (reuse) {
    session.guestLastUsed.set(guestWs, Date.now());
  } else if (guestWs) {
    try { guestWs.close(1000, 'http call complete'); } catch (_) {}
  }

  if (result !== 'done') {
    cors(res);
    res.writeHead(504);
    res.end(`upstream ${result}`);
    return;
  }

  const outHeaders = {};
  // Prefix all relative/localhost-pointing redirects with the proxy path so
  // the browser stays inside the tunnel (otherwise Syncthing's Location:
  // http://localhost:8384/ kicks the user out to a dead localhost URL).
  const proxyPrefix = code ? `/port/http/${code}/${port}` : '';
  const rewriteLocation = (val) => {
    if (!val || !proxyPrefix) return val;
    let s = String(val);
    // Absolute URL pointing at localhost / 127.0.0.1 (any port) → strip origin
    s = s.replace(/^https?:\/\/(?:localhost|127\.0\.0\.1)(?::\d+)?/i, '');
    if (s.startsWith('/')) {
      // Avoid double-prefix if already proxied (defensive)
      if (s.startsWith(proxyPrefix + '/') || s === proxyPrefix) return s;
      return proxyPrefix + s;
    }
    return val;
  };
  for (const [k, v] of parser.rawHeaders) {
    const lc = k.toLowerCase();
    if (['connection', 'transfer-encoding', 'keep-alive', 'content-length'].includes(lc)) continue;
    // NOTE: do NOT strip 'content-encoding'. Body bytes from the guest
    // are still gzip/deflate-encoded; the browser needs the header to
    // know to decompress.
    if (lc.startsWith('access-control-')) continue;
    if (lc === 'location' || lc === 'content-location') {
      outHeaders[k] = rewriteLocation(v);
      continue;
    }
    outHeaders[k] = v;
  }
  outHeaders['access-control-allow-origin'] = '*';
  outHeaders['access-control-expose-headers'] = '*';
  res.writeHead(parser.status, outHeaders);
  if (method === 'HEAD') res.end();
  else res.end(parser.body());
}

// ── Public TCP bridge pool ─────────────────────────────────────────────────
//
// Each public TCP port in [TCP_POOL_BASE, TCP_POOL_BASE + TCP_POOL_SIZE) is
// a "slot". POST /port/expose assigns a slot to a (code, internalPort) pair.
// Incoming TCP connections on assigned slots are bridged to a fresh guest
// WS bridge (same pool used by /port/client), giving any TCP client (irssi,
// ssh, nc, ...) public access to a guest service without a Mac helper.
//
// Slots are stored in `tcpAssignments`: publicPort → { code, internalPort,
// expiresAt, createdAt }. Idle slots are reclaimed by a periodic sweeper.
//
// IMPORTANT: each public port in this range MUST also appear as a
// [[services]] block in fly.toml so the public LB forwards it to the
// container.
const tcpAssignments = new Map();         // publicPort → assignment
const tcpListeners   = new Map();         // publicPort → net.Server
const TCP_ASSIGN_TTL_MS = 60 * 60 * 1000; // 1h default

function tcpEvictDeadAssignments() {
  // Drop assignments whose code's session no longer exists. Run before
  // every allocation + on each incoming TCP connection so a stale slot
  // from a restarted/expired code never blocks a fresh expose.
  for (const [p, a] of tcpAssignments) {
    if (!getSession(a.code)) {
      console.log(`[tcp-pool] evicting stale slot :${p} (code=${a.code} session gone)`);
      tcpAssignments.delete(p);
    }
  }
}

function tcpAssignSlot(code, internalPort, ttlMs) {
  const now = Date.now();
  const ttl = ttlMs || TCP_ASSIGN_TTL_MS;
  tcpEvictDeadAssignments();
  // Prefer matching public port = internal port when it's in the pool
  // and free. Makes "expose 6667 → :6667" the natural case for IRC,
  // SSH, etc., instead of the surprising fallback to :6660.
  if (internalPort >= TCP_POOL_BASE && internalPort < TCP_POOL_BASE + TCP_POOL_SIZE
      && !tcpAssignments.has(internalPort) && tcpListeners.has(internalPort)) {
    const a = { code, internalPort, createdAt: now, expiresAt: now + ttl };
    tcpAssignments.set(internalPort, a);
    return { publicPort: internalPort, ...a };
  }
  for (let i = 0; i < TCP_POOL_SIZE; i++) {
    const p = TCP_POOL_BASE + i;
    if (!tcpAssignments.has(p) && tcpListeners.has(p)) {
      const a = { code, internalPort, createdAt: now, expiresAt: now + ttl };
      tcpAssignments.set(p, a);
      return { publicPort: p, ...a };
    }
  }
  return null;
}

function bridgeTcpToWs(sock, ws, pairId) {
  // tcp → ws  (client bytes to guest)
  sock.on('data', (chunk) => {
    if (ws.readyState !== 1) return;
    try { ws.send(chunk, { binary: true }); } catch (e) {
      console.log(`[tcp-bridge ${pairId}] tcp→ws send failed: ${e.message}`);
      try { sock.destroy(); } catch (_) {}
      return;
    }
    if ((ws.bufferedAmount || 0) > BP_HIGH && !sock.__bpPaused) {
      sock.__bpPaused = true;
      try { sock.pause(); } catch (_) {}
      const tick = setInterval(() => {
        if (sock.destroyed || ws.readyState !== 1) {
          clearInterval(tick); sock.__bpPaused = false;
          try { sock.resume(); } catch (_) {}
          return;
        }
        if ((ws.bufferedAmount || 0) <= BP_LOW) {
          clearInterval(tick); sock.__bpPaused = false;
          try { sock.resume(); } catch (_) {}
        }
      }, 50);
    }
  });

  // ws → tcp  (guest bytes to client). We attach via 'message' so we
  // bypass PortSession.addGuest's message handler (the guest WS is
  // already attached and routing to proxyCalls.feed; we override here
  // by re-listening — both listeners fire, but proxyCalls.feed is a
  // no-op for tcp bridges).
  const onWsMsg = (data, isBinary) => {
    if (sock.destroyed) return;
    const buf = isBinary ? data : Buffer.from(data);
    const ok = sock.write(buf);
    if (!ok) {
      const innerSock = ws._socket;
      if (innerSock && !ws.__bpPaused) {
        ws.__bpPaused = true;
        try { innerSock.pause(); } catch (_) {}
        sock.once('drain', () => {
          ws.__bpPaused = false;
          try { innerSock.resume(); } catch (_) {}
        });
      }
    }
  };
  ws.on('message', onWsMsg);

  let closed = false;
  const closePair = (origin, info) => {
    if (closed) return;
    closed = true;
    console.log(`[tcp-bridge ${pairId}] ${origin} closed${info ? ': ' + info : ''}`);
    try { sock.destroy(); } catch (_) {}
    // Only forcibly close the guest WS on WS-side errors or explicit WS close.
    // On TCP close, we let websocat die naturally when sshd closes its local
    // TCP — this avoids killing the websocat process prematurely and reduces
    // the bridge restart churn for the SSH TCP-expose use case.
    if (origin !== 'tcp') {
      try { ws.close(1000, origin + ' closed'); } catch (_) {}
    }
  };
  sock.on('close', () => closePair('tcp'));
  sock.on('error', (e) => closePair('tcp', e.message));
  ws.on('close', (code, reason) => closePair('ws', `code=${code} reason=${String(reason||'').slice(0,40)}`));
  ws.on('error', (e) => closePair('ws', e.message));
}

function startTcpPool() {
  for (let i = 0; i < TCP_POOL_SIZE; i++) {
    const publicPort = TCP_POOL_BASE + i;
    const srv = net.createServer(async (sock) => {
      const a = tcpAssignments.get(publicPort);
      if (!a) { try { sock.destroy(); } catch (_) {} return; }
      if (Date.now() > a.expiresAt) {
        tcpAssignments.delete(publicPort);
        try { sock.destroy(); } catch (_) {}
        return;
      }
      const session = getSession(a.code);
      if (!session) {
        // Stale slot — code's session is gone. Evict so the next
        // /port/expose can claim this port.
        console.log(`[tcp-bridge :${publicPort}] no session for code=${a.code} — evicting slot`);
        tcpAssignments.delete(publicPort);
        try { sock.destroy(); } catch (_) {}
        return;
      }
      // Retry picking a guest bridge for up to 3s (200ms intervals).
      // Bridges reconnect with a 1s respawn delay; without this wait the
      // TCP client gets an immediate RST if it happens to connect during the
      // brief reconnect window.
      let guest = session.pickFreshGuest(a.internalPort);
      if (!guest) {
        await new Promise((resolve) => {
          let tries = 0;
          const iv = setInterval(() => {
            tries++;
            guest = session.pickFreshGuest(a.internalPort);
            if (guest || tries >= 15) { clearInterval(iv); resolve(); }
          }, 200);
        });
      }
      if (!guest) {
        console.log(`[tcp-bridge :${publicPort}] no guest bridge for ${a.code}:${a.internalPort} after retry`);
        try { sock.destroy(); } catch (_) {}
        return;
      }
      // TCP client may have given up during the await wait.
      if (sock.destroyed) {
        // Return the guest to the pool by not claiming it.
        return;
      }
      const pairId = Math.random().toString(36).slice(2, 8);
      console.log(`[tcp-bridge ${pairId}] :${publicPort} → ${a.code}:${a.internalPort} paired ` +
        `(remote=${sock.remoteAddress}:${sock.remotePort})`);

      // Claim the guest WS so other consumers (HTTP proxy / /port/client)
      // skip it. proxyCalls.feed must be a no-op so it doesn't try to
      // parse our bytes as HTTP — bridgeTcpToWs handles bytes via its
      // own 'message' listener.
      session.proxyCalls.set(guest, { feed: () => {}, settle: () => {} });

      // Flush any pre-pair buffered bytes (e.g. ngircd's NOTICE banner).
      const pre = session.guestBuffer.get(guest);
      if (pre && pre.length) {
        session.guestBuffer.delete(guest);
        for (const d of pre) { try { sock.write(d); } catch (_) {} }
      }

      bridgeTcpToWs(sock, guest, pairId);

      // Unclaim when done. Don't close the guest WS from here —
      // bridgeTcpToWs only closes it on WS-side errors; on TCP close,
      // websocat will naturally exit when sshd closes its local TCP.
      const cleanup = () => { session.proxyCalls.delete(guest); };
      sock.once('close', cleanup);
      guest.once('close', cleanup);
    });
    srv.on('error', (e) => console.log(`[tcp-pool] :${publicPort} error: ${e.message}`));
    srv.listen(publicPort, '0.0.0.0', () => {
      console.log(`[tcp-pool] listening on :${publicPort}`);
    });
    tcpListeners.set(publicPort, srv);
  }
}

// Sweep expired assignments.
setInterval(() => {
  const now = Date.now();
  for (const [p, a] of tcpAssignments) {
    if (now > a.expiresAt) tcpAssignments.delete(p);
  }
  tcpEvictDeadAssignments();
}, 30 * 1000).unref?.();

// ── HTTP server ────────────────────────────────────────────────────────────

function publicRelayUrl(req) {
  if (TUNNEL_PUBLIC_URL) return TUNNEL_PUBLIC_URL;
  const host = req.headers['x-forwarded-host'] || req.headers.host || `localhost:${PORT}`;
  const xfp = req.headers['x-forwarded-proto'];
  const secure = xfp ? xfp === 'https' : false;
  return (secure ? 'wss://' : 'ws://') + host;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://local');

  if (req.method === 'OPTIONS') { cors(res); res.writeHead(204); res.end(); return; }
  if (url.pathname === '/health') { cors(res); res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok'); return; }

  // POST /port/register
  if (url.pathname === '/port/register' && req.method === 'POST') {
    const body = await readBodyJson(req);
    const code = normalizeCode(body.code) || generateCode();
    const ports = (body.ports || []).map(Number).filter(p => p > 0 && p < 65536);
    if (!ports.length) return sendJson(res, { error: 'ports required' }, 400);
    const s = getOrCreateSession(code);
    for (const p of ports) s.registeredPorts.add(p);
    const token = signToken(code);
    return sendJson(res, { code, token, ports, relay: publicRelayUrl(req) });
  }

  // GET /port/status
  if (url.pathname === '/port/status' && req.method === 'GET') {
    let code = normalizeCode(url.searchParams.get('code'));
    if (!code && url.searchParams.get('token')) {
      const payload = verifyToken(url.searchParams.get('token'));
      if (!payload) return sendJson(res, { error: 'Invalid or expired token' }, 401);
      code = payload.code;
    }
    if (!code) return sendJson(res, { error: 'missing code' }, 400);
    const s = getSession(code);
    if (!s) return sendJson(res, { code, active: false, error: 'code not found' }, 404);
    return sendJson(res, { code, ...s.status() });
  }

  // POST /port/unregister
  if (url.pathname === '/port/unregister' && req.method === 'POST') {
    const body = await readBodyJson(req);
    const code = normalizeCode(body.code);
    if (!code) return sendJson(res, { error: 'missing code' }, 400);
    const s = getSession(code);
    if (s) { s.destroy(); sessions.delete(code); }
    return sendJson(res, { ok: true });
  }

  // POST /port/expose  { code, port, ttlMs? } → { host, publicPort, expiresAt }
  // Reserves a public TCP slot from the pool that bridges to the given
  // (code, internalPort). Lets any TCP client (irssi, ssh, nc, ...)
  // connect directly to <host>:<publicPort> with no Mac-side helper.
  if (url.pathname === '/port/expose' && req.method === 'POST') {
    const body = await readBodyJson(req);
    const code = normalizeCode(body.code);
    if (!code) return sendJson(res, { error: 'missing code' }, 400);
    const internalPort = parsePort(body.port);
    if (!internalPort) return sendJson(res, { error: 'missing/invalid port' }, 400);
    const s = getSession(code);
    if (!s) return sendJson(res, { error: 'code not found' }, 404);
    if (s.registeredPorts.size > 0 && !s.registeredPorts.has(internalPort)) {
      return sendJson(res, { error: 'port not registered for this code' }, 400);
    }
    // Drop any stale (dead-session) slots first so the matching-port
    // preference works after a tunnel restart (old code → new code).
    tcpEvictDeadAssignments();
    // Reuse existing assignment for this (code, port) if present so
    // repeat calls are idempotent.
    for (const [p, a] of tcpAssignments) {
      if (a.code === code && a.internalPort === internalPort) {
        a.expiresAt = Date.now() + (parseInt(body.ttlMs, 10) || TCP_ASSIGN_TTL_MS);
        const host = TCP_PUBLIC_HOST || (req.headers['x-forwarded-host'] || req.headers.host || '').split(':')[0];
        return sendJson(res, { host, publicPort: p, code, port: internalPort, expiresAt: a.expiresAt, reused: true });
      }
    }
    const slot = tcpAssignSlot(code, internalPort, parseInt(body.ttlMs, 10));
    if (!slot) return sendJson(res, { error: 'TCP pool exhausted' }, 503);
    const host = TCP_PUBLIC_HOST || (req.headers['x-forwarded-host'] || req.headers.host || '').split(':')[0];
    console.log(`[expose] ${code}:${internalPort} → public :${slot.publicPort} (expires in ${Math.round((slot.expiresAt - Date.now())/1000)}s)`);
    return sendJson(res, { host, publicPort: slot.publicPort, code, port: internalPort, expiresAt: slot.expiresAt, reused: false });
  }

  // POST /port/unexpose { publicPort? , code? }
  // Releases a public TCP slot. Either by publicPort, or by code (releases
  // all slots assigned to that code).
  if (url.pathname === '/port/unexpose' && req.method === 'POST') {
    const body = await readBodyJson(req);
    const pub = parsePort(body.publicPort);
    const code = normalizeCode(body.code);
    let n = 0;
    if (pub && tcpAssignments.has(pub)) { tcpAssignments.delete(pub); n++; }
    else if (code) {
      for (const [p, a] of tcpAssignments) {
        if (a.code === code) { tcpAssignments.delete(p); n++; }
      }
    }
    return sendJson(res, { ok: true, released: n });
  }

  // GET /port/expose-status?code=X
  if (url.pathname === '/port/expose-status' && req.method === 'GET') {
    const code = normalizeCode(url.searchParams.get('code'));
    const host = TCP_PUBLIC_HOST || (req.headers['x-forwarded-host'] || req.headers.host || '').split(':')[0];
    const list = [];
    for (const [p, a] of tcpAssignments) {
      if (code && a.code !== code) continue;
      list.push({ host, publicPort: p, code: a.code, port: a.internalPort, expiresAt: a.expiresAt });
    }
    return sendJson(res, { assignments: list, pool_size: TCP_POOL_SIZE, pool_base: TCP_POOL_BASE });
  }

  // GET /port/debug
  if (url.pathname === '/port/debug' && req.method === 'GET') {
    const code = normalizeCode(url.searchParams.get('code'));
    if (!code) return sendJson(res, { error: 'missing code' }, 400);
    const s = getSession(code);
    if (!s) return sendJson(res, { code, active: false }, 404);
    return sendJson(res, { code, ...s.debug() });
  }

  // GET|POST|HEAD /port/http/CODE/PORT/path
  if (url.pathname.startsWith('/port/http/')) {
    const rest = url.pathname.slice('/port/http/'.length);
    const slash1 = rest.indexOf('/');
    if (slash1 < 0) return sendJson(res, { error: 'expected /port/http/CODE/PORT/path' }, 400);
    const code = normalizeCode(rest.slice(0, slash1));
    if (!code) return sendJson(res, { error: 'invalid code' }, 400);
    const afterCode = rest.slice(slash1 + 1);
    const slash2 = afterCode.indexOf('/');
    const portStr = slash2 < 0 ? afterCode : afterCode.slice(0, slash2);
    const port = parsePort(portStr);
    if (!port) return sendJson(res, { error: 'invalid port' }, 400);
    const guestPath = (slash2 < 0 ? '/' : '/' + afterCode.slice(slash2 + 1)) + (url.search || '');
    const s = getSession(code);
    if (!s) { cors(res); res.writeHead(404); res.end('code not found'); return; }
    return httpProxy(req, res, s, port, guestPath, code);
  }

  cors(res);
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

// ── WebSocket upgrade handling ─────────────────────────────────────────────

const wss = new WebSocketServer({ noServer: true });

// Heartbeat: ping every 25s, evict any ws that hasn't ponged within 60s.
// Fly.io's edge proxy kills idle WebSockets after ~60s, so we must keep
// traffic flowing on parked bridges (idle sshd / ngircd guest connections)
// or they go silent until a TCP client tries to use them and it appears
// "connected" but bytes never make it to the guest.
const HEARTBEAT_MS = 25000;
const HEARTBEAT_TIMEOUT_MS = 60000;
setInterval(() => {
  const now = Date.now();
  wss.clients.forEach((ws) => {
    if (ws.readyState !== 1) return;
    if (ws.__lastPong && now - ws.__lastPong > HEARTBEAT_TIMEOUT_MS) {
      try { ws.terminate(); } catch (_) {}
      return;
    }
    try { ws.ping(); } catch (_) {}
  });
}, HEARTBEAT_MS).unref?.();

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://local');
  const pathname = url.pathname;
  if (pathname !== '/port/guest' && pathname !== '/port/client') {
    socket.destroy();
    return;
  }

  let code = normalizeCode(url.searchParams.get('code'));
  if (!code && url.searchParams.get('token')) {
    const payload = verifyToken(url.searchParams.get('token'));
    if (payload) code = payload.code;
  }
  const port = parsePort(url.searchParams.get('port'));
  if (!code || !port) { socket.destroy(); return; }

  const session = pathname === '/port/guest' ? getOrCreateSession(code) : getSession(code);
  if (!session) { socket.destroy(); return; }
  if (session.registeredPorts.size > 0 && !session.registeredPorts.has(port)) {
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, (ws) => {
    ws.__lastPong = Date.now();
    ws.on('pong', () => { ws.__lastPong = Date.now(); });
    if (pathname === '/port/guest') session.addGuest(port, ws);
    else                             session.addClient(port, ws);
  });
});

server.listen(PORT, () => {
  console.log(`[tunnel-server] listening on :${PORT}`);
  if (TUNNEL_PUBLIC_URL) console.log(`[tunnel-server] public URL: ${TUNNEL_PUBLIC_URL}`);
  startTcpPool();
});
