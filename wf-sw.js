// LinuxOnTab wf-live media service worker.
//
// The wf-live iframe shims window.fetch so the SPA's /api/* calls ride the
// in-page slirp bridge into the guest — but a <video> element's requests are
// native browser HTTP and never touch that shim, so /api/stream/* fell through
// to the dev server and 404'd (playback impossible). This SW intercepts
// /api/stream/* for the whole origin (scope "/", registered by wf-live), asks
// the wf-live client to run the request over the bridge, and answers the media
// stack with the returned bytes.
//
// Ranges are clamped to CHUNK so one <video> request never buffers tens of MB
// through the bridge before first byte; the browser follows a short 206 with
// the next range on its own. Everything that isn't /api/stream/* is left to
// the network untouched.

const STREAM_RE = /^\/api\/stream\/(\d+)/;
// Small chunks: each SMB read runs INLINE on the guest server's event loop
// (sitecustomize shim), blocking everything else — keep the block window short.
const CHUNK = 512 * 1024;
const BRIDGE_TIMEOUT = 120000;

// LAN media gateway (wf-media-gw.py on the SMB host): serves the same files
// over plain HTTP at wire speed. The guest's bulk-RX path caps at ~30 KB/s,
// so media bytes bypass it entirely whenever the gateway answers; the bridge
// path below stays as the fallback. Configured via the SW's own registration
// URL: /wf-sw.js?gw=http%3A%2F%2F192.168.0.55%3A8901
const GATEWAY = new URL(self.location.href).searchParams.get('gw') || null;
const filenameCache = new Map();   // item id -> filename
let gatewayDownUntil = 0;          // backoff timestamp after a gateway failure

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

async function bridgeClient(event) {
  let c = event.clientId && await self.clients.get(event.clientId);
  if (c) return c;
  const all = await self.clients.matchAll({ includeUncontrolled: true, type: 'window' });
  return all.find(x => x.url.includes('wf-live')) || all[0] || null;
}

// Raw bridge round-trip: {status, headers, body(ArrayBuffer)} or null.
async function bridgeRequest(event, path, headers) {
  const client = await bridgeClient(event);
  if (!client) return null;
  const chan = new MessageChannel();
  const reply = new Promise((res) => {
    chan.port1.onmessage = (ev) => res(ev.data);
    setTimeout(() => res(null), BRIDGE_TIMEOUT);
  });
  client.postMessage({ type: 'lot-stream', path, headers: headers || {} }, [chan.port2]);
  return reply;
}

async function itemFilename(event, id) {
  if (filenameCache.has(id)) return filenameCache.get(id);
  const r = await bridgeRequest(event, '/api/library/items/' + id, {});
  if (!r || r.status !== 200 || !r.body) return null;
  try {
    const name = JSON.parse(new TextDecoder().decode(r.body)).filename || null;
    if (name) filenameCache.set(id, name);
    return name;
  } catch (e) {
    return null;
  }
}

// Debug: SW console output is hard to reach; post to the dev server's /log.
function swlog(msg) {
  try { fetch('/log', { method: 'POST', body: '[wf-sw] ' + msg }).catch(() => {}); } catch (e) {}
}

// Direct LAN fetch — streams at wire speed, no clamping needed.
async function viaGateway(event, id, origRange) {
  if (!GATEWAY || Date.now() < gatewayDownUntil) { swlog('gw skip gw=' + GATEWAY + ' downFor=' + Math.max(0, gatewayDownUntil - Date.now())); return null; }
  const name = await itemFilename(event, id);
  if (!name) { swlog('gw no-filename id=' + id); return null; }
  const ctl = new AbortController();
  const connectTimer = setTimeout(() => ctl.abort(), 15000);
  const t0 = Date.now();
  swlog('gw fetch START ' + name + ' range=' + origRange);
  try {
    const resp = await fetch(GATEWAY + '/media/' + encodeURIComponent(name), {
      headers: origRange ? { range: origRange } : {},
      mode: 'cors',
      signal: ctl.signal,
    });
    clearTimeout(connectTimer);
    swlog('gw fetch ' + name + ' range=' + origRange + ' -> ' + resp.status + ' in ' + (Date.now() - t0) + 'ms');
    if (resp.status === 200 || resp.status === 206 || resp.status === 416) return resp;
    return null;   // 404 = filename mismatch → let the bridge serve it
  } catch (e) {
    clearTimeout(connectTimer);
    swlog('gw fetch ERR ' + (e && e.message));
    gatewayDownUntil = Date.now() + 30000;
    return null;
  }
}

async function viaBridge(event, path, range) {
  const client = await bridgeClient(event);
  console.log('[wf-sw]', path, range, 'clientId=', event.clientId, 'client=', client && client.url);
  if (!client) return new Response('no wf-live bridge client', { status: 502 });
  const chan = new MessageChannel();
  const reply = new Promise((res) => {
    chan.port1.onmessage = (ev) => res(ev.data);
    setTimeout(() => res(null), BRIDGE_TIMEOUT);
  });
  client.postMessage({ type: 'lot-stream', path, headers: { range } }, [chan.port2]);
  const r = await reply;
  if (!r || !r.status) return new Response('bridge timeout', { status: 504 });
  const body = r.body ? new Uint8Array(r.body) : new Uint8Array(0);
  const h = new Headers(r.headers || {});
  // A timed-out bridge read can hand back fewer bytes than the guest declared;
  // shrink the headers to what we actually have so the browser just re-requests
  // the remainder instead of hanging on a short body.
  const cr = /bytes (\d+)-(\d+)\/(\d+|\*)/.exec(h.get('content-range') || '');
  if (cr && body.length > 0 && body.length < (+cr[2] - +cr[1] + 1)) {
    h.set('content-range', `bytes ${cr[1]}-${+cr[1] + body.length - 1}/${cr[3]}`);
  }
  if (body.length === 0 && r.status < 300) return new Response('empty bridge read', { status: 502 });
  h.set('content-length', String(body.length));
  return new Response(body, { status: r.status, headers: h });
}

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  const sm = STREAM_RE.exec(url.pathname);
  if (url.origin !== self.location.origin || !sm) return;
  if (event.request.method !== 'GET' && event.request.method !== 'HEAD') return;
  const origRange = event.request.headers.get('range') || '';
  event.respondWith((async () => {
    // Fast path: LAN gateway streams the file directly (media bytes never
    // touch the guest). Fallback: clamped chunks over the in-guest bridge.
    const direct = await viaGateway(event, sm[1], origRange);
    if (direct) return direct;
    const m = /bytes=(\d+)-(\d*)/.exec(origRange);
    const start = m ? +m[1] : 0;
    let end = m && m[2] ? +m[2] : start + CHUNK - 1;
    if (end - start + 1 > CHUNK) end = start + CHUNK - 1;
    return viaBridge(event, url.pathname + url.search, `bytes=${start}-${end}`);
  })());
});
