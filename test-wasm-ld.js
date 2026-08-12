#!/usr/bin/env node
// Playwright test: boot WASM kernel and test wasm-ld linking
// Injects a pre-built .o via base64 to avoid loading clang (reduces memory pressure)
const { chromium } = require('playwright');

const URL = 'http://localhost:8765/shell/wasm.html?autoboot&debuglog&cachebust=38';
const BOOT_TIMEOUT = 600000;  // 10 min
const CMD_TIMEOUT  = 600000;  // 10 min for wasm-ld

// Pre-built wasm32-unknown-unknown object file (int main(){return 0;})
// Built on Mac with: clang -target wasm32-unknown-unknown --sysroot=$MUSL_SYSROOT -c t.c -o t.o
const T_O_B64 = 'AGFzbQEAAAABi4CAgAACYAABf2ACf38BfwLRgICAAAMDZW52D19fbGluZWFyX21lbW9yeQIAAANlbnYP\n' +
  'X19zdGFja19wb2ludGVyA38BA2VudhlfX2luZGlyZWN0X2Z1bmN0aW9uX3RhYmxlAXAAAAODgICAAAIA\n' +
  'AQq7gICAAAIpAQV/I4CAgIAAIQBBECEBIAAgAWshAkEAIQMgAiADNgIMQQAhBCAEDwsPAQF/EICAgIAA\n' +
  'IQIgAg8LAMGAgIAAB2xpbmtpbmcCCLKAgIAABQAEAA9fX29yaWdpbmFsX21haW4CEAAABAEEbWFpbgAE\n' +
  'AAtfX21haW5fdm9pZAWQAQAAk4CAgAAKcmVsb2MuQ09ERQMCBwYBADAAAKaAgIAACXByb2R1Y2VycwEM\n' +
  'cHJvY2Vzc2VkLWJ5AQVjbGFuZwYxOS4xLjcA34CAgAAPdGFyZ2V0X2ZlYXR1cmVzBisHYXRvbWljcysL\n' +
  'YnVsay1tZW1vcnkrCm11bHRpdmFsdWUrD211dGFibGUtZ2xvYmFscysPcmVmZXJlbmNlLXR5cGVzKwhz\n' +
  'aWduLWV4dA==';

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
    await new Promise(r => setTimeout(r, 800));
  }
  const text = await getTermText(page);
  throw new Error(`Timeout: ${pattern}\nTerminal:\n${text.slice(-2000)}`);
}

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--js-flags=--max-old-space-size=4096 --no-wasm-tier-up']
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
    console.log('Shell prompt detected!');
  } catch (e) {
    console.log('Boot failed:\n', (await getTermText(page)).slice(-1000));
    await browser.close(); process.exit(1);
  }

  await new Promise(r => setTimeout(r, 1000));

  // Inject pre-built .o via base64 (avoids loading clang binary into memory)
  console.log('Injecting pre-built t.o via base64...');
  const b64clean = T_O_B64.replace(/\n/g, '');
  await page.evaluate((b64) => window.guestSend(
    `printf '${b64}' | base64 -d > /tmp/t.o && echo "T_O_OK"`
  ), b64clean);

  try {
    await waitForText(page, 'T_O_OK', 15000);
    console.log('t.o injected successfully!');
  } catch (e) {
    console.log('Failed to inject t.o:', (await getTermText(page)).slice(-500));
    await browser.close(); process.exit(1);
  }

  await new Promise(r => setTimeout(r, 500));

  // Run wasm-ld
  console.log('Running wasm-ld...');
  await page.evaluate(() => window.guestSend(
    "wasm-ld /tmp/t.o -o /tmp/t.wasm --no-entry --import-memory --export-memory --export-table --shared-memory --max-memory=268435456 --threads=1; printf '\\nWASMLD_EXIT_%d\\n' $?"
  ));

  console.log('Waiting for WASMLD_EXIT_N (up to 3 min)...');
  let resultText;
  try {
    resultText = await waitForText(page, /WASMLD_EXIT_\d+/, CMD_TIMEOUT);
  } catch (e) {
    console.log('Timeout waiting for wasm-ld result');
    console.log((await getTermText(page)).slice(-2000));
    await browser.close(); process.exit(1);
  }

  const lines = resultText.split('\n');
  const outputLines = lines.filter(l => /^WASMLD_EXIT_\d+$/.test(l.trim()));
  const exitCode = outputLines.length > 0
    ? parseInt(outputLines[outputLines.length - 1].trim().replace('WASMLD_EXIT_', ''))
    : -1;

  console.log('\n=== RESULT ===');
  console.log('Exit code:', exitCode);

  if (exitCode === 0) {
    console.log('*** WASM-LD LINK SUCCEEDED ***');
    // Check output file
    await page.evaluate(() => window.guestSend('xxd /tmp/t.wasm | head -1; ls -la /tmp/t.wasm'));
    await new Promise(r => setTimeout(r, 3000));
    console.log((await getTermText(page)).slice(-500));
    await browser.close();
    process.exit(0);
  } else {
    console.log('*** WASM-LD FAILED (exit code:', exitCode, ') ***');
    console.log((await getTermText(page)).slice(-2000));
    await browser.close(); process.exit(1);
  }
})();
