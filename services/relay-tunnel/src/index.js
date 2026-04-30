/**
 * traits-build-tunnel — TCP port tunnel via WebSocket pairs
 *
 * Forks the FsBridge pattern from relay/src/index.js into a dedicated
 * worker so the running relay.linuxontab.com is never touched.
 *
 * Routes:
 *   GET  /health
 *   POST /port/register   { code?, ports:[22,21,22000,8384] } → { code, token }
 *   WS   /port/guest?code=XXXX&port=22     ← guest (websocat → local port)
 *   WS   /port/client?code=XXXX&port=22    ← external client
 *   GET  /port/status?code=XXXX            → { registered_ports, guest_ports, client_ports, age_s }
 *   POST /port/unregister { code }
 *   GET  /port/debug?code=XXXX
 *
 * Each code maps to one PortSession Durable Object.
 * Each PortSession holds one guest WS + one client WS per registered port.
 * Raw bytes are spliced bidirectionally — zero protocol awareness.
 *
 * Deploying:
 *   cd relay-tunnel && npm install && npx wrangler deploy
 */

// ── HMAC-SHA256 signed tokens ─────────────────────────────────────────────────
// Requires TUNNEL_SECRET worker secret (optional, skipped if absent).
// Set via: npx wrangler secret put TUNNEL_SECRET

const TOKEN_TTL_SECS = 86400 * 30;

async function _getHmacKey(secret) {
  return crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify'],
  );
}

async function signToken(code, secret) {
  const payload = { code, iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECS };
  const payloadBytes = new TextEncoder().encode(JSON.stringify(payload));
  const key = await _getHmacKey(secret);
  const sig = await crypto.subtle.sign('HMAC', key, payloadBytes);
  return btoa(JSON.stringify(payload)) + '.' + btoa(String.fromCharCode(...new Uint8Array(sig)));
}

async function verifyToken(token, secret) {
  try {
    const dot = token.lastIndexOf('.');
    if (dot === -1) return null;
    const payloadB64 = token.slice(0, dot);
    const sigB64 = token.slice(dot + 1);
    const payload = JSON.parse(atob(payloadB64));
    if (!payload.exp || Date.now() / 1000 > payload.exp) return null;
    const key = await _getHmacKey(secret);
    const sigBytes = Uint8Array.from(atob(sigB64), c => c.charCodeAt(0));
    const dataBytes = new TextEncoder().encode(JSON.stringify(payload));
    const valid = await crypto.subtle.verify('HMAC', key, sigBytes, dataBytes);
    return valid ? payload : null;
  } catch (_) { return null; }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function cors() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': '*',
  };
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...cors() },
  });
}

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

function _concat(arrays) {
  let total = 0;
  for (const a of arrays) total += a.byteLength;
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrays) { out.set(a, off); off += a.byteLength; }
  return out;
}

// ── PortSession Durable Object ────────────────────────────────────────────────
// One DO instance per pairing code.
//
// Multi-pair queue model:
//   guestQueue:  port → Array<WS>  (FIFO of idle guest bridges, not yet paired)
//   pairs:       WS → WS           (bidirectional pair map: client↔guest)
//
// Each guest WS on the tunnel wraps exactly ONE tcp:127.0.0.1:PORT accept on
// the guest side, so it can serve at most ONE client end-to-end. tunnel-up.sh
// maintains a pool of standby bridges per port (POOL_SIZE, default 4); each
// new client dequeues one fresh bridge here. The guest's respawn loop refills
// the pool as bridges are consumed.
//
// This multi-pair design is required for parallel-capable protocols:
//   - SFTP (Filezilla opens 2+ concurrent SSH connections for parallel xfers)
//   - FTP control + multiple data sockets
//   - HTTP/1.1 keep-alive across overlapping requests
//
// The previous 1:1-per-port design closed any "existing" client/guest on a
// new client attach, which mid-killed the first parallel SFTP transfer with
// "Could not read from socket, socket unexpectedly closed".

