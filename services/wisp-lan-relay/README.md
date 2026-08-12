# wisp-lan-relay

A minimal, dependency-free **WISP v1** relay (raw WebSocket, pure Python stdlib)
you run **inside your LAN** so the LinuxOnTab wasm guest can reach LAN-only
services — e.g. an SMB share on a NAS — that the public cloud relay
(`linuxontab-net.fly.dev`) can't route to.

## Why

The guest's NIC egresses through a WISP WebSocket relay. The default cloud relay
dials targets *from the cloud*, so it has no route to a private address like
`192.168.x.x`. The browser can reach your LAN but can't make raw TCP
connections, so SMB can't piggyback on it. Running this relay on a LAN box
(e.g. the NAS that hosts the share) makes egress happen from inside the network.

## Run

On a host that can reach the target (e.g. the SMB server itself, so it dials
`localhost:445`):

```sh
python3 wisp-relay.py 4000        # listens on 0.0.0.0:4000, path /wisp
```

Only stdlib is needed — no pip. `curl http://<host>:4000/health` returns `ok`.

## Point the guest at it

Boot LinuxOnTab with the `?wisp=` override (added to `shell/wasm.html`):

```
http://<devserver>/shell/wasm.html?autoboot&wisp=ws://<lan-host>:4000/wisp
```

The guest now reaches the LAN (and the internet) through this relay. Verify from
the guest shell:

```sh
python3 -c "import socket; socket.create_connection(('<lan-host>',445),timeout=5); print('ok')"
```

## Protocol

Implements [WISP v1](https://github.com/MercuryWorkshop/wisp-protocol) — the same
protocol `WispSlirp` in `shell/wasm.html` speaks (little-endian): `CONNECT 0x01`,
`DATA 0x02`, `CONTINUE 0x03` (client ignores), `CLOSE 0x04`. Single-threaded
asyncio; a per-frame error is logged and skipped rather than tearing down the
whole WebSocket (which would drop every stream and force the guest to reconnect).

## Caveats

- Leech/egress only — no inbound, no UDP (so DNS still goes via the guest's DoH
  path, not this relay; connect by IP for LAN hosts, or ensure the relay host
  can resolve the name).
- No auth. Run it on a trusted LAN only.
