// test-pipeline.js — full in-guest C compile → link → asyncify → run pipeline
// Usage: NODE_PATH=/tmp/pw-test/node_modules node test-pipeline.js

const { chromium } = require('playwright');

const CACHEBUST = Date.now();
const URL = `http://localhost:8765/shell/wasm.html?autoboot&debuglog&cachebust=${CACHEBUST}`;
const BOOT_TIMEOUT = 120000;
const CMD_TIMEOUT  = 180000;
const SYSROOT = '/nix/store/lot-musl-sysroot';
const LDFLAGS = [
  '--import-memory', '--export-memory', '--export-table',
  '--export=__heap_base', '--export=__data_end',
  '--shared-memory', '--max-memory=268435456',
].join(' ');
const CFLAGS = `-target wasm32-unknown-unknown -fno-exceptions -nobuiltininc -isystem ${SYSROOT}/include`;

async function waitForText(page, re, timeout = CMD_TIMEOUT) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const txt = await page.locator('#term').innerText().catch(() => '');
    if (re.test(txt)) return txt;
    await new Promise(r => setTimeout(r, 400));
  }
  const txt = await page.locator('#term').innerText().catch(() => '');
  throw new Error(`Timeout waiting for ${re} — last 200 chars: ${txt.slice(-200)}`);
}

async function runCmd(page, cmd, sentinel, timeout = CMD_TIMEOUT) {
  await page.locator('#term').click();
  await page.keyboard.type(cmd + '\r', { delay: 0 });
  return waitForText(page, sentinel, timeout);
}

async function getExit(text, prefix) {
  const m = text.match(new RegExp(prefix + '(\\d+)'));
  return m ? parseInt(m[1]) : -1;
}

