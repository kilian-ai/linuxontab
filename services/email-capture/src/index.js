/**
 * LinuxOnTab — Email Capture Worker
 *
 * Routes:
 *   POST /subscribe   { email: string }  → store lead in KV, return JSON
 *   GET  /count       → return { count: number } (admin, requires ?secret=)
 *   GET  /export      → return newline-delimited email list (admin, requires ?secret=)
 *
 * KV layout:
 *   lead:<email>  →  JSON { email, ts, source }
 *   meta:count    →  integer string
 *
 * Environment bindings (set in wrangler.toml / dashboard):
 *   LEADS          KV namespace
 *   ADMIN_SECRET   plain string secret for /count and /export (set as Worker secret)
 */

const ALLOWED_ORIGINS = [
  'https://linuxontab.com',
  'https://www.linuxontab.com',
  // Allow local dev
  'http://localhost',
  'http://127.0.0.1',
];

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function corsHeaders(origin) {
  const allowed = ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '86400',
  };
}

function json(data, status, origin) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders(origin),
    },
  });
}

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const url = new URL(request.url);

    // CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders(origin) });
    }

    // POST /subscribe
    if (request.method === 'POST' && url.pathname === '/subscribe') {
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: 'Invalid JSON' }, 400, origin);
      }

      const email = (body.email || '').trim().toLowerCase();
      if (!EMAIL_RE.test(email)) {
        return json({ error: 'Invalid email address' }, 400, origin);
      }
      if (email.length > 254) {
        return json({ error: 'Email too long' }, 400, origin);
      }

      const key = `lead:${email}`;
      const existing = await env.LEADS.get(key);
      if (existing) {
        // Already subscribed — return success silently (don't leak existence)
        return json({ ok: true, message: 'You\'re on the list!' }, 200, origin);
      }

      const source = (body.source || 'homepage').slice(0, 64);
      const ip = request.headers.get('CF-Connecting-IP') || '';
      const record = JSON.stringify({ email, ts: Date.now(), source, ip });

      await env.LEADS.put(key, record);

      // Increment counter atomically-ish (best-effort, Workers KV is eventually consistent)
      const countStr = await env.LEADS.get('meta:count');
      const count = countStr ? parseInt(countStr, 10) : 0;
      await env.LEADS.put('meta:count', String(count + 1));

      return json({ ok: true, message: 'You\'re on the list!' }, 201, origin);
    }

    // GET /count  (admin)
    if (request.method === 'GET' && url.pathname === '/count') {
      if (!env.ADMIN_SECRET || url.searchParams.get('secret') !== env.ADMIN_SECRET) {
        return json({ error: 'Forbidden' }, 403, origin);
      }
      const countStr = await env.LEADS.get('meta:count');
      return json({ count: countStr ? parseInt(countStr, 10) : 0 }, 200, origin);
    }

    // GET /export  (admin) — newline-delimited email list
    if (request.method === 'GET' && url.pathname === '/export') {
      if (!env.ADMIN_SECRET || url.searchParams.get('secret') !== env.ADMIN_SECRET) {
        return json({ error: 'Forbidden' }, 403, origin);
      }

      const lines = [];
      let cursor;
      do {
        const res = await env.LEADS.list({ prefix: 'lead:', cursor, limit: 1000 });
        for (const key of res.keys) {
          const val = await env.LEADS.get(key.name);
          if (val) {
            try {
              const { email, ts, source, ip } = JSON.parse(val);
              lines.push(`${email}\t${new Date(ts).toISOString()}\t${source}\t${ip || ''}`);
            } catch {
              // skip malformed
            }
          }
        }
        cursor = res.cursor;
        if (res.list_complete) break;
      } while (cursor);

      return new Response(lines.join('\n'), {
        headers: {
          'Content-Type': 'text/plain; charset=utf-8',
          'Content-Disposition': 'attachment; filename="leads.tsv"',
          ...corsHeaders(origin),
        },
      });
    }

    return json({ error: 'Not found' }, 404, origin);
  },
};
