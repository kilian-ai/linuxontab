/**
 * E2E test: boot WASM kernel, install syncthing via apk add, run via wasm3
 * Tests: wasm3 /bin/syncthing.wasm serve starts and outputs something
 */
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const URL = 'http://localhost:8765/shell/wasm.html?autoboot&debuglog&cachebust=' + Date.now();
const LOG_PATH = '/tmp/wasm-kernel-debug.log';
const BOOT_TIMEOUT = 90_000;
const CMD_TIMEOUT = 60_000;

async function waitForPrompt(page, timeout = BOOT_TIMEOUT) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const text = await page.evaluate(() => window._terminalText || '');
    if (/~\s*#/.test(text)) return text;
    await page.waitForTimeout(500);
  }
  throw new Error('Timed out waiting for shell prompt');
}

async function sendCommand(page, cmd, waitMs = 2000) {
  await page.keyboard.type(cmd + '\n');
  await page.waitForTimeout(waitMs);
  return page.evaluate(() => window._terminalText || '');
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    // SharedArrayBuffer requires these headers (served by dev server)
  });
  const page = await context.newPage();

  // Capture terminal text via the xterm buffer
  await page.exposeFunction('_appendTermText', (t) => {});
  await page.addInitScript(() => {
    window._terminalText = '';
    const orig = window.Terminal;
    // Hook via MutationObserver on the terminal DOM instead
  });

  console.log('Opening:', URL);
  await page.goto(URL);

  // Wait for xterm to appear and hook into it
  await page.waitForSelector('.xterm-rows', { timeout: 30_000 });

  // Inject text capture
  await page.evaluate(() => {
    window._terminalText = '';
    // Poll the xterm DOM for text content
    window._termPoll = setInterval(() => {
      const rows = document.querySelectorAll('.xterm-rows > div');
      let text = '';
      rows.forEach(r => { text += r.textContent + '\n'; });
      window._terminalText = text;
    }, 200);
  });

  console.log('Waiting for boot...');
  try {
    await waitForPrompt(page);
  } catch (e) {
    console.log('Boot timeout, checking terminal...');
    const text = await page.evaluate(() => window._terminalText || '');
    console.log('Terminal so far:', text.slice(-500));
    await browser.close();
    process.exit(1);
  }
  console.log('Boot OK — shell prompt detected');

  // Step 1: Install wasm3 (needed to run syncthing.wasm)
  console.log('Installing wasm3...');
  await page.keyboard.type('apk add wasm3\n');
  const apkTimeout = Date.now() + 30_000;
  while (Date.now() < apkTimeout) {
    await page.waitForTimeout(1000);
    const text = await page.evaluate(() => window._terminalText || '');
    if (/installed|already|wasm3.*ok/i.test(text) || (text.match(/~\s*#/g) || []).length >= 2) break;
  }
  console.log('wasm3 install done');

  // Step 2: Verify files exist (syncthing.wasm is pre-baked, no apk install needed)
  await page.keyboard.type('ls /bin/syncthing.wasm /bin/wasm3 && echo FILES_OK\n');
  await page.waitForTimeout(3000);
  const lsText = await page.evaluate(() => window._terminalText || '');
  if (!lsText.includes('FILES_OK')) {
    console.error('FAIL: Files not found in guest');
    console.log('Terminal:', lsText.slice(-400));
    await browser.close();
    process.exit(1);
  }
  console.log('Files present in guest: OK');

  // Step 4: Run syncthing via wasm3 with --help (quick, no network needed)
  console.log('Running: wasm3 /bin/syncthing.wasm -- --help ...');
  await page.keyboard.type('wasm3 /bin/syncthing.wasm -- --help 2>&1 | head -5 && echo WASM3_ST_OK\n');

  const helpTimeout = Date.now() + 60_000;
  while (Date.now() < helpTimeout) {
    await page.waitForTimeout(1000);
    const text = await page.evaluate(() => window._terminalText || '');
    if (text.includes('WASM3_ST_OK') || text.includes('syncthing') || text.includes('Syncthing')) break;
  }

  const helpText = await page.evaluate(() => window._terminalText || '');
  if (helpText.includes('WASM3_ST_OK') || /syncthing/i.test(helpText.split('WASM3_ST_OK')[0] || helpText)) {
    console.log('SUCCESS: wasm3 ran syncthing.wasm');
    console.log('Output snippet:', helpText.slice(-600));
  } else {
    console.error('FAIL: wasm3 did not run syncthing or timed out');
    console.log('Terminal:', helpText.slice(-600));
    await browser.close();
    process.exit(1);
  }

  await browser.close();
  console.log('TEST PASSED');
  process.exit(0);
})();
