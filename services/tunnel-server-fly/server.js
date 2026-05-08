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
import crypto from 'node:crypto';
import { WebSocketServer } from 'ws';
import { URL } from 'node:url';

const PORT = parseInt(process.env.PORT || '8787', 10);
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || '';
const TUNNEL_PUBLIC_URL = process.env.TUNNEL_PUBLIC_URL || ''; // e.g. wss://tunnel.linuxontab.com

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
  // Bridges idle in the pool >IDLE_BRIDGE_MS are preemptively closed:
  // upstream (e.g. syncthing) may have closed the keep-alive TCP connection
  // already, leaving websocat with a half-dead pipe. Better to force a
  // fresh respawn than to send into a corpse.
  pickFreshGuest(port) {
    const pool = this.guestWs.get(port);
    if (!pool || !pool.size) return null;
    // Idle eviction threshold: must be longer than any reasonable upstream
    // keep-alive timeout, otherwise we kick perfectly healthy bridges
    // mid-session. Syncthing default keep-alive is 75s; nginx default
    // is 75s; node http default is 5s but most app servers set higher.
    // 120s is a safe ceiling — bridges idle that long are likely dead.
    const IDLE_BRIDGE_MS = 120000;
    const now = Date.now();
    for (const ws of pool) {
      if (ws.readyState !== 1) continue;
      if (this.pairs.has(ws) || this.proxyCalls.has(ws)) continue;
      const lastUsed = this.guestLastUsed.get(ws);
      if (lastUsed && (now - lastUsed) > IDLE_BRIDGE_MS) {
        // Stale keep-alive — kick it. websocat respawn loop replaces it.
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
    return {
      registered_ports: [...this.registeredPorts],
      guest_ports: guestPorts,
      client_ports: clientPorts,
      paired_ports: clientPorts.filter(p => this.guestWs.has(p)),
      guest_queue_depth: guestQueueDepth,
      active_pairs: activePairs,
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

async function httpProxy(req, res, session, port, guestPath) {
  // Wait for an idle bridge in the pool. With keep-alive, bridges survive
  // multiple requests, so the pool only needs to drain on respawn (e.g.
  // upstream keep-alive timeout, server hiccup). Wait up to 8s.
  const RECONNECT_WAIT_MS = 8000;
  const waitStart = Date.now();
  let guestWs = null;
  while (true) {
    guestWs = session.pickFreshGuest(port);
    if (guestWs) break;
    if (Date.now() - waitStart > RECONNECT_WAIT_MS) {
      cors(res);
      res.writeHead(503);
      res.end(`guest not connected on port ${port}`);
      return;
    }
    await new Promise(r => setTimeout(r, 100));
  }

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

  const parser = new HttpResponseParser(method);
  let settle;
  const done = new Promise(r => { settle = r; });
  let firstByte = false;
  // Long-poll endpoints (Syncthing /rest/events, etc.) legitimately hold
  // the connection for up to 60s with no bytes before responding. Anything
  // shorter than that here surfaces as "Connection Error" flicker in the
  // GUI on every long-poll cycle. Give upstream plenty of room.
  let firstByteTimer = setTimeout(() => settle('no-headers'), 90000);
  let overallTimer = setTimeout(() => settle('timeout'), 300000);

  session.proxyCalls.set(guestWs, {
    feed: (buf) => {
      if (!firstByte) { firstByte = true; clearTimeout(firstByteTimer); }
      try { parser.feed(buf); }
      catch (e) { settle('parse-error'); return; }
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
    cors(res);
    res.writeHead(502);
    res.end('failed to send to guest');
    return;
  }

  const t0 = Date.now();
  const result = await done;
  clearTimeout(firstByteTimer);
  clearTimeout(overallTimer);
  session.proxyCalls.delete(guestWs);
  const dur = Date.now() - t0;
  if (result !== 'done' || dur > 5000 || parser.status >= 400) {
    console.log(`[httpProxy] ${method} ${guestPath} port=${port} → ` +
      `result=${result} status=${parser.status} dur=${dur}ms ` +
      `bodyLen=${parser.bodyBytes.reduce((n,c)=>n+c.length,0)} ` +
      `reuse=${result === 'done' && parser.canReuse() && guestWs.readyState === 1}`);
  }

  // Bridge fate: reuse iff the response framed cleanly AND upstream
  // didn't say `Connection: close`. Otherwise close so websocat respawns.
  const reuse = result === 'done' && parser.canReuse() && guestWs.readyState === 1;
  if (reuse) {
    session.guestLastUsed.set(guestWs, Date.now());
  } else {
    try { guestWs.close(1000, 'http call complete'); } catch (_) {}
  }

  if (result !== 'done') {
    cors(res);
    res.writeHead(504);
    res.end(`upstream ${result}`);
    return;
  }

  const outHeaders = {};
  for (const [k, v] of parser.rawHeaders) {
    const lc = k.toLowerCase();
    if (['connection', 'transfer-encoding', 'keep-alive', 'content-length'].includes(lc)) continue;
    // NOTE: do NOT strip 'content-encoding'. Body bytes from the guest
    // are still gzip/deflate-encoded; the browser needs the header to
    // know to decompress.
    if (lc.startsWith('access-control-')) continue;
    outHeaders[k] = v;
  }
  outHeaders['access-control-allow-origin'] = '*';
  outHeaders['access-control-expose-headers'] = '*';
  res.writeHead(parser.status, outHeaders);
  if (method === 'HEAD') res.end();
  else res.end(parser.body());
}

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
    return httpProxy(req, res, s, port, guestPath);
  }

  cors(res);
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

// ── WebSocket upgrade handling ─────────────────────────────────────────────

const wss = new WebSocketServer({ noServer: true });

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
    if (pathname === '/port/guest') session.addGuest(port, ws);
    else                             session.addClient(port, ws);
  });
});

server.listen(PORT, () => {
  console.log(`[tunnel-server] listening on :${PORT}`);
  if (TUNNEL_PUBLIC_URL) console.log(`[tunnel-server] public URL: ${TUNNEL_PUBLIC_URL}`);
});
