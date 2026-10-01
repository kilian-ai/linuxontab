// Serves /linux-dist/x86-chromium.ext4 — the read-only extra disk of the x86
// Chromium spike (spikes/x86-chromium/make-image.sh), attached by wasm.html's
// ?xdisk= as /dev/vdc — from R2, same-origin (COEP: require-corp).
//
// Same layout as rootfs.ext4 (see rootfs.ext4.js): ~25 MiB parts in A/B slots
// plus a manifest {slot, parts, size, sha256}, written by
//   IMAGE=x86-chromium.ext4 ./upload-rootfs.sh
// The manifest's sha256 is the ETag, which wasm.html's bootImageVersion() uses
// to key its Cache Storage copy (downloaded once per image version).

const MANIFEST_KEY = "x86-chromium.ext4.manifest";

async function manifest(env) {
  const obj = await env.ROOTFS.get(MANIFEST_KEY);
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
  h.set("content-length", String(m.size));
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

export const onRequestGet = async (ctx) => {
  const { env } = ctx;
  if (!env.ROOTFS) return new Response("R2 binding ROOTFS is not configured.\n", { status: 500 });
  const m = await manifest(env);
  if (!m) return new Response("x86-chromium.ext4 is not uploaded.\n", { status: 404 });
  return new Response(concatStream(env, m.parts, ctx), { status: 200, headers: headersFor(m) });
};

export const onRequestHead = async ({ env }) => {
  if (!env.ROOTFS) return new Response(null, { status: 500 });
  const m = await manifest(env);
  if (!m) return new Response(null, { status: 404 });
  return new Response(null, { status: 200, headers: headersFor(m) });
};
