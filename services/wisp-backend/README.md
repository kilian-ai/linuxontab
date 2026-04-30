# wisp-backend (linuxontab-net.fly.dev)

WebSocket WISP v1 server providing real TCP egress for the v86 Alpine guest's NIC.

The v86 page (`https://linuxontab.com/shell/`) connects its `WispNetworkAdapter` to:

```
wisps://linuxontab-net.fly.dev/wisp
```

This Fly app is the upstream that handles DHCP, ARP, TCP connect, and DNS-over-TCP/53 for everything inside the guest. The Cloudflare Worker `relay.linuxontab.com` only handles `/dns-query` (DoH) and the helper-tunnel endpoints; real network egress goes here.

## What it runs

It runs the **same `traits` binary** as the upstream traits.build server (`apptron-traits-build` Fly app). The binary's `sys.serve` HTTP server handles `/wisp` WebSocket upgrade via [`traits/sys/serve/wisp.rs`](https://github.com/kilian-ai/traits.build/blob/main/traits/sys/serve/wisp.rs) — a tokio TCP-bridge implementation of [WISP v1](https://github.com/MercuryWorkshop/wisp-protocol).

## Deploy

```sh
# One-time
fly apps create linuxontab-net

# Deploy using the prebuilt image from the upstream traits.build app
IMAGE=$(fly image show -a apptron-traits-build --json | jq -r '.[0].FullImageRef')
fly deploy -c fly.toml --image "$IMAGE" --ha=false
```

To rebuild from source instead, deploy from the `traits.build` repo using its `Dockerfile`:

```sh
cd ~/.ai/traits/Polygrait/A.\ traits.build
fly deploy -c ~/.ai/LinuxOnTab/services/wisp-backend/fly.toml --ha=false
```

## Verify

```sh
curl -si https://linuxontab-net.fly.dev/health        # HTTP 200
curl -si 'https://linuxontab-net.fly.dev/wisp/debug'  # JSON status
```

For end-to-end, open https://linuxontab.com/shell/ → wait for prompt → run `wget https://example.com -O -`.

## Why a separate app from the relay Worker

Cloudflare Workers' `connect()` API has built-in loopback prevention and cannot reach CF-fronted targets (most of Alpine apk repos, etc.). Fly machines have unrestricted outbound TCP, so we keep WISP on Fly and only DoH on the CF Worker. See [traits/sys/serve/wisp.rs](https://github.com/kilian-ai/traits.build/blob/main/traits/sys/serve/wisp.rs) header comment.
