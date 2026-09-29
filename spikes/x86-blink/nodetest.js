// nodetest.js — what real Node programs lean on, run under Blink in the guest
const fs = require('fs'), os = require('os'), cp = require('child_process');
const net = require('net'), crypto = require('crypto'), zlib = require('zlib');
const t0 = Date.now();
const results = [];
const ok = (name, cond, extra = '') => { results.push(cond); console.log(`${cond ? 'PASS' : 'FAIL'} ${name} ${extra}`); };

ok('versions', !!process.versions.v8, `node ${process.version} v8 ${process.versions.v8} uv ${process.versions.uv}`);
ok('os', os.platform() === 'linux', `${os.arch()} ${os.release()} cpus=${os.cpus().length}`);
fs.writeFileSync('/tmp/node-wrote.txt', 'hello from node\n');
ok('fs write/read', fs.readFileSync('/tmp/node-wrote.txt', 'utf8') === 'hello from node\n');
ok('fs readdir guest', fs.readdirSync('/bin').includes('busybox'), `(/bin has ${fs.readdirSync('/bin').length} entries)`);
ok('crypto sha256', crypto.createHash('sha256').update('abc').digest('hex').startsWith('ba7816bf'));
ok('zlib roundtrip', zlib.gunzipSync(zlib.gzipSync('x'.repeat(1000))).length === 1000);
ok('json/regex/intl', JSON.parse('{"a":[1,2]}').a[1] === 2 && /b+/.test('abbc') && (1234.5).toLocaleString('en-US') === '1,234.5');
ok('spawn wasm program', cp.execSync('echo from-wasm-sh; uname -m').toString().trim().split('\n').join(','), cp.execSync('uname -m').toString().trim());

(async () => {
  await new Promise(r => setTimeout(r, 50));
  ok('timers + promises', true);
  const srv = net.createServer(s => s.end('pong:' + s.remoteAddress)).listen(0, '127.0.0.1');
  await new Promise(r => srv.on('listening', r));
  const reply = await new Promise((res, rej) => {
    const c = net.connect(srv.address().port, '127.0.0.1');
    let d = ''; c.on('data', x => d += x); c.on('end', () => res(d)); c.on('error', rej);
  });
  srv.close();
  ok('tcp server+client', reply.startsWith('pong:'), reply);
  const kids = await new Promise(res => cp.exec('ls /opt/x86 | wc -l', (e, out) => res(e ? String(e) : out.trim())));
  ok('async child_process', /^\d+$/.test(kids), `(${kids} entries)`);
  console.log(`${results.filter(Boolean).length}/${results.length} passed in ${Date.now() - t0} ms`);
})();
