#!/usr/bin/env node
// Playwright test: boot WASM kernel and test clang -cc1 compilation
const { chromium } = require('playwright');

const URL = 'http://localhost:8765/shell/wasm.html?autoboot&debuglog&cachebust=27';
const BOOT_TIMEOUT = 300000;  // 5 min for kernel boot (170MB rootfs download + WASM JIT)
const CMD_TIMEOUT  = 180000;  // 3 min for clang (large WASM binary)

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
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--js-flags=--max-old-space-size=4096']
  });
  const ctx = await browser.newContext();
  const page = await ctx.newPage();

  page.on('console', msg => {
    const t = msg.text();
    if (t.includes('ERR_INSUFFICIENT') || t.includes('Failed to load resource')) return;
    // Log all messages containing error/crash indicators
    if (msg.type() === 'error' || t.toLowerCase().includes('error') || t.includes('WORKER') || t.includes('call()') || t.includes('stack'))
      console.log('[browser]', t.slice(0, 2000));
  });
  page.on('pageerror', err => console.log('[pageerror]', err.message.slice(0, 200)));

  console.log('Opening:', URL);
  await page.goto(URL, { waitUntil: 'domcontentloaded' });

  console.log('Waiting for kernel boot...');
  try {
    // Look for ~ # anywhere (not just end-of-text) since wasm_call_clone_fn messages follow the prompt
    await waitForText(page, /~\s*#/, BOOT_TIMEOUT);
    console.log('Shell prompt detected!');
  } catch (e) {
    console.log('Boot failed:\n', (await getTermText(page)).slice(-1000));
    await browser.close(); process.exit(1);
  }

  await new Promise(r => setTimeout(r, 1000));

  // Write test file
  console.log('Writing test C file...');
  await page.evaluate(() => window.guestSend('printf "int main(){return 0;}\\n" > /tmp/t.c'));
  await new Promise(r => setTimeout(r, 2000));

  console.log('Running clang -cc1...');
  // Use printf with %d so the actual output "CLANG_EXIT_0" differs from the
  // command echo "printf '\\nCLANG_EXIT_%d\\n' $?" — no false positive possible.
  await page.evaluate(() => window.guestSend(
    "clang -cc1 -triple wasm32-unknown-unknown -emit-obj -o /tmp/t.o /tmp/t.c; printf '\\nCLANG_EXIT_%d\\n' $?"
  ));

  console.log('Waiting for CLANG_EXIT_N (up to 3 min)...');
  let resultText;
  try {
    resultText = await waitForText(page, /CLANG_EXIT_\d+/, CMD_TIMEOUT);
  } catch (e) {
    console.log('Timeout waiting for clang result');
    console.log((await getTermText(page)).slice(-2000));
    await browser.close(); process.exit(1);
  }

  const lines = resultText.split('\n');
  // Command echo contains "printf" and "%d"; actual output is just "CLANG_EXIT_N"
  const outputLines = lines.filter(l => /^CLANG_EXIT_\d+$/.test(l.trim()));
  const exitCode = outputLines.length > 0
    ? parseInt(outputLines[outputLines.length - 1].trim().replace('CLANG_EXIT_', ''))
    : -1;

  console.log('\n=== RESULT ===');
  console.log('All CLANG_EXIT_ lines:', lines.filter(l => /CLANG_EXIT_/.test(l)).map(l => JSON.stringify(l.trim())));
  console.log('Output lines:', outputLines);
  console.log('Exit code:', exitCode);

  if (exitCode === 0) {
    console.log('\n*** CLANG COMPILATION SUCCEEDED ***');
    await browser.close();
    process.exit(0);
  } else {
    console.log('\n*** CLANG FAILED (exit code:', exitCode, ') ***');
    // Print context
    const idx = lines.findLastIndex(l => /CLANG_EXIT_/.test(l));
    const start = Math.max(0, idx - 30);
    console.log(lines.slice(start, idx + 3).map(l => l.trim()).filter(Boolean).join('\n'));
    await browser.close();
    process.exit(1);
  }
})();
