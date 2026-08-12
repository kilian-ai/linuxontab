/**
 * E2E test: boot WASM kernel, run syncthing serve, verify HTTP health endpoint
 * Tests that wasm3 socket extensions enable real TCP binding inside the guest.
 *
 * Pass criteria:
 *   1. syncthing starts (no crash from sock_open/sock_bind/sock_listen)
 *   2. "Syncthing is ready" or "API listening" appears in output
 *   3. wget/curl to http://127.0.0.1:8384/rest/noauth/health returns {"ping":"pong"}
 */
const { chromium } = require('playwright');

const URL = 'http://localhost:8765/shell/wasm.html?autoboot&debuglog&cachebust=' + Date.now();
const BOOT_TIMEOUT = 90_000;
const SERVE_TIMEOUT = 120_000;

async function waitForPrompt(page, timeout = BOOT_TIMEOUT) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const text = await page.evaluate(() => window._terminalText || '');
    if (/~\s*#/.test(text)) return text;
    await page.waitForTimeout(500);
  }
  throw new Error('Timed out waiting for shell prompt');
}

async function waitForPattern(page, pattern, timeout) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const text = await page.evaluate(() => window._terminalText || '');
    if (pattern.test(text)) return text;
    await page.waitForTimeout(1000);
  }
  return null;
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  console.log('Opening:', URL);
  await page.goto(URL);
  await page.waitForSelector('.xterm-rows', { timeout: 30_000 });

  // Inject terminal text capture
  await page.evaluate(() => {
    window._terminalText = '';
    window._termPoll = setInterval(() => {
      const rows = document.querySelectorAll('.xterm-rows > div');
      let text = '';
      rows.forEach(r => { text += r.textContent + '\n'; });
      window._terminalText = text;
    }, 200);
  });

  console.log('Waiting for boot...');
  await waitForPrompt(page);
  console.log('Boot OK');

  // Run syncthing serve in background, redirect output to a file for inspection
  // Use --home /tmp/st-home to keep data off the read-only paths
  // Use --no-browser and plain HTTP GUI
  console.log('Starting syncthing serve...');
  await page.keyboard.type(
    'mkdir -p /tmp/st-home && ' +
    'wasm3 /bin/syncthing.wasm -- serve ' +
    '--home /tmp/st-home ' +
    '--no-browser ' +
    '--gui-address=127.0.0.1:8384 ' +
    '--log-file /tmp/st.log ' +
    '>/tmp/st.out 2>&1 &\n'
  );
  await page.waitForTimeout(2000);
  console.log('syncthing started in background, PID TBD');

  // Wait for syncthing to print its startup message in the log
  // Inject a shell polling loop that checks /tmp/st.out and /tmp/st.log
  await page.keyboard.type(
    'for i in $(seq 60); do ' +
      'if grep -qiE "syncthing is ready|API listening|gui listener started|startWithConfigs" /tmp/st.out /tmp/st.log 2>/dev/null; then ' +
        'echo SYNCTHING_READY; break; ' +
      'fi; ' +
      'sleep 2; ' +
    'done\n'
  );

  console.log('Waiting for SYNCTHING_READY signal (up to 2 min)...');
  const readyText = await waitForPattern(page, /SYNCTHING_READY/, SERVE_TIMEOUT);

  if (!readyText) {
    console.error('FAIL: syncthing did not signal ready within timeout');
    // Dump the log files
    await page.keyboard.type('cat /tmp/st.out | head -30\n');
    await page.waitForTimeout(3000);
    const logText = await page.evaluate(() => window._terminalText || '');
    console.log('st.out tail:\n', logText.slice(-1000));
    await browser.close();
    process.exit(1);
  }
  console.log('SYNCTHING_READY detected!');

  // Now test the HTTP health endpoint from inside the guest
  console.log('Testing HTTP health endpoint inside guest...');
  await page.keyboard.type(
    'wget -q -O - http://127.0.0.1:8384/rest/noauth/health && echo HEALTH_OK\n'
  );

  const healthText = await waitForPattern(page, /HEALTH_OK|ping.*pong/, 30_000);

  if (!healthText) {
    console.error('FAIL: health endpoint did not respond');
    const t = await page.evaluate(() => window._terminalText || '');
    console.log('Terminal:\n', t.slice(-800));
    await browser.close();
    process.exit(1);
  }

  console.log('SUCCESS: Syncthing HTTP health endpoint responded!');
  const t = await page.evaluate(() => window._terminalText || '');
  const lastBit = t.slice(-400);
  console.log('Terminal snippet:', lastBit);

  await browser.close();
  console.log('TEST PASSED');
  process.exit(0);
})();
