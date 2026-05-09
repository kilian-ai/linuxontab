Guest-side dev server (live-edit JS from inside the guest)
=========================================================

Overview
--------
This folder contains a tiny dev-server scaffold designed to run *inside the v86 guest*.
Run the server in the guest and expose its TCP port via the existing tunnel/relay so
the parent browser page can load JavaScript directly from the guest during development.

Two server options are provided:
- `server-express.js` — Node/Express static server with CORS + WebSocket change notifications (recommended).
- `server-py.py`    — small Python3 fallback that serves static files and adds an `Access-Control-Allow-Origin: *` header.

Files
-----
- `server-express.js` — Node express static server (uses `express`, `cors`, `ws`, `chokidar`).
- `server-py.py`      — Python fallback static server with CORS header.
- `guest-dev-server.sh` — wrapper to start Node server if available, otherwise Python fallback. Usage documented below.

How it works
------------
1. Start the dev server inside the guest and point it at a directory containing your JS files (e.g. `/usr/local/dev`).
2. Expose the guest port through the relay so your browser can reach it. You can either:
   - Use `tunnel-up.sh` with the desired port (e.g. `sh <(curl -sS https://linuxontab.com/local/tunnel-up.sh) 3000`) so the guest will spawn websocat bridges and the relay will assign a public mapping.
   - Or manually register a code via the relay API and start websocat bridges.
3. From the browser page load the dev script via the relay's HTTP endpoint: `https://linuxontab-tunnel.fly.dev/port/http/<CODE>/<PORT>/path/to/file.js` (replace `<CODE>` and `<PORT>` with the registration values). You can inject a `<script>` tag dynamically to load the changed JS.

Quick start (guest)
-------------------
1. Ensure `node` or `python3` exists in the guest. If not, install via `apk add nodejs npm` or `apk add python3`.
2. Copy your editable JS into `/usr/local/dev` (choose any path you like).
3. Start the server (recommended Node):

   # inside guest
   cd /usr/local/dev
   # if Node packages missing, install once
   npm init -y
   npm i express cors ws chokidar
   PORT=3000 HOST_DIR=/usr/local/dev node /usr/local/dev/server-express.js

   # or use the wrapper
   /usr/local/dev/guest-dev-server.sh 3000 /usr/local/dev

4. Expose the port via the relay (use tunnel-up.sh to auto-manage websocat):

   sh <(curl -sS https://linuxontab.com/local/tunnel-up.sh) 3000

   The script prints a 4-character code (or write it to `/tmp/tunnel.code`), and the relay will assign a public port.

Quick start (browser)
---------------------
Once the guest has registered and the relay assigned a public mapping, get the `code` and assigned public port from `/port/status?code=CODE` or use the UI tunnels panel. Then inject a script tag into the page:

```js
// run in browser console or paste into a small bookmarklet
const CODE = 'ABCD'; // 4-char code
const DEV_PORT = 3000; // port inside guest
const path = '/bundle.js'; // file path served by the dev server
const url = `https://linuxontab-tunnel.fly.dev/port/http/${CODE}/${DEV_PORT}${path}`;
const s = document.createElement('script');
s.src = url;
s.async = true;
document.head.appendChild(s);
```

Live-reload (optional)
-----------------------
The Node server exposes a WebSocket endpoint at `/ws` and emits JSON messages `{event,path}` on changes. You can open a WebSocket from the browser to listen for changes and re-load the affected module or reload the page.

Example client-side reload snippet:

```js
const wsUrl = `wss://linuxontab-tunnel.fly.dev/port/client?code=${CODE}&port=${DEV_PORT}&path=/ws`;
const ws = new WebSocket(wsUrl);
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  console.log('dev change', msg);
  // crude: reload the page to pick up changes
  location.reload();
};
```

Security & notes
----------------
- The relay makes the guest port reachable via a public host and port — limit exposure only when developing. Use tunnel codes and stop the dev server when finished.
- If you require authentication, add a simple token check in `server-express.js`.
- If the guest boots into a snapshot on each reload, ensure you run the wrapper after boot (or add it to a startup hook in the guest environment).

Host <-> guest sync (edit on host, push into guest)
-----------------------------------------------
This repo now includes a host-side watcher `host-sync.js` that watches a local folder on your Mac and pushes edits into the guest dev server via the relay HTTP proxy. The guest server exposes `POST /_sync` which writes files into the guest's host directory.

Quick host setup
1. Register or obtain the tunnel code and port for your guest dev server (see `tunnel-up.sh`).
2. On your host (mac), install dependencies and run the watcher from the workspace folder:

```bash
cd local/dev-sync
npm install
# run: replace CODE and PORT with the values printed by tunnel-up.sh
node host-sync.js --code ABCD --port 3000 --watch /path/to/edit --token YourSecretOptional
```

Notes
- The host watcher uses `POST https://linuxontab-tunnel.fly.dev/port/http/<CODE>/<PORT>/_sync` to send file writes and deletes.
- For safety set `DEV_SYNC_TOKEN` in the guest environment and pass `--token` when starting `host-sync.js` so only your host can write into the guest.

If you want, I can:
- add a tiny helper to auto-run `tunnel-up.sh` from the guest and echo the 4-char code into `/tmp/tunnel.code` so you can wire `host-sync.js` quickly, and
- add a small example that injects the dev script into `shell/index.html` for quicker reloads.
Convenience scripts added
-------------------------
1. `guest-dev-start-auto.sh` — start dev server in the guest, register with the relay and spawn websocat bridge loops; writes `/tmp/tunnel.json` and `/tmp/tunnel.code`.
   Usage (guest):

```sh
# inside guest, in the directory containing your editable files
/usr/local/dev/guest-dev-start-auto.sh 3000 /usr/local/dev YourOptionalToken
```

2. `host-dev-start.sh` — host helper to install deps and start the watcher that pushes edits into the guest.
   Usage (host mac):

```bash
cd local/dev-sync
# run with CODE and PORT from /tmp/tunnel.json printed by the guest
./host-dev-start.sh ABCD 3000 /path/to/edit YourOptionalToken
```

3. `client-inject-snippet.js` — small browser snippet to inject the dev script and listen for `/ws` reload events. Update `CODE` and `DEV_PORT` constants before use.

End-to-end flow (summary)
------------------------
1. On the guest: copy dev server files into `/usr/local/dev` and run `guest-dev-start-auto.sh`.
2. The script starts the dev server, registers with the relay and spawns websocat bridges. It writes `/tmp/tunnel.json` containing `code` and `port`.
3. On the host: run `host-dev-start.sh CODE PORT WATCH_DIR [TOKEN]` using the `code` and `port` from the guest.
4. Edit files on your host; changes are pushed to the guest's `HOST_DIR` and the dev server notifies via `/ws` so the browser can reload.

