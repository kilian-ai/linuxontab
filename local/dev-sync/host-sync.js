#!/usr/bin/env node
// Host-side watcher that pushes file edits into the guest via the relay HTTP proxy.
// Usage: node host-sync.js --code CODE --port 3000 --watch ./my-site --token SECRET

const fs = require('fs');
const path = require('path');

// try to use global fetch (Node 18+), otherwise fallback to node-fetch
let fetcher = global.fetch;
if (!fetcher) {
  try { fetcher = require('node-fetch'); } catch (e) { /* will error later if not provided */ }
}

function parseArgs() {
  const out = {};
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--code') out.code = argv[++i];
    else if (a === '--port') out.port = argv[++i];
    else if (a === '--watch') out.watch = argv[++i];
    else if (a === '--url') out.url = argv[++i];
    else if (a === '--token') out.token = argv[++i];
  }
  return out;
}

const args = parseArgs();
const CODE = args.code || process.env.DEV_SYNC_CODE;
const PORT = args.port || process.env.DEV_SYNC_PORT;
const WATCH_DIR = args.watch || process.env.DEV_SYNC_WATCH || process.cwd();
const TOKEN = args.token || process.env.DEV_SYNC_TOKEN;
const BASE_URL = args.url || process.env.DEV_SYNC_BASE_URL || 'https://linuxontab-tunnel.fly.dev/port/http';

if (!CODE || !PORT) {
  console.error('Missing --code and --port (or DEV_SYNC_CODE and DEV_SYNC_PORT)');
  process.exit(2);
}

if (!fetcher) {
  console.error('No fetch available. Install node-fetch or use Node 18+.');
  process.exit(2);
}

const targetBase = `${BASE_URL}/${CODE}/${PORT}`;

const chokidar = require('chokidar');

async function postSync(payload) {
  const url = `${targetBase}/_sync`;
  const headers = { 'content-type': 'application/json' };
  if (TOKEN) headers['x-dev-token'] = TOKEN;
  try {
    const res = await fetcher(url, { method: 'POST', body: JSON.stringify(payload), headers });
    if (!res.ok) {
      console.error('sync failed', res.status, await res.text());
    }
  } catch (e) { console.error('sync error', e && e.stack || e); }
}

function syncWrite(relPath, buf) {
  const payload = { op: 'write', path: relPath, content_b64: buf.toString('base64') };
  return postSync(payload);
}

function syncDelete(relPath) {
  const payload = { op: 'delete', path: relPath };
  return postSync(payload);
}

function rel(p) { return path.relative(WATCH_DIR, p).replace(/\\\\/g, '/'); }

console.log(`Watching ${WATCH_DIR} -> ${targetBase} (token:${TOKEN? 'yes':'no'})`);

const watcher = chokidar.watch(WATCH_DIR, { ignoreInitial: true, depth: 10, awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 100 } });

watcher.on('add', p => {
  const r = rel(p);
  fs.readFile(p, (err, data) => { if (err) return console.error(err); console.log('add', r); syncWrite(r, data); });
});
watcher.on('change', p => {
  const r = rel(p);
  fs.readFile(p, (err, data) => { if (err) return console.error(err); console.log('change', r); syncWrite(r, data); });
});
watcher.on('unlink', p => { const r = rel(p); console.log('unlink', r); syncDelete(r); });
watcher.on('error', e => console.error('watcher error', e));
