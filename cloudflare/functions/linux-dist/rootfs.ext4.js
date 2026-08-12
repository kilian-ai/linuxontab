// Serves /linux-dist/rootfs.ext4 (the 512 MiB guest root filesystem) from R2,
// on the SAME origin as the page — so it satisfies COEP: require-corp with no
// CORS/CORP handshake.
//
// The image is 512 MiB, but `wrangler r2 object put` caps a single upload at
// 300 MiB. So it's stored as ordered parts:  rootfs.ext4.part-aa, -ab, -ac …
// This Function lists those parts and streams them back concatenated, so the
// browser sees one continuous 512 MiB file. shell/wasm.html needs no change —
// it still fetches ./linux-dist/rootfs.ext4 and does a single full GET.
//
// A single-object fast path is kept too: if a whole "rootfs.ext4" object ever
// exists (e.g. uploaded via the S3 endpoint / rclone), it's served directly
// with Range support. Otherwise the parts are assembled.

const KEY = "rootfs.ext4";
const PART_PREFIX = "rootfs.ext4.part-";
const MANIFEST_KEY = "rootfs.ext4.manifest";

function baseHeaders() {
  const h = new Headers();
  h.set("content-type", "application/octet-stream");
  h.set("cache-control", "public, max-age=31536000, immutable");
  h.set("cross-origin-resource-policy", "same-origin");
  return h;
}

// Resolve the ordered parts + total size. A manifest, if present, is
// authoritative — so a rebuilt (possibly smaller) image can't be corrupted by
// stale trailing parts left in the bucket. Otherwise fall back to listing.
async function resolveParts(env) {
  const manifest = await env.ROOTFS.get(MANIFEST_KEY);
  if (manifest) {
    try {
      const m = JSON.parse(await manifest.text());
      if (Array.isArray(m.parts) && m.parts.length) {
        const total =
          typeof m.size === "number"
            ? m.size
            : (await listParts(env)).reduce((n, p) => n + p.size, 0);
        return { keys: m.parts, total };
      }
    } catch (_) {
      /* fall through to listing */
    }
  }
  const parts = await listParts(env);
  return { keys: parts.map((p) => p.key), total: parts.reduce((n, p) => n + p.size, 0) };
}

async function listParts(env) {
  // R2 list returns keys lexicographically; -aa,-ab,-ac already sort right,
  // but sort explicitly to be safe. Paginate in case of many parts.
  const parts = [];
  let cursor;
  do {
    const page = await env.ROOTFS.list({ prefix: PART_PREFIX, cursor });
    for (const o of page.objects) parts.push({ key: o.key, size: o.size });
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  parts.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  return parts;
}

// Stream several R2 objects back-to-back with real backpressure.
function concatStream(env, keys, ctx) {
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const pump = (async () => {
    try {
      for (const key of keys) {
        const obj = await env.ROOTFS.get(key);
        if (!obj || !obj.body) throw new Error("missing part " + key);
        const reader = obj.body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          await writer.write(value); // awaits => honors client backpressure
        }
      }
      await writer.close();
    } catch (e) {
      try { await writer.abort(e); } catch (_) {}
    }
  })();
  if (ctx && ctx.waitUntil) ctx.waitUntil(pump);
  return readable;
}

export const onRequestGet = async (ctx) => {
  const { request, env } = ctx;
  if (!env.ROOTFS) {
    return new Response(
      "R2 binding ROOTFS is not configured on this Pages project.\n" +
        "See cloudflare/README.md.",
      { status: 500 }
    );
  }

  // ── Fast path: a single whole object exists ──────────────────────────────
  const whole = await env.ROOTFS.head(KEY);
  if (whole) {
    let wantRange = null;
    const rangeHeader = request.headers.get("range");
    if (rangeHeader) {
      const m = /^bytes=(\d+)-(\d*)$/.exec(rangeHeader.trim());
      if (m) {
        const start = parseInt(m[1], 10);
        wantRange =
          m[2] === ""
            ? { offset: start }
            : { offset: start, length: parseInt(m[2], 10) - start + 1 };
      }
    }
    const obj = await env.ROOTFS.get(KEY, wantRange ? { range: wantRange } : {});
    const headers = baseHeaders();
    obj.writeHttpMetadata(headers);
    headers.set("content-type", "application/octet-stream");
    headers.set("etag", obj.httpEtag);
    headers.set("accept-ranges", "bytes");
    if (wantRange && obj.range) {
      const start = obj.range.offset ?? 0;
      const len = obj.range.length ?? obj.size - start;
      headers.set("content-range", `bytes ${start}-${start + len - 1}/${obj.size}`);
      headers.set("content-length", String(len));
      return new Response(obj.body, { status: 206, headers });
    }
    headers.set("content-length", String(obj.size));
    return new Response(obj.body, { status: 200, headers });
  }

  // ── Assembled path: stream the ordered parts as one body ─────────────────
  const { keys, total } = await resolveParts(env);
  if (keys.length === 0) {
    return new Response(
      "rootfs.ext4 not found in R2 (no whole object and no parts).\n" +
        "Upload it — see cloudflare/README.md.",
      { status: 404 }
    );
  }
  const headers = baseHeaders();
  // The parts are opaque slices of one file; range requests aren't supported
  // on the assembled view (the loader does a single full GET anyway).
  headers.set("accept-ranges", "none");
  headers.set("content-length", String(total));
  headers.set("x-rootfs-parts", String(keys.length));
  return new Response(concatStream(env, keys, ctx), { status: 200, headers });
};

// HEAD — report the assembled size without streaming.
export const onRequestHead = async ({ env }) => {
  if (!env.ROOTFS) return new Response(null, { status: 500 });
  const whole = await env.ROOTFS.head(KEY);
  if (whole) {
    const headers = baseHeaders();
    whole.writeHttpMetadata(headers);
    headers.set("content-type", "application/octet-stream");
    headers.set("content-length", String(whole.size));
    headers.set("accept-ranges", "bytes");
    headers.set("etag", whole.httpEtag);
    return new Response(null, { status: 200, headers });
  }
  const { keys, total } = await resolveParts(env);
  if (keys.length === 0) return new Response(null, { status: 404 });
  const headers = baseHeaders();
  headers.set("content-length", String(total));
  headers.set("accept-ranges", "none");
  headers.set("x-rootfs-parts", String(keys.length));
  return new Response(null, { status: 200, headers });
};
