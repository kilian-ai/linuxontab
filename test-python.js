#!/usr/bin/env node
// Playwright test: boot WASM kernel and test python3.11 -c "print(42)"
const { chromium } = require('playwright');

const URL = 'http://localhost:8765/shell/wasm.html?autoboot&debuglog&cachebust=260';
const BOOT_TIMEOUT = 300000;  // 5 min for kernel boot
const CMD_TIMEOUT  = 360000;  // 6 min for Python

async function getTermText(page) {
  return page.evaluate(() => {
    // Use xterm.js buffer API to get full scrollback (not just visible rows)
    if (window.__xterm__ && window.__xterm__.buffer && window.__xterm__.buffer.active) {
      const buf = window.__xterm__.buffer.active;
      const lines = [];
      for (let i = 0; i < buf.length; i++) {
        const line = buf.getLine(i);
        if (line) lines.push(line.translateToString(true));
      }
      return lines.join('\n');
    }
    // Fallback: DOM rows (visible only)
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
    if (msg.type() === 'error' || t.toLowerCase().includes('error') || t.includes('call()') || t.includes('WORKER'))
      console.log('[browser]', t.slice(0, 2000));
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

  await new Promise(r => setTimeout(r, 1000));

  // Test 1: python3.11 --version (should always work)
  console.log('Testing python3.11 --version...');
  await page.evaluate(() => window.guestSend("python3.11 --version; printf '\\nVERSION_EXIT_%d\\n' $?"));
  try {
    await waitForText(page, /VERSION_EXIT_\d+/, 30000);
    console.log('--version done');
  } catch (e) {
    console.log('--version timed out');
  }
  const afterVersion = await getTermText(page);
  const versionMatch = afterVersion.match(/Python [\d.]+/);
  console.log('Version output:', versionMatch ? versionMatch[0] : '(not found)');

  await new Promise(r => setTimeout(r, 500));

  // Test 2: python3.11 -c "print(42)"
  console.log('Running python3.11 -c "print(42)"...');
  await page.evaluate(() => window.guestSend(
    "rm -f /tmp/chk.txt /tmp/pyerr /tmp/pyout /tmp/pyexit; python3.11 -c \"print(42)\" > /tmp/pyout 2>/tmp/pyerr; echo $? > /tmp/pyexit; echo '=CHKFILE='; cat /tmp/chk.txt 2>/dev/null; echo '=PYERR='; cat /tmp/pyerr 2>/dev/null; echo '=ENDCHK='; echo \"PYTHON_EXIT_$(cat /tmp/pyexit)\""
  ));

  console.log('Waiting for PYTHON_EXIT_N (up to 6 min)...');
  let resultText;
  try {
    resultText = await waitForText(page, /PYTHON_EXIT_\d+/, CMD_TIMEOUT);
  } catch (e) {
    console.log('Timeout waiting for python result');
    console.log((await getTermText(page)).slice(-3000));
    await browser.close(); process.exit(1);
  }

  const exitMatch = resultText.match(/PYTHON_EXIT_(\d+)/);
  const exitCode = exitMatch ? parseInt(exitMatch[1]) : -1;
  console.log('Python exit code:', exitCode);

  // Show last part of terminal
  console.log('\nTerminal tail:');
  console.log(resultText.slice(-15000));

  if (exitCode === 0) {
    if (resultText.includes('42')) {
      console.log('\nSUCCESS: python3.11 -c "print(42)" → 42, exit 0');
    } else {
      console.log('\nPARTIAL: exit 0 but "42" not found in output');
    }
  } else {
    console.log(`\nFAILED: exit ${exitCode}`);
    process.exit(1);
  }

  await browser.close();
  process.exit(0);
})();