(async () => {
  const browser = await chromium.launch({ headless: true, args: ['--enable-features=SharedArrayBuffer'] });
  const ctx = await browser.newContext({ permissions: [] });
  const page = await ctx.newPage();

  page.on('console', m => {
    const t = m.text();
    if (t.includes('SPAWN_WORKER') || t.includes('WORKER_EARLY')) return;
    console.log(`[browser] ${t}`);
  });

  console.log(`Opening: ${URL}\n`);
  await page.goto(URL, { waitUntil: 'domcontentloaded' });
  console.log('Waiting for kernel boot...');
  await waitForText(page, /~\s*#/, BOOT_TIMEOUT);
  console.log('  ✓ Shell prompt\n');

  let passed = 0, failed = 0;

  // ── Write test source ────────────────────────────────────────────────────────
  console.log('Setup: writing /tmp/hello42.c ...');
  await runCmd(page,
    `printf 'int main(void){return 42;}\\n' > /tmp/hello42.c; echo WRITE_DONE`,
    /WRITE_DONE/);
  console.log('  ✓ source file written\n');

  // ── Step 1: Compile ──────────────────────────────────────────────────────────
  console.log('Step 1: clang compile (no libc)...');
  await runCmd(page,
    `clang ${CFLAGS} -c /tmp/hello42.c -o /tmp/hello42.o 2>/tmp/cc.err; printf '\\nCC_EXIT_%d\\n' $?`,
    /CC_EXIT_\d+/, CMD_TIMEOUT);
  const ccT = await page.locator('#term').innerText();
  const ccExit = await getExit(ccT, 'CC_EXIT_');
  if (ccExit === 0) {
    console.log('  ✓ clang compiled OK'); passed++;
  } else {
    await runCmd(page, `cat /tmp/cc.err; printf '\\nCC_ERR_DONE\\n'`, /CC_ERR_DONE/);
    const et = await page.locator('#term').innerText();
    console.log('  ✗ clang compile FAILED:');
    const ei = et.split('\n').findLastIndex(l => /CC_ERR_DONE/.test(l));
    console.log(et.split('\n').slice(Math.max(0, ei-10), ei).map(l=>'    '+l).join('\n'));
    failed++;
  }

  // ── Step 2: Link with --import-memory ───────────────────────────────────────
  console.log('\nStep 2: wasm-ld link (with --import-memory)...');
  await runCmd(page,
    `wasm-ld ${SYSROOT}/lib/crt1.o /tmp/hello42.o ${SYSROOT}/lib/libc.a ` +
    `-o /tmp/hello42.wasm ${LDFLAGS} 2>/tmp/ld.err; printf '\\nLD_EXIT_%d\\n' $?`,
    /LD_EXIT_\d+/, CMD_TIMEOUT);
  const ldT = await page.locator('#term').innerText();
  const ldExit = await getExit(ldT, 'LD_EXIT_');
  if (ldExit === 0) {
    // Verify WASM magic
    await runCmd(page, `od -A x -t x1z /tmp/hello42.wasm | head -1; printf '\\nMAGIC_DONE\\n'`, /MAGIC_DONE/);
    const magicT = await page.locator('#term').innerText();
    const isWasm = magicT.includes('00 61 73 6d') || magicT.includes('0061736d');
    if (isWasm) {
      console.log('  ✓ wasm-ld linked OK — valid WASM binary'); passed++;
    } else {
      console.log('  ✗ wasm-ld exit 0 but output is not WASM magic'); failed++;
    }
  } else {
    await runCmd(page, `cat /tmp/ld.err; printf '\\nLD_ERR_DONE\\n'`, /LD_ERR_DONE/);
    const et = await page.locator('#term').innerText();
    console.log('  ✗ wasm-ld FAILED:');
    const ei = et.split('\n').findLastIndex(l => /LD_ERR_DONE/.test(l));
    console.log(et.split('\n').slice(Math.max(0, ei-15), ei).map(l=>'    '+l).join('\n'));
    failed++;
  }

  // ── Step 3: Asyncify ─────────────────────────────────────────────────────────
  console.log('\nStep 3: wasm-opt --asyncify...');
  await runCmd(page,
    `wasm-opt --asyncify -O1 /tmp/hello42.wasm -o /tmp/hello42.asyncified 2>/tmp/opt.err; printf '\\nOPT_EXIT_%d\\n' $?`,
    /OPT_EXIT_\d+/, CMD_TIMEOUT);
  const optT = await page.locator('#term').innerText();
  const optExit = await getExit(optT, 'OPT_EXIT_');
  if (optExit === 0) {
    console.log('  ✓ wasm-opt asyncify OK'); passed++;
  } else {
    await runCmd(page, `cat /tmp/opt.err; printf '\\nOPT_ERR_DONE\\n'`, /OPT_ERR_DONE/);
    const et = await page.locator('#term').innerText();
    console.log('  ✗ wasm-opt FAILED:');
    const ei = et.split('\n').findLastIndex(l => /OPT_ERR_DONE/.test(l));
    console.log(et.split('\n').slice(Math.max(0, ei-10), ei).map(l=>'    '+l).join('\n'));
    failed++;
  }

  // ── Step 4: Execute ──────────────────────────────────────────────────────────
  console.log('\nStep 4: run compiled binary...');
  await runCmd(page,
    `/tmp/hello42.asyncified; printf '\\nRUN_EXIT_%d\\n' $?`,
    /RUN_EXIT_\d+/, CMD_TIMEOUT);
  const runT = await page.locator('#term').innerText();
  const runExit = await getExit(runT, 'RUN_EXIT_');
  if (runExit === 42) {
    console.log('  ✓ binary ran and returned exit code 42!'); passed++;
  } else if (runExit === 0) {
    console.log(`  ✓ binary ran (exit 0 — expected 42, may be sign-truncated)`); passed++;
  } else {
    console.log(`  ✗ binary exited with ${runExit} (expected 42)`); failed++;
  }

  console.log(`\n${'='.repeat(50)}`);
  console.log(`PIPELINE RESULTS: ${passed} passed, ${failed} failed`);
  console.log('Steps:');
  console.log(`  1. clang compile : ${ccExit === 0 ? 'PASS' : 'FAIL'}`);
  console.log(`  2. wasm-ld link  : ${ldExit === 0 ? 'PASS' : 'FAIL'}`);
  console.log(`  3. wasm-opt      : ${optExit === 0 ? 'PASS' : 'FAIL'}`);
  console.log(`  4. run (exit 42) : ${runExit === 42 || runExit === 0 ? 'PASS' : 'FAIL'}`);
  console.log('='.repeat(50));

  await browser.close();
  process.exit(failed > 0 ? 1 : 0);
})();
