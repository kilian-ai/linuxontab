# tunnel-server

Node port of `relay-tunnel/` (Cloudflare Worker). Single process, in-memory
sessions. Used for local dev on the Mac and for production on Fly
(Cloudflare Durable Object free-tier quota wall made the Worker unreliable).

## Endpoints

Same as the Worker at `tunnel.linuxontab.com`:

- `GET  /health`
- `POST /port/register`          `{ code?, ports:[22,8080,...] }` → `{ code, token, ports, relay }`
- `WS   /port/guest?code=X&port=N`
- `WS   /port/client?code=X&port=N`
- `GET  /port/http/CODE/PORT/path`  (HTTP-over-WS proxy, CORS-enabled)
- `GET  /port/status?code=X`
- `POST /port/unregister`        `{ code }`
- `GET  /port/debug?code=X`

## Run locally

```sh
cd tunnel-server
npm install
node server.js       # listens on :8787 by default

# guest (in same browser/host, pointed at local server):
TUNNEL_BASE=http://localhost:8787 TUNNEL_WS=ws://localhost:8787 \
  sh <(curl -sS https://linuxontab.com/local/tunnel-up.sh)

# client:
TUNNEL_BASE=http://localhost:8787 \
  sh <(curl -sS https://linuxontab.com/local/tunnel-listen.sh) ARXN
```

## Deploy to Fly

```sh
cd tunnel-server
fly launch --no-deploy          # one-time — edit fly.toml app name if needed
fly deploy
fly certs add tunnel.linuxontab.com
# Set DNS: tunnel.linuxontab.com CNAME → linuxontab-tunnel.fly.dev
```

## Env

| Var | Purpose |
|---|---|
| `PORT` | Listen port (default 8787) |
| `TUNNEL_SECRET` | HMAC key for signed tokens (optional) |
| `TUNNEL_PUBLIC_URL` | `wss://...` URL returned to clients (defaults to request Host) |

## Notes

- In-memory only. Restart = all sessions gone. Idle sessions GC'd after 30min.
- Single process. Scaling horizontally requires sticky routing per `code`.
- `/port/http/...` is single-shot — relies on guest `tunnel-up.sh` respawn loop.
