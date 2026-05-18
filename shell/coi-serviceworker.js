/* coi-serviceworker — injects Cross-Origin-Isolation headers so that
   SharedArrayBuffer is available on GitHub Pages and other static hosts.
   Based on https://github.com/gzuidhof/coi-serviceworker (MIT licence).
   Hosted here so we don't depend on an external CDN. */

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('fetch', function (e) {
  // Only intercept same-origin document / script navigation requests.
  // Don't intercept no-cors requests for cross-origin resources —
  // those need Cross-Origin-Resource-Policy on the resource itself.
  if (e.request.cache === 'only-if-cached' && e.request.mode !== 'same-origin') {
    return;
  }

  e.respondWith(
    fetch(e.request).then(function (response) {
      if (response.status === 0) return response;

      const newHeaders = new Headers(response.headers);
      newHeaders.set('Cross-Origin-Opener-Policy', 'same-origin');
      newHeaders.set('Cross-Origin-Embedder-Policy', 'require-corp');
      newHeaders.set('Cross-Origin-Resource-Policy', 'cross-origin');

      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: newHeaders,
      });
    }).catch(function (e) {
      console.error('[coi-sw] fetch failed:', e);
      throw e;
    })
  );
});
