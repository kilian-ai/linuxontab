// Serve a disk image stored in R2 as ordered parts + a manifest (written by
// upload-rootfs.sh with IMAGE=<name>), same-origin so COEP: require-corp holds.
//
// Manifest: {slot, parts, size, sha256[, encoding: "gzip", csize]}
//   - plain: the parts concatenate to the image (size bytes)
//   - gzip:  the parts concatenate to a gzip stream (csize bytes) of the
//            image; served as-is with x-lot-encoding: gzip + x-lot-size, and
//            the page inflates it (DecompressionStream). No Content-Encoding:
//            the page needs the compressed length for progress and the raw
//            stream to verify, and the edge must not re-encode it.
// The sha256 (of the uncompressed image) is the ETag: wasm.html's
// bootImageVersion() keys its Cache Storage copy on it.

async function readManifest(env, key) {
  const obj = await env.ROOTFS.get(key);
  if (!obj) return null;
  try {
    const m = JSON.parse(await obj.text());
    return Array.isArray(m.parts) && m.parts.length && typeof m.size === "number" ? m : null;
  } catch (_) {
    return null;
  }
}

function headersFor(m) {
  const h = new Headers();
  h.set("content-type", "application/octet-stream");
  h.set("cache-control", "public, max-age=31536000, immutable");
  h.set("cross-origin-resource-policy", "same-origin");
  h.set("accept-ranges", "none");
  h.set("etag", '"' + (m.sha256 || "size-" + m.size) + '"');
  if (m.encoding === "gzip") {
    h.set("content-length", String(m.csize));
    h.set("x-lot-encoding", "gzip");
    h.set("x-lot-size", String(m.size));
  } else {
    h.set("content-length", String(m.size));
  }
  return h;
}

// Stream the parts back-to-back with backpressure.
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
          await writer.write(value);
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

export function r2Image(name) {
  const manifestKey = name + ".manifest";
  return {
    onRequestGet: async (ctx) => {
      const { env } = ctx;
      if (!env.ROOTFS) return new Response("R2 binding ROOTFS is not configured.\n", { status: 500 });
      const m = await readManifest(env, manifestKey);
      if (!m) return new Response(name + " is not uploaded.\n", { status: 404 });
      return new Response(concatStream(env, m.parts, ctx), {
        status: 200, headers: headersFor(m), encodeBody: "manual",
      });
    },
    onRequestHead: async ({ env }) => {
      if (!env.ROOTFS) return new Response(null, { status: 500 });
      const m = await readManifest(env, manifestKey);
      if (!m) return new Response(null, { status: 404 });
      return new Response(null, { status: 200, headers: headersFor(m) });
    },
  };
}
