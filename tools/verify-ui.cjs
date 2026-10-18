const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

async function main() {
  const envPath = path.resolve(__dirname, '../../../.env');
  const config = Object.fromEntries(fs.readFileSync(envPath, 'utf8').split(/\r?\n/)
    .filter(line => /^WAKEMATE_(ADMIN_PASSWORD|PORT)=/.test(line))
    .map(line => { const index = line.indexOf('='); return [line.slice(0, index), line.slice(index + 1).trim()]; }));
  const url = `http://127.0.0.1:${config.WAKEMATE_PORT || 8090}/admin`;
  const output = path.resolve(__dirname, '../verification');
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 960 } });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error' && !message.text().includes('Failed to load resource')) errors.push(message.text()); });
  try {
    await page.goto(url);
    await page.locator('#login-form [name=username]').fill('admin');
    await page.locator('#login-form [name=password]').fill(config.WAKEMATE_ADMIN_PASSWORD);
    await page.locator('#login-form button[type=submit]').click();
    await page.locator('#workspace').waitFor({ state: 'visible' });
    await page.locator('.metric-band').waitFor();
    await page.screenshot({ path: path.join(output, 'admin-desktop.png'), fullPage: true });
    const views = ['patients', 'plans', 'records', 'devices', 'notifications', 'mcp', 'audit', 'settings', 'overview'];
    for (const view of views) {
      await page.locator(`.nav-button[data-view=${view}]`).click();
      await page.waitForFunction(() => !document.querySelector('#refresh').disabled);
      assert.equal(await page.locator('.error-state').count(), 0, `view failed: ${view}`);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      assert.equal(overflow, false, `desktop overflow: ${view}`);
    }
    await page.reload();
    await page.locator('.metric-band').waitFor();
    await page.route('**/api/admin/status', route => route.fulfill({ status: 503, contentType: 'application/json', body: '{"detail":"Verification service unavailable"}' }));
    await page.locator('.nav-button[data-view=settings]').click();
    await page.locator('.error-state').waitFor();
    await page.unroute('**/api/admin/status');
    await page.locator('[data-action=reload]').click();
    await page.waitForFunction(() => !document.querySelector('#refresh').disabled);
    assert.equal(await page.locator('.error-state').count(), 0);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator('#menu-toggle').click();
    await page.locator('.nav-button[data-view=overview]').click();
    await page.locator('.metric-band').waitFor();
    await page.waitForFunction(() => document.querySelector('#sidebar').getBoundingClientRect().right <= 1);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, 'mobile overflow');
    await page.screenshot({ path: path.join(output, 'admin-mobile.png'), fullPage: true });
    for (const view of views) {
      await page.locator('#menu-toggle').click();
      await page.locator(`.nav-button[data-view=${view}]`).click();
      await page.waitForFunction(() => !document.querySelector('#refresh').disabled);
      assert.equal(await page.locator('.error-state').count(), 0, `mobile view failed: ${view}`);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `mobile overflow: ${view}`);
    }
    await page.locator('#logout').click();
    await page.locator('#login-screen').waitFor({ state: 'visible' });
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ result: 'passed', views: 9, desktop: '1440x960', mobile: '390x844', errorRecovery: true, screenshots: output }));
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