export class PortSession {
  constructor(state, _env) {
    this.state = state;
    this.created = Date.now();
    this.registeredPorts = new Set();
    this.guestQueue = new Map();   // port → Array<WS>  (idle guests, FIFO)
    this.pairs = new Map();        // WS → WS  (bidirectional)
    // Pre-pair buffer: bytes received from a guest before any client has
    // dequeued it (e.g. sshd banner sent eagerly on TCP accept). Keyed by
    // guest WS so each bridge has its own buffer; flushed to the client on
    // pair, discarded on guest close.
    this.guestBuffer = new WeakMap();
    this.BUFFER_MAX = 256;
    this.lastActivity = Date.now();
    this.IDLE_TTL_MS = 10 * 60 * 1000;
    // Per-WS HTTP proxy call state: ws → { chunks:[], resolve, resetIdle }
    // Used to route webSocketMessage bytes into an active _httpProxy call
    // (the call dequeues a guest and consumes it single-shot).
    this.proxyCalls = new Map();

    this.state.blockConcurrencyWhile(async () => {
      const ports = await this.state.storage.get('registeredPorts');
      if (Array.isArray(ports)) this.registeredPorts = new Set(ports);
      const created = await this.state.storage.get('created');
      if (typeof created === 'number') this.created = created;
      // Force-reset any hibernated WSes — pair state isn't persisted to DO
      // storage, and CF DO hibernation only triggers after extended idle
      // (tunnel-up.sh's --ping-interval 25 keeps active sessions hot, so
      // hibernation cannot interrupt a live transfer). Closing hibernated
      // WS triggers tunnel-up.sh respawn → fresh bridges enqueued cleanly.
      for (const ws of this.state.getWebSockets()) {
        try { ws.close(1000, 'rehydrate'); } catch (_) {}
      }
    });
  }

  _parseTags(ws) {
    let role = null, port = null;
    for (const t of this.state.getTags(ws)) {
      if (t === 'guest' || t === 'client') role = t;
      else if (t.startsWith('port:')) port = parseInt(t.slice(5), 10);
    }
    return { role, port };
  }

  _cloneWsPayload(message) {
    if (message instanceof ArrayBuffer) {
      return message.slice(0);
    }
    if (typeof message === 'string') {
      return message;
    }
    if (message && message.byteLength != null) {
      const u8 = new Uint8Array(message.buffer || message, message.byteOffset || 0, message.byteLength);
      return u8.slice();
    }
    return message;
  }

  async fetch(request) {
    this.lastActivity = Date.now();
    const url = new URL(request.url);
    if (url.pathname.startsWith('/http')) return this._httpProxy(request, url);
    switch (url.pathname) {
      case '/register':  return this._register(request);
      case '/guest':     return this._accept(request, 'guest', url);
      case '/client':    return this._accept(request, 'client', url);
      case '/status':    return this._status();
      case '/unregister':return this._unregister();
      case '/debug':     return this._debug();
      default:           return new Response('not found', { status: 404 });
    }
  }

  async _register(request) {
    let ports = [];
    try {
      const body = await request.json();
      ports = (body.ports || []).map(Number).filter(p => p > 0 && p < 65536);
    } catch (_) {}
    if (!ports.length) return json({ error: 'ports required (non-empty array of port numbers)' }, 400);
    for (const p of ports) this.registeredPorts.add(p);
    await this.state.storage.put('registeredPorts', [...this.registeredPorts]);
    await this.state.storage.put('created', this.created);
    return json({ ok: true, registered_ports: [...this.registeredPorts] });
  }

  async _accept(request, role, url) {
    const port = parsePort(url.searchParams.get('port'));
    if (!port) return new Response('missing or invalid port', { status: 400 });
    if (this.registeredPorts.size > 0 && !this.registeredPorts.has(port)) {
      return new Response(`port ${port} not registered for this code`, { status: 403 });
    }

    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('WebSocket upgrade required', { status: 426 });
    }

