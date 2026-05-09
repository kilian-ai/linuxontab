#!/usr/bin/env node
// Simple dev server for guest
// Usage: PORT=3000 HOST_DIR=/usr/local/dev node server-express.js

const path = require('path');
const fs = require('fs');
const http = require('http');
const express = require('express');
const cors = require('cors');
const WebSocket = require('ws');
const chokidar = require('chokidar');

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST_DIR = process.env.HOST_DIR || process.cwd();

if (!fs.existsSync(HOST_DIR)) {
  console.error('Host dir does not exist:', HOST_DIR);
  process.exit(2);
}

const app = express();
app.use(cors());
// accept reasonably-sized JSON payloads for file sync
app.use(express.json({ limit: '20mb' }));
app.use(express.static(HOST_DIR, { extensions: ['html', 'js', 'mjs'] }));

// Basic index fallback
app.get('/', (req, res) => {
  const f = path.join(HOST_DIR, 'index.html');
  if (fs.existsSync(f)) return res.sendFile(f);
  res.type('text/plain').send('dev server root');
});

const server = http.createServer(app);
const wss = new WebSocket.Server({ server, path: '/ws' });

wss.on('connection', (ws) => {
  console.log('ws client connected');
  ws.send(JSON.stringify({ event: 'hello' }));
});

const watcher = chokidar.watch(HOST_DIR, { ignoreInitial: true, depth: 6 });
watcher.on('all', (event, filePath) => {
  const rel = path.relative(HOST_DIR, filePath);
  const msg = JSON.stringify({ event, path: rel });
  wss.clients.forEach(c => { if (c.readyState === WebSocket.OPEN) c.send(msg); });
  console.log('change', event, rel);
});

server.listen(PORT, () => {
  console.log(`dev server serving ${HOST_DIR} on port ${PORT}`);
  console.log(`ws endpoint: /ws`);
});

// Sync endpoint used by host-side watcher to push edited files into the guest
// POST /_sync { op: 'write'|'delete', path: 'relative/path', content_b64: '...' }
app.post('/_sync', async (req, res) => {
  try {
    // optional token guard: set DEV_SYNC_TOKEN in guest environment
    const expected = process.env.DEV_SYNC_TOKEN;
    if (expected) {
      const got = req.headers['x-dev-token'];
      if (!got || got !== expected) return res.status(403).json({ error: 'forbidden' });
    }

    const body = req.body || {};
    const op = body.op || 'write';
    const relPath = body.path;
    if (!relPath) return res.status(400).json({ error: 'missing path' });

    const abs = path.join(HOST_DIR, relPath);
    if (op === 'delete') {
      try { fs.unlinkSync(abs); } catch (e) { /* ignore */ }
      console.log('sync: delete', relPath);
      return res.json({ ok: true });
    }

    const content_b64 = body.content_b64 || '';
    const buf = Buffer.from(content_b64, 'base64');
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, buf);
    console.log('sync: write', relPath, `${buf.length} bytes`);
    return res.json({ ok: true });
  } catch (err) {
    console.error('sync error', err && err.stack || err);
    return res.status(500).json({ error: 'sync_failed' });
  }
});
