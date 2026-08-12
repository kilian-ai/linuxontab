#!/usr/bin/env node
// Playwright test: boot WASM kernel and test nested $() command substitution
const { chromium } = require('playwright');

const URL = 'http://localhost:8765/shell/wasm.html?autoboot&debuglog&cachebust=50';
const BOOT_TIMEOUT = 300000;  // 5 min for kernel boot
const CMD_TIMEOUT  = 30000;   // 30s for simple shell command

async function getTermText(page) {
  return page.evaluate(() => {
    const rows = document.querySelectorAll('#term .xterm-rows > div');
    return Array.from(rows).map(r => r.textContent).join('\n');
  });
}

async function waitForText(page, pattern, timeout = BOOT_TIMEOUT) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const text = await getTermText(page);
    if (typeof pattern === 'string' ? text.includes(pattern) : pattern.test(text))
      return text;
    await new Promise(r => setTimeout(r, 500));
  }
  const text = await getTermText(page);
  throw new Error(`Timeout waiting for: ${pattern}\nTerminal:\n${text.slice(-2000)}`);
}

(async () => {
  const consoleLogs = [];
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--js-flags=--max-old-space-size=4096']
  });
  const ctx = await browser.newContext();
  const page = await ctx.newPage();

  page.on('console', msg => {
    const t = msg.text();
    if (t.includes('ERR_INSUFFICIENT') || t.includes('Failed to load resource')) return;
    consoleLogs.push(t.slice(0, 1000));
    // Print diagnostics immediately
    if (t.includes('FORK_INIT') || t.includes('FORK_DIAG') || t.includes('WORKER') || t.includes('fork:') || msg.type() === 'error') {
      console.log('[browser]', t.slice(0, 500));
    }
  });
  page.on('pageerror', err => console.log('[pageerror]', err.message.slice(0, 200)));

  console.log('Opening:', URL);
  await page.goto(URL, { waitUntil: 'domcontentloaded' });

  console.log('Waiting for kernel boot...');
  try {
    await waitForText(page, /~\s*#/, BOOT_TIMEOUT);
    console.log('Shell prompt detected!');
  } catch (e) {
    console.log('Boot failed:\n', (await getTermText(page)).slice(-1000));
    await browser.close(); process.exit(1);
  }

  await new Promise(r => setTimeout(r, 1500));
  consoleLogs.length = 0; // clear pre-boot logs

  // Test 1: simple $() (should work)
  console.log('\n--- Test 1: single $() ---');
  await page.evaluate(() => window.guestSend('echo "T1:$(echo single)"; echo DONE_T1'));
  try {
    await waitForText(page, 'DONE_T1', 15000);
    const t = await getTermText(page);
    const line = t.split('\n').find(l => l.includes('T1:'));
    console.log('Result:', line?.trim() || '(not found)');
  } catch(e) { console.log('TIMEOUT on Test 1'); }

  await new Promise(r => setTimeout(r, 1000));
  consoleLogs.length = 0;

  // Test 2: nested $() (the failing case)
  console.log('\n--- Test 2: nested $()$(()) ---');
  await page.evaluate(() => window.guestSend('echo "T2:$(echo $(echo nested))"; echo DONE_T2'));
  try {
    await waitForText(page, 'DONE_T2', CMD_TIMEOUT);
    const t = await getTermText(page);
    const line = t.split('\n').find(l => l.includes('T2:'));
    console.log('Result:', line?.trim() || '(not found)');
  } catch(e) {
    console.log('TIMEOUT on Test 2 (nested fork hung as expected)');
  }

  // Print all console logs captured during test 2
  console.log('\n--- Browser console logs ---');
  for (const log of consoleLogs) {
    if (log.includes('FORK_INIT') || log.includes('FORK_DIAG') || log.includes('SPAWN_WORKER') ||
        log.includes('fork:') || log.includes('WORKER') || log.includes('call()')) {
      console.log('[browser]', log);
    }
  }

  // Dump the debug log
  console.log('\n--- Fetching debug log ---');
  try {
    const debugLog = await page.evaluate(() =>
      fetch('/log-dump').then(r => r.text()).catch(() => 'fetch failed')
    );
    console.log(debugLog);
  } catch(e) {}

  await browser.close();
  process.exit(0);
})();