    if (role === 'client') {
      // Pop a fresh OPEN guest from the queue. Each guest WS = one TCP accept
      // on the guest side, single-use. Filezilla-style parallel SFTP transfers
      // open multiple SSH connections to the same port — each one dequeues
      // its own bridge here, paired independently.
      const popFreshGuest = () => {
        const q = this.guestQueue.get(port);
        while (q && q.length) {
          const candidate = q.shift();
          if (candidate.readyState === 1 /* OPEN */) {
            if (!q.length) this.guestQueue.delete(port);
            return candidate;
          }
        }
        if (q && !q.length) this.guestQueue.delete(port);
        return null;
      };
      let guest = popFreshGuest();
      // Pool may be momentarily empty between guest respawns. Wait briefly
      // for tunnel-up.sh's respawn loop to refill (typical refill ~100ms),
      // so small POOL_SIZE values still tolerate parallel-capable clients.
      if (!guest) {
        const start = Date.now();
        const deadline = 2500;
        while (Date.now() - start < deadline) {
          await new Promise(r => setTimeout(r, 100));
          guest = popFreshGuest();
          if (guest) break;
        }
      }
      if (!guest) {
        return new Response(
          `no guest bridge available on port ${port} (pool drained — guest must respawn)`,
          { status: 503 },
        );
      }

      const pair = new WebSocketPair();
      const client = pair[1];
      this.state.acceptWebSocket(client, ['client', `port:${port}`]);
      this.pairs.set(client, guest);
      this.pairs.set(guest, client);

      // Flush any pre-pair buffered bytes (e.g. SSH banner sent eagerly by
      // sshd on TCP accept, before this client dequeued the bridge).
      const buf = this.guestBuffer.get(guest);
      if (buf && buf.length) {
        this.guestBuffer.delete(guest);
        const buffered = [...buf];
        setTimeout(() => {
          for (const d of buffered) { try { client.send(d); } catch (_) {} }
        }, 0);
      }

      return new Response(null, { status: 101, webSocket: pair[0] });
    }

    // role === 'guest': enqueue in the per-port standby pool.
    const pair = new WebSocketPair();
    const guest = pair[1];
    this.state.acceptWebSocket(guest, ['guest', `port:${port}`]);
    let q = this.guestQueue.get(port);
    if (!q) { q = []; this.guestQueue.set(port, q); }
    q.push(guest);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  // Hibernation API handlers — Cloudflare invokes these for any acceptWebSocket'd
  // WS, surviving DO eviction. All bytes flow through here.
  async webSocketMessage(ws, message) {
    this.lastActivity = Date.now();
    const { role } = this._parseTags(ws);

    // If an _httpProxy call owns this guest WS, deliver bytes to it.
    const call = this.proxyCalls.get(ws);
    if (call && role === 'guest') {
      let u8;
      if (message instanceof ArrayBuffer)       u8 = new Uint8Array(message);
      else if (typeof message === 'string')     u8 = new TextEncoder().encode(message);
      else if (message && message.byteLength != null) u8 = new Uint8Array(message.buffer || message);
      if (u8) { call.chunks.push(u8); call.resetIdle(); }
      return;
    }

    // Forward to paired peer if pair exists.
    const peer = this.pairs.get(ws);
    if (peer && peer.readyState === 1) {
      try { peer.send(message); } catch (_) {}
      return;
    }

    // Unpaired guest receiving bytes (e.g. sshd banner on TCP accept before
    // any client has dequeued this bridge): buffer for the eventual pair.
    if (role === 'guest') {
      let buf = this.guestBuffer.get(ws);
      if (!buf) { buf = []; this.guestBuffer.set(ws, buf); }
      buf.push(this._cloneWsPayload(message));
      if (buf.length > this.BUFFER_MAX) buf.shift();
    }
  }

  async webSocketClose(ws, code, reason, _wasClean) {
    const { role, port } = this._parseTags(ws);
    // If still queued (unpaired guest disconnected), splice out.
    if (role === 'guest' && port != null) {
      const q = this.guestQueue.get(port);
      if (q) {
        const i = q.indexOf(ws);
        if (i >= 0) q.splice(i, 1);
        if (!q.length) this.guestQueue.delete(port);
      }
    }
    this.guestBuffer.delete(ws);

    // Break the specific pair only — other concurrent pairs on the same
    // port are unaffected. This is the key change vs the old 1:1 design:
    // a closed Filezilla transfer #1 no longer kills transfer #2.
    const peer = this.pairs.get(ws);
    if (peer) {
      this.pairs.delete(peer);
      try { peer.close(code || 1000, String(reason || 'peer disconnected')); } catch (_) {}
    }
    this.pairs.delete(ws);

    const call = this.proxyCalls.get(ws);
    if (call) call.settle('close');
  }

  async webSocketError(ws, _err) {
    return this.webSocketClose(ws, 1011, 'peer error', false);
  }

