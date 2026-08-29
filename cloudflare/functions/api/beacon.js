// Debug telemetry for devices we can't attach a console to (iOS Safari).
// POST /api/beacon  {sid, name, stage, t, ...}  → stored as beacon/<key>.json
// GET  /api/beacon?sid=<sid>                    → recent events for that sid
// Bodies are capped small; entries are short-lived debug data, not user data.
export async function onRequest({ request, env }) {
  const url = new URL(request.url);
  if (request.method === "POST") {
    const text = (await request.text()).slice(0, 2048);
    let sid = "unknown";
    try { sid = String(JSON.parse(text).sid || "unknown").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 16) || "unknown"; } catch (_) {}
    const key = `beacon/${sid}/${Date.now()}-${Math.random().toString(36).slice(2, 6)}.json`;
    await env.ROOTFS.put(key, text);
    return new Response('{"ok":1}', { headers: { "content-type": "application/json" } });
  }
  if (request.method === "GET") {
    const sid = (url.searchParams.get("sid") || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 16);
    const prefix = sid ? `beacon/${sid}/` : "beacon/";
    const page = await env.ROOTFS.list({ prefix, limit: 200 });
    const keys = page.objects.map(o => o.key).sort().slice(-60);
    const out = [];
    for (const k of keys) {
      const o = await env.ROOTFS.get(k);
      if (o) out.push(await o.text());
    }
    return new Response("[" + out.join(",") + "]", {
      headers: { "content-type": "application/json", "cache-control": "no-store" },
    });
  }
  return new Response("nope", { status: 405 });
}
