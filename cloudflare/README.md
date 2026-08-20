# Deploying LinuxOnTab 2.0 to Cloudflare Pages

The wasm-native 2.0 build (`shell/wasm.html` + `shell/linux-dist/`) can't ship on
GitHub Pages: the root filesystem `rootfs.ext4` is **512 MiB**, over GitHub's
100 MB/file hard limit. This directory deploys it to **Cloudflare Pages + R2**.

> **Status: LIVE** at **https://next.linuxontab.com** (production branch `main`).
> `linuxontab2.pages.dev` still works and is what `wrangler pages deploy` prints;
> the custom domain is the public name.

## How it fits together

```
next.linuxontab.com                     (Cloudflare Pages project "linuxontab2")
├── index.html            ← shell/wasm.html            static, from ./public
├── xterm.js, dist/*.js, linux-dist/vmlinux.wasm …      static, from ./public
├── _headers              ← COOP/COEP (cross-origin isolation, for SharedArrayBuffer)
└── /linux-dist/rootfs.ext4   → Pages Function → R2 bucket "linuxontab-rootfs"
        the 512 MiB image, stored as parts + a manifest, streamed same-origin
```

- **Pages** hosts everything small (< 25 MiB/file). `_headers` turns on
  cross-origin isolation, which the wasm kernel needs for `SharedArrayBuffer`.
- **R2** holds the big image. Because `wrangler r2 object put` caps a single
  upload at 300 MiB, `rootfs.ext4` is stored as **25 MiB parts**
  (`rootfs.ext4.part-aa …`) plus **`rootfs.ext4.manifest`** (their order + total
  size). The Function in `functions/linux-dist/rootfs.ext4.js` reads the
  manifest and streams the parts back concatenated, on the *same origin* as the
  page — so `COEP: require-corp` is satisfied with no CORS/CORP setup.
- **`shell/wasm.html` needs no edits** — it fetches `./linux-dist/rootfs.ext4`
  and does one full GET; the Function answers with the reassembled 512 MiB file.
  (Verified: the streamed bytes are sha256-identical to the local image.)

No S3 API token is needed anywhere — everything uses the same `wrangler login`
you already do for `pages deploy`.

## Files here

| File | Purpose |
|------|---------|
| `wrangler.jsonc` | Pages project name, output dir, R2 binding `ROOTFS` |
| `functions/linux-dist/rootfs.ext4.js` | Streams rootfs.ext4 from R2 parts (manifest-driven; single-object + Range fast path kept) |
| `_headers` | COOP/COEP + cache rules (copied into `public/` at build) |
| `build-publish.sh` | Assembles `./public` from `../shell` (excludes rootfs.ext4) |
| `upload-rootfs.sh` | Splits rootfs.ext4 → uploads parts + manifest to R2 via wrangler |
| `public/` | Build artifact (gitignored) |

## Prerequisites

- A Cloudflare account with the **linuxontab.com** zone on Cloudflare.
- `npx wrangler` (v3.60+). No global install needed.
- Run uploads from a normal shell with real network egress (a sandboxed/proxied
  shell may drop large uploads — the script retries, but bare metal is best).

## First-time deploy (already done once; here for reproducibility)

All commands run from this `cloudflare/` directory.

```bash
npx wrangler login                                   # your Cloudflare login
npx wrangler r2 bucket create linuxontab-rootfs      # already created
./upload-rootfs.sh                                   # split + upload parts + manifest
./build-publish.sh                                   # assemble ./public
npx wrangler pages project create linuxontab2 --production-branch=main
npx wrangler pages deploy --branch=main              # deploy to production
```

### If the Function returns 500 "R2 binding ROOTFS is not configured"

`wrangler.jsonc` declares the binding and recent Wrangler applies it on deploy.
If not, set it once in the dashboard and redeploy:

> Pages → **linuxontab2** → Settings → Functions → **R2 bindings** →
> `ROOTFS` → bucket `linuxontab-rootfs`.

### next.linuxontab.com  ← done (2026-08-20)

The custom domain is attached to the Pages project AND the DNS record exists:

```
CNAME  next  →  linuxontab2.pages.dev   (proxied)
```

Two gotchas, both hit while setting this up:

* Pages is documented to create that CNAME for you when the zone is in the
  same account. It did not — the domain sat `active` on the project with no
  DNS record at all, so the hostname simply did not resolve. If a custom
  domain looks configured but does not answer, check DNS before touching
  anything else.
* `wrangler`'s stored OAuth token has `zone:read`, which does NOT include
  reading DNS records: the API cheerfully returns *zero records for the whole
  zone* instead of a permission error. Do not read that as "no record" — use
  `dig` against `1.1.1.1`, which is authoritative for this purpose.

## Verify

```bash
# cross-origin isolation on the document:
curl -sI https://next.linuxontab.com/ | grep -i cross-origin
#   → require-corp + same-origin  (else SharedArrayBuffer is blocked)

# the reassembled image:
curl -sI 'https://next.linuxontab.com/linux-dist/rootfs.ext4?cb=1' | grep -iE 'etag|content-length|x-rootfs-parts'
#   → content-length: 536870912 · x-rootfs-parts: 21
```

Then open the site; in the console `crossOriginIsolated` must be `true`, and the
boot log should stream the rootfs and drop you at a shell.

## Updating

- **Shell / small assets changed** → `./build-publish.sh` then
  `npx wrangler pages deploy --branch=main`.
- **rootfs.ext4 rebuilt** → `./upload-rootfs.sh` (re-splits, re-uploads parts,
  rewrites the manifest — safe even if the new image has fewer parts, since the
  manifest is authoritative), then bump the `?v=` cache-bust on the rootfs fetch
  in `shell/wasm.html`, then `./build-publish.sh && npx wrangler pages deploy --branch=main`.

## Cost note

R2 has **no egress fees**. The image is ~pennies/month of storage; each cold
boot does ~21 Class B reads (one per part) — the browser overlay caches the
image after first load, so repeat visits don't refetch. Pages static requests
are free; only the rootfs Function is metered (100k free invocations/day).