  _status() {
    const now = Date.now();
    const guestQueueDepth = {};
    for (const [p, q] of this.guestQueue.entries()) guestQueueDepth[p] = q.length;
    // Count active pairs per port.
    const pairsPerPort = {};
    for (const ws of this.pairs.keys()) {
      const { role, port } = this._parseTags(ws);
      if (role === 'client' && port != null) {
        pairsPerPort[port] = (pairsPerPort[port] || 0) + 1;
      }
    }
    return json({
      registered_ports: [...this.registeredPorts],
      guest_queue_depth: guestQueueDepth,
      active_pairs: pairsPerPort,
      // Legacy compatibility fields (used by tunnel-up.sh reclaim watchdog
      // to detect "session lost"): non-empty if any guest is registered or
      // paired on the port.
      guest_ports: [...new Set([...Object.keys(guestQueueDepth).map(Number), ...Object.keys(pairsPerPort).map(Number)])],
      client_ports: Object.keys(pairsPerPort).map(Number),
      paired_ports: Object.keys(pairsPerPort).map(Number),
      age_s: Math.floor((now - this.created) / 1000),
      idle_s: Math.floor((now - this.lastActivity) / 1000),
    });
  }

  async _unregister() {
    for (const q of this.guestQueue.values()) {
      for (const ws of q) { try { ws.close(1000, 'unregistered'); } catch (_) {} }
    }
    for (const ws of this.pairs.keys()) { try { ws.close(1000, 'unregistered'); } catch (_) {} }
    this.guestQueue.clear();
    this.pairs.clear();
    this.registeredPorts.clear();
    await this.state.storage.deleteAll();
    return json({ ok: true });
  }

  // HTTP/1.1 proxy: dequeues a guest from the standby pool, sends an HTTP
  // request over it (the guest bridges to tcp:127.0.0.1:PORT internally),
  // parses the response bytes, returns a Response. Single-shot — the guest's
  // tunnel-up.sh respawn loop refills the pool for subsequent calls.
  async _httpProxy(request, url) {
    const port = parsePort(request.headers.get('X-Tunnel-Port'));
    if (!port) return new Response('missing port', { status: 400, headers: cors() });
    const q = this.guestQueue.get(port);
    let guestWs = null;
    while (q && q.length) {
      const candidate = q.shift();
      if (candidate.readyState === 1) { guestWs = candidate; break; }
    }
    if (q && !q.length) this.guestQueue.delete(port);
    if (!guestWs) {
      return new Response(`guest not connected on port ${port}`, { status: 503, headers: cors() });
    }

    // Derive upstream path: main worker routes to "/http" + guest path.
    const stripped = url.pathname.replace(/^\/http/, '') || '/';
    const guestPath = stripped + (url.search || '');
    const method = request.method;
    const bodyBytes = (method === 'GET' || method === 'HEAD')
      ? null
      : new Uint8Array(await request.arrayBuffer());

    // Build HTTP/1.1 request bytes.
    const hdrs = [];
    hdrs.push(`${method} ${guestPath} HTTP/1.1`);
    hdrs.push(`Host: guest.tunnel.local`);
    hdrs.push(`Connection: close`);
    hdrs.push(`User-Agent: traits-tunnel-proxy/1`);
    for (const h of ['accept', 'accept-encoding', 'range', 'content-type', 'cache-control']) {
      const v = request.headers.get(h);
      if (v) hdrs.push(`${h}: ${v}`);
    }
    if (bodyBytes) hdrs.push(`Content-Length: ${bodyBytes.byteLength}`);
    const reqHead = new TextEncoder().encode(hdrs.join('\r\n') + '\r\n\r\n');
    const reqBytes = bodyBytes ? _concat([reqHead, bodyBytes]) : reqHead;

    // Collect response bytes with idle + close detection.
    const chunks = [];
    let settle;
    const done = new Promise(r => { settle = r; });
    let idleTimer;
    const IDLE_MS = 1500;
    const resetIdle = () => { clearTimeout(idleTimer); idleTimer = setTimeout(() => settle('idle'), IDLE_MS); };

    // Register the call keyed by the dequeued guest WS so webSocketMessage
    // routes its bytes here (multiple concurrent proxy calls on the same
    // port are now safe — each owns its own bridge).
    this.proxyCalls.set(guestWs, { chunks, resetIdle, settle });

    try {
      guestWs.send(reqBytes);
    } catch (err) {
      this.proxyCalls.delete(guestWs);
      return new Response('failed to send to guest', { status: 502, headers: cors() });
    }
    resetIdle();

    // Overall timeout for the whole proxy call.
    const timeout = new Promise(r => setTimeout(() => r('timeout'), 12000));
    await Promise.race([done, timeout]);
    clearTimeout(idleTimer);
    this.proxyCalls.delete(guestWs);
    // Single-shot: close the consumed bridge so the guest respawn loop
    // refills the standby pool for subsequent calls.
    try { guestWs.close(1000, 'http-proxy-done'); } catch (_) {}

    // Parse HTTP/1.1 response bytes.
    const total = chunks.reduce((s, c) => s + c.byteLength, 0);
    if (!total) return new Response('no response from guest', { status: 504, headers: cors() });
    const buf = new Uint8Array(total);
    let off = 0;
    for (const c of chunks) { buf.set(c, off); off += c.byteLength; }

    // Find \r\n\r\n header terminator.
    let he = -1;
    for (let i = 0; i + 3 < buf.length; i++) {
      if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) { he = i; break; }
    }
    if (he < 0) return new Response('bad http response from guest', { status: 502, headers: cors() });

