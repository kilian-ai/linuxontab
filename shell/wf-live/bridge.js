// LinuxOnTab ⇄ guest HTTP bridge — renders a guest web app in the page's
// "output: browser" panel, with NO external relay.
//
// The page's slirp can open a TCP connection straight into the guest via
// injectConnect(port, adapter) — the same primitive the VNC view uses. We
// speak HTTP/1.1 over that, so the app's /api/* fetches (proxied from the
// iframe by wf-live/index.html) hit the guest's uvicorn in-process.
//
// Usage from the page console:
//   await import('/shell/wf-live/bridge.js'); await lotWebFuse();
//
// Two things matter for reliability on this kernel:
//  * SERIALIZE requests. The app fires several fetches at once on mount, and
//    concurrent injected connections wedge the guest's uvicorn (it ends up
//    holding the port with data stuck in recv-Q, unkillable → needs a reboot).
//  * WARM the path. The first injected connection after idle costs ~1.5 s
//    (gateway ARP); after that requests land in ~10 ms. A slow ping keeps it hot.

const GUEST_PORT = 8080;

export function parseHttp(raw) {
  let idx = -1;
  for (let i = 0; i + 3 < raw.length; i++) {
    if (raw[i] === 13 && raw[i + 1] === 10 && raw[i + 2] === 13 && raw[i + 3] === 10) { idx = i; break; }
  }
  if (idx < 0) return { status: 0, headers: {}, body: new Uint8Array(0) };
  const lines = new TextDecoder().decode(raw.subarray(0, idx)).split('\r\n');
  const status = parseInt((lines[0].split(' ')[1] || '0'), 10);
  const headers = {};
  for (let i = 1; i < lines.length; i++) {
    const c = lines[i].indexOf(':');
    if (c > 0) headers[lines[i].slice(0, c).trim().toLowerCase()] = lines[i].slice(c + 1).trim();
  }
  return { status, headers, body: raw.subarray(idx + 4) };
}

// One request over one injected TCP connection. Resolves as soon as
// Content-Length bytes of body have arrived (or on FIN / timeout).
export function guestSend(reqBytes, timeoutMs = 12000, port = GUEST_PORT) {
  const slirp = window.__slirp;
  return new Promise((resolve) => {
    const chunks = []; let total = 0, done = false, headerLen = -1, contentLen = -1;
    const cat = () => { const o = new Uint8Array(total); let p = 0; for (const c of chunks) { o.set(c, p); p += c.length; } return o; };
    const fin = () => {
      if (done) return; done = true;
      resolve(parseHttp(cat()));
      // ALWAYS tear down the injected connection (injectConnect's onclose hook
      // RSTs the guest side). Without this, a timed-out request leaves an
      // ESTABLISHED conn the guest server holds forever — they pile up until
      // uvicorn wedges (observed: 53 stuck conns, Recv-Q full, needs kill -9).
      setTimeout(() => { try { adapter.onclose && adapter.onclose(); } catch (e) {} }, 0);
    };
    const adapter = {
      binaryType: 'arraybuffer',
      readyState: WebSocket.OPEN,   // must be OPEN or slirp won't forward guest data
      send(g) {
        const u = g instanceof Uint8Array ? g : new Uint8Array(g);
        chunks.push(u); total += u.length;
        if (headerLen < 0) {
          const raw = cat();
          for (let i = 0; i + 3 < raw.length; i++) {
            if (raw[i] === 13 && raw[i + 1] === 10 && raw[i + 2] === 13 && raw[i + 3] === 10) {
              headerLen = i + 4;
              contentLen = parseInt(parseHttp(raw).headers['content-length'] || '-1', 10);
              break;
            }
          }
        }
        if (contentLen >= 0 && total >= headerLen + contentLen) fin();
      },
      close() { fin(); }
    };
    slirp.injectConnect(port, adapter);
    // injectConnect sets adapter.onmessage synchronously and buffers our bytes
    // until the TCP handshake completes.
    if (adapter.onmessage) adapter.onmessage({ data: reqBytes.buffer.slice(reqBytes.byteOffset, reqBytes.byteOffset + reqBytes.byteLength) });
    setTimeout(fin, timeoutMs);
  });
}

