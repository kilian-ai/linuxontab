#!/usr/bin/env node
// Playwright test: full clang driver pipeline inside WASM kernel
// Tests: clang driver (fork+exec cc1) → object file → wasm-ld → .wasm
const { chromium } = require('playwright');

const URL = 'http://localhost:8765/shell/wasm.html?autoboot&debuglog&cachebust=38';
const BOOT_TIMEOUT = 600000;  // 10 min
const CMD_TIMEOUT  = 600000;  // 10 min per step

// Simple C source (no includes needed)
const T_C = 'int add(int a, int b) { return a + b; }';

async function getTermText(page) {
  return page.evaluate(() => {
    const rows = document.querySelectorAll('#term .xterm-rows > div');
    return Array.from(rows).map(r => r.textContent).join('\n');
  });
}

async function waitForText(page, pattern, timeout = CMD_TIMEOUT) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const text = await getTermText(page);
    if (typeof pattern === 'string' ? text.includes(pattern) : pattern.test(text))
      return text;
    await new Promise(r => setTimeout(r, 800));
  }
  const text = await getTermText(page);
  throw new Error(`Timeout waiting for: ${pattern}\nTerminal:\n${text.slice(-2000)}`);
}

async function runCmd(page, cmd, marker, timeout = CMD_TIMEOUT) {
  await page.evaluate((c) => window.guestSend(c), cmd);
  return waitForText(page, marker, timeout);
}

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox',
           '--js-flags=--max-old-space-size=4096 --no-wasm-tier-up']
  });
  const ctx = await browser.newContext();
  const page = await ctx.newPage();

  page.on('console', msg => {
    const t = msg.text();
    if (t.includes('ERR_INSUFFICIENT') || t.includes('Failed to load resource')) return;
    if (msg.type() === 'error' || t.toLowerCase().includes('error') || t.includes('call()'))
      console.log('[browser]', t.slice(0, 2000));
  });
  page.on('pageerror', err => console.log('[pageerror]', err.message.slice(0, 400)));
  page.on('crash', () => { console.log('[PAGE CRASHED]'); process.exit(2); });

  console.log('Opening:', URL);
  await page.goto(URL, { waitUntil: 'domcontentloaded' });

  console.log('Waiting for kernel boot...');
  try {
    await waitForText(page, /~\s*#/, BOOT_TIMEOUT);
    console.log('Boot prompt detected!');
  } catch (e) {
    console.log('Boot failed:', (await getTermText(page)).slice(-1000));
    await browser.close(); process.exit(1);
  }
  await new Promise(r => setTimeout(r, 1000));

  // Write C source file
  console.log('Writing t.c...');
  await runCmd(page,
    `printf '%s' '${T_C}' > /tmp/t.c && echo "TC_OK"`,
    'TC_OK', 10000);
  console.log('t.c written!');
  await new Promise(r => setTimeout(r, 500));

  // Step 1: Test clang DRIVER (not -cc1 directly)
  // The driver will fork+exec clang -cc1 as a subprocess
  console.log('\n--- STEP 1: clang driver (fork+exec cc1) ---');
  console.log('Running: clang -target wasm32-unknown-unknown -c /tmp/t.c -o /tmp/t_driver.o');
  await page.evaluate(() => window.guestSend(
    "clang -target wasm32-unknown-unknown -matomics -mbulk-memory -c /tmp/t.c -o /tmp/t_driver.o; printf '\\nCLANG_DRV_EXIT_%d\\n' $?"
  ));
  console.log('Waiting for CLANG_DRV_EXIT_N (up to 5 min)...');
  let drvText;
  try {
    drvText = await waitForText(page, /CLANG_DRV_EXIT_\d+/, CMD_TIMEOUT);
  } catch (e) {
    console.log('Timeout waiting for clang driver result');
    console.log((await getTermText(page)).slice(-2000));
    await browser.close(); process.exit(1);
  }
  const drvExitLine = drvText.split('\n').reverse().find(l => /CLANG_DRV_EXIT_\d+/.test(l.trim()));
  const drvExit = drvExitLine ? parseInt(drvExitLine.trim().replace('CLANG_DRV_EXIT_', '')) : -1;
  console.log(`\n=== clang driver exit: ${drvExit} ===`);
  if (drvExit !== 0) {
    console.log('FAIL: clang driver did not exit 0');
    console.log(drvText.slice(-1000));
    await browser.close(); process.exit(1);
  }
  console.log('*** CLANG DRIVER SUCCEEDED (fork+exec cc1 works!) ***');

  // Check output file
  await runCmd(page,
    'ls -la /tmp/t_driver.o; printf "\\nOBJ_CHECK_OK\\n"',
    'OBJ_CHECK_OK', 10000);
  console.log((await getTermText(page)).slice(-300));

  // Step 2: Link with wasm-ld
  console.log('\n--- STEP 2: wasm-ld link ---');
  console.log('Running: wasm-ld /tmp/t_driver.o -o /tmp/t_pipeline.wasm ...');
  await page.evaluate(() => window.guestSend(
    "wasm-ld /tmp/t_driver.o -o /tmp/t_pipeline.wasm --no-entry --import-memory --export-memory --export-table --shared-memory --max-memory=268435456 --threads=1; printf '\\nWASMLD_PIPE_EXIT_%d\\n' $?"
  ));
  console.log('Waiting for WASMLD_PIPE_EXIT_N (up to 5 min)...');
  let ldText;
  try {
    ldText = await waitForText(page, /WASMLD_PIPE_EXIT_\d+/, CMD_TIMEOUT);
  } catch (e) {
    console.log('Timeout waiting for wasm-ld result');
    console.log((await getTermText(page)).slice(-2000));
    await browser.close(); process.exit(1);
  }
  const ldExitLine = ldText.split('\n').reverse().find(l => /WASMLD_PIPE_EXIT_\d+/.test(l.trim()));
  const ldExit = ldExitLine ? parseInt(ldExitLine.trim().replace('WASMLD_PIPE_EXIT_', '')) : -1;
  console.log(`\n=== wasm-ld exit: ${ldExit} ===`);

  // Check output
  await runCmd(page,
    'ls -la /tmp/t_pipeline.wasm; xxd /tmp/t_pipeline.wasm | head -2; printf "\\nFINAL_CHECK_OK\\n"',
    'FINAL_CHECK_OK', 10000);
  console.log((await getTermText(page)).slice(-500));

  if (ldExit === 0) {
    console.log('\n*** FULL PIPELINE SUCCEEDED: clang driver → object → wasm-ld → .wasm ***');
    await browser.close(); process.exit(0);
  } else {
    console.log(`\nFAIL: wasm-ld exit ${ldExit}`);
    await browser.close(); process.exit(1);
  }
})();