    const headStr = new TextDecoder().decode(buf.slice(0, he));
    const body = buf.slice(he + 4);
    const lines = headStr.split('\r\n');
    const statusMatch = lines[0].match(/^HTTP\/\d\.\d\s+(\d+)\s*(.*)$/);
    const status = statusMatch ? parseInt(statusMatch[1], 10) : 502;

    const outHeaders = new Headers();
    for (let i = 1; i < lines.length; i++) {
      const m = lines[i].match(/^([^:]+):\s*(.*)$/);
      if (!m) continue;
      const k = m[1].toLowerCase();
      // Skip hop-by-hop + length fields (Response recomputes them).
      if (['connection', 'transfer-encoding', 'keep-alive', 'content-length', 'content-encoding'].includes(k)) continue;
      try { outHeaders.append(m[1], m[2]); } catch (_) {}
    }
    outHeaders.set('access-control-allow-origin', '*');
    outHeaders.set('access-control-expose-headers', '*');
    // HEAD has no body.
    return new Response(method === 'HEAD' ? null : body, { status, headers: outHeaders });
  }

  _debug() {
    const now = Date.now();
    const ports = {};
    const pairsPerPort = {};
    for (const ws of this.pairs.keys()) {
      const { role, port } = this._parseTags(ws);
      if (role === 'client' && port != null) {
        pairsPerPort[port] = (pairsPerPort[port] || 0) + 1;
      }
    }
    for (const p of this.registeredPorts) {
      const q = this.guestQueue.get(p);
      ports[p] = {
        guest_queue_depth: q ? q.length : 0,
        active_pairs: pairsPerPort[p] || 0,
      };
    }
    return json({
      created: new Date(this.created).toISOString(),
      age_s: Math.floor((now - this.created) / 1000),
      idle_s: Math.floor((now - this.lastActivity) / 1000),
      total_pairs: this.pairs.size / 2,
      ports,
    });
  }
}