async function rawRequest(method, path, body, { retries = 8, timeoutMs = 12000, headers = null } = {}) {
  const enc = new TextEncoder();
  let head = method + ' ' + path + ' HTTP/1.1\r\nHost: guest\r\nConnection: close\r\n';
  if (headers) for (const k in headers) if (headers[k] != null) head += k + ': ' + headers[k] + '\r\n';
  if (body && body.length) head += 'Content-Type: application/json\r\nContent-Length: ' + body.length + '\r\n';
  head += '\r\n';
  const hb = enc.encode(head);
  const req = (body && body.length)
    ? (() => { const m = new Uint8Array(hb.length + body.length); m.set(hb); m.set(body, hb.length); return m; })()
    : hb;
  for (let i = 0; i < retries; i++) {
    const r = await guestSend(req, timeoutMs);
    if (r.status >= 200) return r;          // cold connections need a retry or two
    await new Promise(x => setTimeout(x, 100));
  }
  return { status: 0, headers: {}, body: new Uint8Array(0) };
}

// Serialized: exactly one injected connection in flight at a time.
let queue = Promise.resolve();
let inFlight = 0;
export function guestRequest(...args) {
  inFlight += 1;
  const run = () => rawRequest(...args);
  const p = queue.then(run, run);
  queue = p.then(() => { inFlight -= 1; }, () => { inFlight -= 1; });
  return p;
}

// What the iframe's fetch-shim calls.
export async function guestFetchResponse(path, init) {
  init = init || {};
  const method = (init.method || 'GET').toUpperCase();
  let body = null;
  if (init.body != null) body = new TextEncoder().encode(typeof init.body === 'string' ? init.body : JSON.stringify(init.body));
  const hdrs = {};
  if (init.headers) {
    if (typeof init.headers.forEach === 'function') init.headers.forEach((v, k) => { hdrs[k] = v; });
    else for (const k in init.headers) hdrs[k] = init.headers[k];
  }
  // Media chunks (relayed here by the wf-sw.js service worker) come from SMB
  // over the LAN WISP relay — allow far longer than an API call.
  const isStream = /^\/api\/stream\//.test(path);
  const r = await guestRequest(method, path, body, {
    retries: isStream ? 2 : 8,
    timeoutMs: isStream ? 45000 : 12000,
    headers: hdrs,
  });
  (window.__apiLog = window.__apiLog || []).push(path + ' -> ' + r.status);
  const headers = new Headers();
  for (const k in r.headers) { try { headers.set(k, r.headers[k]); } catch (e) {} }
  return new Response(r.body.length ? r.body : null, {
    status: r.status || 502, statusText: r.status ? 'OK' : 'Bad Gateway', headers
  });
}

export async function warmUp(n = 4) {
  const times = [];
  for (let i = 0; i < n; i++) {
    const t = performance.now();
    const r = await guestRequest('GET', '/api/health', null, { retries: 6, timeoutMs: 6000 });
    times.push(r.status + '/' + Math.round(performance.now() - t) + 'ms');
  }
  return times;
}

export function keepWarm(ms = 3000) {
  if (window.__keepWarm) clearInterval(window.__keepWarm);
  window.__keepWarm = setInterval(() => {
    // Only ping when idle. WebFuse's sync handlers run inline on uvicorn's
    // event loop, so during a slow SMB-backed request the server can't accept
    // anything — pings fired then just stack up as extra connections.
    if (inFlight > 0) return;
    guestRequest('GET', '/api/health', null, { retries: 1, timeoutMs: 4000 }).catch(() => {});
  }, ms);
}

export function showPanel(url = '/shell/wf-live/index.html', label = 'WebFuse — live from guest (127.0.0.1:8080 via in-page slirp, no relay)') {
  const g = id => document.getElementById(id);
  try { if (typeof setOutputMode === 'function') setOutputMode('browser'); } catch (e) {}
  if (g('term')) g('term').hidden = true;
  if (g('cgi-view')) g('cgi-view').hidden = false;
  if (g('output-mode')) g('output-mode').textContent = 'output: browser';
  if (g('cgi-text-wrap')) g('cgi-text-wrap').hidden = true;
  if (g('cgi-meta')) g('cgi-meta').textContent = label;
  const f = g('cgi-frame');
  f.hidden = false;
  window.__apiLog = [];
  f.src = url + (url.includes('?') ? '&' : '?') + 'r=' + Date.now();
  return f.src;
}

// One-shot: stop the relay tunnel (its pool churn competes with injectConnect),
// warm the path, expose the bridge, then render the app in the panel.
export async function start({ url, quiet = true } = {}) {
  if (!window.__slirp) throw new Error('guest not booted (window.__slirp missing)');
  if (quiet) { try { window.stopJsTunnel && window.stopJsTunnel(); } catch (e) {} }
  window.__guestFetchResponse = guestFetchResponse;   // the iframe shim looks this up on window.parent
  window.__guestRequest = guestRequest;
  const warm = await warmUp();
  keepWarm();
  const src = showPanel(url);
  return { warm, src };
}

window.lotWebFuse = start;
export default start;
