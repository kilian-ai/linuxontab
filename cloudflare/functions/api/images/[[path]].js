// Committed-image registry: push/pull LinuxOnTab container images (lean-base
// dirty-block overlays) to/from R2, on the page's own origin.
//
//   GET  /api/images                 → JSON list [{name, size, baseSha, created}]
//   GET  /api/images/<name>.json     → image metadata {name, baseSha, extents, created}
//   GET  /api/images/<name>.data     → overlay blob (sparse extents, concatenated)
//   PUT  /api/images/<name>.json     → store metadata   (requires x-lot-token)
//   PUT  /api/images/<name>.data     → store blob       (requires x-lot-token)
//   DELETE /api/images/<name>        → remove both      (requires x-lot-token)
//
// Pushes need the LOT_PUSH_TOKEN env var (Pages project setting / wrangler
// secret) and a matching x-lot-token header — without a configured token the
// registry is read-only. Objects live in the ROOTFS bucket under images/.

const PREFIX = "images/";
const NAME_RE = /^[A-Za-z0-9_-]{1,32}$/;

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "content-type": "application/json",
      "cross-origin-resource-policy": "same-origin",
      "cache-control": "no-store",
    },
  });
}

function authorized(request, env) {
  const token = env.LOT_PUSH_TOKEN;
  if (!token) return false;                       // no token configured → read-only
  return request.headers.get("x-lot-token") === token;
}

export async function onRequest({ request, env, params }) {
  const path = (params.path || []).join("/");     // "", "<name>.json", "<name>.data", "<name>"
  const method = request.method;

  // ── List ──────────────────────────────────────────────────────────────────
  if (!path && method === "GET") {
    const out = [];
    let cursor;
    do {
      const page = await env.ROOTFS.list({ prefix: PREFIX, cursor, include: ["customMetadata"] });
      for (const o of page.objects) {
        if (!o.key.endsWith(".json")) continue;
        const meta = o.customMetadata || {};
        out.push({
          name: o.key.slice(PREFIX.length, -".json".length),
          size: +(meta.dataSize || 0),
          baseSha: meta.baseSha || null,
          created: +(meta.created || 0),
        });
      }
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
    return json(out);
  }

  const m = /^([A-Za-z0-9_-]{1,32})(\.json|\.data)?$/.exec(path);
  if (!m) return json({ error: "bad image name" }, 400);
  const name = m[1];
  const kind = m[2] || "";

  // ── Fetch ─────────────────────────────────────────────────────────────────
  if (method === "GET" && (kind === ".json" || kind === ".data")) {
    const obj = await env.ROOTFS.get(PREFIX + name + kind);
    if (!obj) return json({ error: "not found" }, 404);
    const h = new Headers();
    h.set("content-type", kind === ".json" ? "application/json" : "application/octet-stream");
    h.set("cross-origin-resource-policy", "same-origin");
    h.set("cache-control", "no-store");   // images are mutable by name
    h.set("content-length", String(obj.size));
    return new Response(obj.body, { headers: h });
  }

  // ── Push / delete (token-gated) ───────────────────────────────────────────
  if (method === "PUT" || method === "DELETE") {
    if (!env.LOT_PUSH_TOKEN) return json({ error: "registry is read-only (LOT_PUSH_TOKEN not configured)" }, 403);
    if (!authorized(request, env)) return json({ error: "bad or missing x-lot-token" }, 401);
  }

  if (method === "PUT" && (kind === ".json" || kind === ".data")) {
    if (!NAME_RE.test(name)) return json({ error: "bad image name" }, 400);
    const customMetadata = {};
    if (kind === ".json") {
      // Validate + index the metadata so listing needs no extra reads.
      let meta;
      try { meta = await request.clone().json(); } catch (_) { return json({ error: "metadata must be JSON" }, 400); }
      if (!meta || !meta.baseSha || !Array.isArray(meta.extents)) {
        return json({ error: "metadata needs {baseSha, extents}" }, 400);
      }
      customMetadata.baseSha = String(meta.baseSha).slice(0, 64);
      customMetadata.created = String(meta.created || Date.now());
      customMetadata.dataSize = String(meta.dataSize || 0);
    }
    await env.ROOTFS.put(PREFIX + name + kind, request.body, { customMetadata });
    return json({ ok: 1, key: name + kind });
  }

  if (method === "DELETE" && !kind) {
    await env.ROOTFS.delete(PREFIX + name + ".json");
    await env.ROOTFS.delete(PREFIX + name + ".data");
    return json({ ok: 1, deleted: name });
  }

  return json({ error: "unsupported" }, 405);
}