// ── Main Worker ───────────────────────────────────────────────────────────────

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: cors() });
    }

    if (url.pathname === '/health') {
      return new Response('ok', { headers: cors() });
    }

    // POST /port/register  { code?, ports:[22, 21, 22000] }
    if (url.pathname === '/port/register' && request.method === 'POST') {
      let body = {};
      try { body = await request.json(); } catch (_) {}
      const code = normalizeCode(body.code) || generateCode();
      const ports = (body.ports || []).map(Number).filter(p => p > 0 && p < 65536);
      if (!ports.length) return json({ error: 'ports required' }, 400);

      const stub = env.PORT_SESSION.get(env.PORT_SESSION.idFromName(code));
      await stub.fetch(new Request('http://do/register', {
        method: 'POST',
        body: JSON.stringify({ ports }),
        headers: { 'Content-Type': 'application/json' },
      }));

      let token = null;
      if (env.TUNNEL_SECRET) {
        token = await signToken(code, env.TUNNEL_SECRET);
      }

      return json({ code, token, ports, relay: 'wss://tunnel.linuxontab.com' });
    }

    // WS /port/guest?code=XXXX&port=22
    if (url.pathname === '/port/guest') {
      const code = normalizeCode(url.searchParams.get('code'));
      if (!code) return json({ error: 'missing code' }, 400);
      return env.PORT_SESSION.get(env.PORT_SESSION.idFromName(code)).fetch(
        new Request(`http://do/guest?port=${url.searchParams.get('port') || ''}`, request),
      );
    }

    // WS /port/client?code=XXXX&port=22
    if (url.pathname === '/port/client') {
      const code = normalizeCode(url.searchParams.get('code'));
      // Accept signed token in place of code
      if (!code && request.headers.get('upgrade') === 'websocket' && url.searchParams.get('token') && env.TUNNEL_SECRET) {
        const payload = await verifyToken(url.searchParams.get('token'), env.TUNNEL_SECRET);
        if (!payload) return json({ error: 'Invalid or expired token' }, 401);
        return env.PORT_SESSION.get(env.PORT_SESSION.idFromName(payload.code)).fetch(
          new Request(`http://do/client?port=${url.searchParams.get('port') || ''}`, request),
        );
      }
      if (!code) return json({ error: 'missing code' }, 400);
      return env.PORT_SESSION.get(env.PORT_SESSION.idFromName(code)).fetch(
        new Request(`http://do/client?port=${url.searchParams.get('port') || ''}`, request),
      );
    }

    // GET/HEAD/POST /port/http/CODE/PORT/path  → HTTP-over-WS proxy to guest
    if (url.pathname.startsWith('/port/http/')) {
      const rest = url.pathname.slice('/port/http/'.length);
      // Format: CODE/PORT[/path...]
      const slash1 = rest.indexOf('/');
      if (slash1 < 0) return json({ error: 'expected /port/http/CODE/PORT/path' }, 400);
      const code = normalizeCode(rest.slice(0, slash1));
      if (!code) return json({ error: 'invalid code' }, 400);
      const afterCode = rest.slice(slash1 + 1);
      const slash2 = afterCode.indexOf('/');
      const portStr = slash2 < 0 ? afterCode : afterCode.slice(0, slash2);
      const port = parsePort(portStr);
      if (!port) return json({ error: 'invalid port' }, 400);
      const guestPath = slash2 < 0 ? '/' : '/' + afterCode.slice(slash2 + 1);

      // Forward to DO with pathname "/http" + guest path as search/suffix.
      const headers = new Headers(request.headers);
      headers.set('X-Tunnel-Port', String(port));
      const innerUrl = 'http://do/http' + guestPath + (url.search || '');
      return env.PORT_SESSION.get(env.PORT_SESSION.idFromName(code)).fetch(
        new Request(innerUrl, {
          method: request.method,
          headers,
          body: (request.method === 'GET' || request.method === 'HEAD') ? null : request.body,
        }),
      );
    }


    if (url.pathname === '/port/status' && request.method === 'GET') {
      let code = normalizeCode(url.searchParams.get('code'));
      if (!code && url.searchParams.get('token') && env.TUNNEL_SECRET) {
        const payload = await verifyToken(url.searchParams.get('token'), env.TUNNEL_SECRET);
        if (!payload) return json({ error: 'Invalid or expired token' }, 401);
        code = payload.code;
      }
      if (!code) return json({ error: 'missing code' }, 400);
      const res = await env.PORT_SESSION.get(env.PORT_SESSION.idFromName(code)).fetch(
        new Request('http://do/status'),
      );
      const data = await res.json();
      return json({ ...data, code });
    }

    // POST /port/unregister  { code }
    if (url.pathname === '/port/unregister' && request.method === 'POST') {
      const body = await request.json().catch(() => ({}));
      const code = normalizeCode(body.code);
      if (!code) return json({ error: 'missing code' }, 400);
      const res = await env.PORT_SESSION.get(env.PORT_SESSION.idFromName(code)).fetch(
        new Request('http://do/unregister', { method: 'POST' }),
      );
      return json(await res.json());
    }

    // GET /port/debug?code=XXXX
    if (url.pathname === '/port/debug' && request.method === 'GET') {
      const code = normalizeCode(url.searchParams.get('code'));
      if (!code) return json({ error: 'missing code' }, 400);
      const res = await env.PORT_SESSION.get(env.PORT_SESSION.idFromName(code)).fetch(
        new Request('http://do/debug'),
      );
      return json({ code, ...(await res.json()) });
    }

    return json({ error: 'not found' }, 404);
  },
};
