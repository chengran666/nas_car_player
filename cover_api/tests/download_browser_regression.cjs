// Run with Node and Playwright available; each browser has a fresh test profile.
const { chromium } = require('playwright');
const fs = require('fs'), os = require('os'), path = require('path');
const { execFileSync } = require('child_process');
const assert = require('assert/strict');
(async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nas-download-test-'));
  let browser;
  try {
    fs.mkdirSync(path.join(root, 'updates'));
    fs.copyFileSync(path.join(__dirname, '../download.php'), path.join(root, 'download.php'));
    function release(code) {
      const downloads = {};
      for (const abi of ['universal', 'armeabi-v7a', 'arm64-v8a', 'x86_64']) {
        downloads[abi] = { apk_url: `updates/player-${code}-${abi}-abcdef012345.apk`, size: 20000000, sha256: 'a'.repeat(64) };
      }
      return { version_code: code, version_name: `1.0.${code}`, downloads, ...downloads.universal,
        notes: '</script><script>globalThis.compromised = true</script>', published_at: '2026-10-11T00:00:00Z' };
    }
    fs.writeFileSync(path.join(root, 'updates/latest.json'), JSON.stringify(release(7004)));
    fs.writeFileSync(path.join(root, 'updates/release-7003.json'), JSON.stringify(release(7003)));
    const html = execFileSync(process.env.PHP_BINARY || 'php', [path.join(root, 'download.php')], { encoding: 'utf8' });
    browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
    async function open(android, hint) {
      const context = await browser.newContext({ userAgent: android ? 'Mozilla/5.0 (Linux; Android 9) Chrome/74 Mobile' : 'Desktop test', viewport: { width: 800, height: 900 } });
      await context.addInitScript(value => Object.defineProperty(navigator, 'userAgentData', { value: value ? { getHighEntropyValues: async () => value } : undefined }), hint);
      await context.route('https://mp3.whzxc.com/', route => route.fulfill({ contentType: 'text/html; charset=utf-8', body: html }));
      const apkRequests = [];
      await context.route('https://mp3.whzxc.com/updates/*.apk', route => {
        apkRequests.push(route.request().url());
        return route.fulfill({ headers: { 'Content-Disposition': 'attachment; filename="player.apk"' }, contentType: 'application/vnd.android.package-archive', body: 'test fixture' });
      });
      const page = await context.newPage();
      await page.clock.install();
      const errors = []; page.on('pageerror', error => errors.push(error.message));
      await page.goto('https://mp3.whzxc.com/');
      await page.waitForFunction(() => document.querySelector('#version').options.length === 2);
      return { context, page, errors, apkRequests };
    }
    const desktop = await open(false);
    assert.equal(await desktop.page.locator('#packages a').count(), 4);
    assert.match(await desktop.page.locator('#recommended').getAttribute('href'), /7004-universal/);
    assert.equal(await desktop.page.locator('#countdown').count(), 0);
    assert.equal(await desktop.page.evaluate(() => globalThis.compromised), undefined);
    await desktop.page.locator('#version').selectOption({ index: 1 });
    assert.match(await desktop.page.locator('#recommended').getAttribute('href'), /7003-universal/);
    assert.deepEqual(desktop.errors, []);
    await desktop.context.close();
    const fallback = await open(true);
    assert.match(await fallback.page.locator('#recommended').getAttribute('href'), /universal/);
    await fallback.page.clock.runFor(8000);
    assert.deepEqual(fallback.apkRequests, []);
    assert.equal(await fallback.page.locator('#countdown').count(), 0);
    const [download] = await Promise.all([
      fallback.page.waitForEvent('download', { timeout: 5000 }),
      fallback.page.locator('#recommended').click(),
    ]);
    assert.match(download.url(), /7004-universal/);
    assert.equal(fallback.apkRequests.length, 1);
    assert.deepEqual(fallback.errors, []);
    await fallback.context.close();
    for (const [architecture, bitness, expected] of [['arm', '64', 'arm64-v8a'], ['arm', '32', 'armeabi-v7a'], ['x86', '64', 'x86_64']]) {
      const test = await open(true, { architecture, bitness });
      await test.page.waitForFunction(abi => document.querySelector('#recommended').href.includes(abi), expected);
      assert.match(await test.page.locator('#recommended').getAttribute('href'), new RegExp(expected));
      await test.page.clock.runFor(8000);
      assert.deepEqual(test.apkRequests, []);
      assert.deepEqual(test.errors, []);
      await test.context.close();
    }
    console.log('Download browser regression passed: desktop, Android fallback, ARM32/64, x86_64, history, manual download only, escaped notes.');
  } finally {
    if (browser) await browser.close();
    const resolved = fs.realpathSync(root);
    if (path.dirname(resolved) === fs.realpathSync(os.tmpdir()) && path.basename(resolved).startsWith('nas-download-test-')) {
      fs.rmSync(resolved, { recursive: true, force: true });
    }
  }
})().catch(error => { console.error(error); process.exit(1); });
