// sw-guest-proxy.js — reverse proxy that renders GUEST web apps in the page.
//
// The web-view panel points an iframe at  <base>/guest/<port>/ . This worker
// intercepts every request under that prefix (and every absolute-path request
// *referred* by a guest-framed document — Flask templates link site-absolute
// URLs like /static/x.css) and forwards it to the shell page over a one-shot
// MessageChannel. The page speaks HTTP/1.1 over an injected TCP connection
// straight into the wasm guest (same primitive as the VNC view / wf-live
// bridge) and replies with status + headers + body.
//
// Stateless by design: no handshake, no global map — each fetch event finds
// the shell client and carries its own reply port, so the browser can kill
// and restart this worker at any time with zero consequences.
//
// Everything that is NOT guest traffic gets no respondWith() at all: the
// browser's default network path stays untouched (the 512 MB rootfs download
// never flows through here).

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

// Matches both deploy layouts: /guest/8080/... (Pages, page at /) and
// /shell/guest/8080/... (local serve.sh, page at /shell/wasm.html).
const GUEST_RE = /^(.*\/guest\/(\d{2,5}))(\/.*)?$/;

function textResponse(status, msg) {
  return new Response(msg + '\n', {
    status,
    headers: {
      'content-type': 'text/plain; charset=utf-8',
      'cross-origin-embedder-policy': 'require-corp',
      'cross-origin-resource-policy': 'same-origin',
      'cache-control': 'no-store',
    },
  });
}

async function findShell() {
  const cs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  const shells = cs.filter((c) => !GUEST_RE.test(new URL(c.url).pathname));
  shells.sort((a, b) =>
    (b.focused - a.focused) ||
    ((b.visibilityState === 'visible') - (a.visibilityState === 'visible')));
  return shells[0] || null;
}

async function proxy(request, port, pathq, prefix) {
  const shell = await findShell();
  if (!shell) return textResponse(502, 'guest proxy: shell page not found — keep the LinuxOnTab tab open.');
  const body = (request.method === 'GET' || request.method === 'HEAD')
    ? null
    : await request.arrayBuffer();
  const headers = {};
  for (const [k, v] of request.headers) headers[k] = v;

  const reply = await new Promise((resolve) => {
    const ch = new MessageChannel();
    // The shell serializes guest requests and retries stalled ones (6 x 20 s);
    // a page load queues ~6 assets behind each other, so a 30 s deadline used
    // to 504 the tail of every slow load (blank app). Wait for the engine.
    const timer = setTimeout(() => resolve(null), 150000);
    ch.port1.onmessage = (ev) => { clearTimeout(timer); resolve(ev.data); };
    const msg = { type: 'guest-proxy', port, method: request.method, path: pathq, mode: request.mode, headers, body, prefix };
    shell.postMessage(msg, body ? [ch.port2, body] : [ch.port2]);
  });

  if (!reply) return textResponse(504, 'guest proxy: request timed out (is the guest server running?)');
  if (reply.error) return textResponse(502, 'guest proxy: ' + reply.error);

  const h = new Headers();
  for (const [k, v] of (reply.headers || [])) { try { h.set(k, v); } catch (_) {} }
  h.set('cross-origin-embedder-policy', 'require-corp');
  h.set('cross-origin-resource-policy', 'same-origin');
  h.set('cache-control', 'no-store');
  let status = reply.status || 502;
  if (status < 200 || status > 599) status = 502;
  const respBody = (status === 204 || status === 304 || request.method === 'HEAD') ? null : reply.body;
  return new Response(respBody, { status, headers: h });
}

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin) return;         // external → browser default

  // Direct hit under the /guest/<port>/ prefix.
  const m = url.pathname.match(GUEST_RE);
  if (m) {
    e.respondWith(proxy(e.request, +m[2], (m[3] || '/') + url.search, m[1]));
    return;
  }

  // Site-absolute request coming FROM a guest-framed document (its referrer
  // carries the prefix). Subresources are proxied in place; navigations are
  // 307'd back under the prefix (307 keeps method + body for form POSTs).
  const ref = e.request.referrer || '';
  if (ref.startsWith(self.location.origin + '/') && ref.includes('/guest/')) {
    const rm = new URL(ref).pathname.match(GUEST_RE);
    if (rm) {
      const base = rm[1];                                  // e.g. /guest/8080
      if (e.request.mode === 'navigate') {
        e.respondWith(new Response(null, {
          status: 307,
          headers: { location: base + url.pathname + url.search },
        }));
      } else {
        e.respondWith(proxy(e.request, +rm[2], url.pathname + url.search, base));
      }
    }
  }
  // Everything else: no respondWith → untouched.
});
