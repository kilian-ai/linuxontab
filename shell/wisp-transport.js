// shell/wisp-transport.js
//
// openWispTransport(url) — the socket WispSlirp runs on.
//
// WispSlirp only ever uses seven members of its socket: binaryType, onopen,
// onmessage, onclose, onerror, send() and close(). That is already a
// duck-typed WebSocket; this makes the choice explicit so a backend that is
// not reachable by URL can be used. For ws:// and wss:// it returns a real
// WebSocket and nothing changes.
//
// The other scheme is vnet:<port>, a virtual-loopback port in the page (the
// `vnet` object from github.com/0magnet/bottle). It exists because a Wisp
// backend running INSIDE the browser cannot be a WebSocket at all:
//
//   - a WebSocket server needs to listen, and a page cannot listen;
//   - a service worker cannot intercept ws:// or wss://, so even a
//     page-served endpoint could not be reached.
//
// So an in-page backend is reached by dialing it directly, and Wisp's packets
// are length-prefixed to keep the message boundaries a byte stream does not
// have. The prefix is a uint32 little-endian, matching every other multi-byte
// field in Wisp.
//
// vnet lives in one realm. A guest running in a same-origin iframe of the
// page that hosts the backend reaches it through window.parent, which is why
// findVnet looks up as well as in.
(function () {
	'use strict';
	if (globalThis.openWispTransport) return;

	// A frame longer than this is a desynchronized stream rather than a real
	// packet, and there is no way to resynchronize a length-prefixed stream
	// once it is lost — so the socket closes instead of guessing.
	var MAX_FRAME = 16 * 1024 * 1024;

	function findVnet() {
		if (globalThis.vnet) return globalThis.vnet;
		// Cross-origin access throws rather than returning undefined, so each
		// lookup is guarded separately.
		try {
			if (window.parent && window.parent !== window && window.parent.vnet) return window.parent.vnet;
		} catch (_) { /* cross-origin parent */ }
		try {
			if (window.opener && window.opener.vnet) return window.opener.vnet;
		} catch (_) { /* cross-origin opener */ }
		return null;
	}

	function concat(a, b) {
		if (a.length === 0) return b;
		if (b.length === 0) return a;
		var out = new Uint8Array(a.length + b.length);
		out.set(a, 0);
		out.set(b, a.length);
		return out;
	}

	// VnetSocket presents a virtual-loopback conn with the surface WispSlirp
	// uses. Event handlers are fired asynchronously, as a real WebSocket's
	// are, so a caller that assigns them after construction still sees open.
	function VnetSocket(port) {
		var self = this;
		this.binaryType = 'arraybuffer';
		this.readyState = 0; // CONNECTING
		this.onopen = null;
		this.onmessage = null;
		this.onclose = null;
		this.onerror = null;

		var v = findVnet();
		var id = -1;
		var rx = new Uint8Array(0);
		var closed = false;

		function fail(why) {
			if (closed) return;
			closed = true;
			self.readyState = 3; // CLOSED
			if (self.onerror) self.onerror({ type: 'error', message: why });
			if (self.onclose) self.onclose({ type: 'close', code: 1006, reason: why });
		}

		function finish(code, reason) {
			if (closed) return;
			closed = true;
			self.readyState = 3;
			if (self.onclose) self.onclose({ type: 'close', code: code, reason: reason || '' });
		}

		// Drain everything readable, emitting each whole frame.
		function pump() {
			if (closed) return;
			for (;;) {
				var chunk = v.recv(id, 'a');
				if (!chunk) break;
				rx = concat(rx, chunk);
			}
			for (;;) {
				if (rx.length < 4) break;
				var len = rx[0] | (rx[1] << 8) | (rx[2] << 16) | (rx[3] << 24);
				len = len >>> 0;
				if (len > MAX_FRAME) {
					fail('wisp frame of ' + len + ' bytes: stream desynchronized');
					return;
				}
				if (rx.length < 4 + len) break;
				var frame = rx.slice(4, 4 + len);
				rx = rx.subarray(4 + len);
				if (self.onmessage) self.onmessage({ type: 'message', data: frame.buffer });
			}
			if (v.eof(id, 'a')) { finish(1000, 'peer closed'); return; }
			v.onReadable(id, 'a', pump);   // one-shot, so it is re-armed here
		}

		// send and close are defined before any early return, so the object
		// always has the full socket shape. A caller that never sees onopen
		// still calls close() on its way down, and a half-built object would
		// throw a TypeError there instead of closing quietly.
		this.send = function (data) {
			if (closed || id < 0) return;
			var body = data instanceof Uint8Array ? data
				: (data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer || data));
			var out = new Uint8Array(4 + body.length);
			var n = body.length;
			out[0] = n & 0xff; out[1] = (n >>> 8) & 0xff;
			out[2] = (n >>> 16) & 0xff; out[3] = (n >>> 24) & 0xff;
			out.set(body, 4);
			if (!v.send(id, 'a', out)) finish(1006, 'peer gone');
		};

		this.close = function () {
			if (closed) return;
			closed = true;
			self.readyState = 3;
			if (v && id >= 0) {
				try { v.close(id, 'a'); } catch (_) { /* already gone */ }
			}
		};

		if (!v) {
			setTimeout(function () { fail('no vnet in this page'); }, 0);
			return;
		}
		id = v.dial(port, '');
		if (id < 0) {
			setTimeout(function () { fail('connection refused: 127.0.0.1:' + port); }, 0);
			return;
		}

		setTimeout(function () {
			if (closed) return;
			self.readyState = 1; // OPEN
			if (self.onopen) self.onopen({ type: 'open' });
			pump();
		}, 0);
	}

	// openWispTransport returns the socket for a Wisp endpoint. Anything that
	// is not vnet: is a URL a real WebSocket can open, which keeps the default
	// path byte-identical to what it was.
	globalThis.openWispTransport = function (url) {
		var m = /^vnet:(?:\/\/)?(\d+)\/?$/.exec(String(url));
		if (!m) return new WebSocket(url);
		return new VnetSocket(parseInt(m[1], 10));
	};
})();
