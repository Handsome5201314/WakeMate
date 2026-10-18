/* Read-only deployment smoke check: no patients or MCP configuration are created. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.WAKEMATE_PLAYWRIGHT_PATH || 'playwright');

async function main() {
  const envFile = path.resolve(__dirname, '../../../.env');
  const settings = fs.readFileSync(envFile, 'utf8').replace(/^\uFEFF/, '');
  const passwordLine = settings.split(/\r?\n/).find(line => line.startsWith('WAKEMATE_ADMIN_PASSWORD='));
  assert(passwordLine, 'Administrator password is not configured');
  const password = passwordLine.slice(passwordLine.indexOf('=') + 1).trim().replace(/^(["'])(.*)\1$/, '$2');
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
    await page.goto('https://wakemate.tongyimoheai.top/admin#mcp');
    await page.locator('#login-form input[name="username"]').fill('admin');
    await page.locator('#login-form input[name="password"]').fill(password);
    await page.locator('#login-form button[type="submit"]').click();
    const createBinding = page.getByRole('button', { name: '新建绑定', exact: true }).first();
    await createBinding.waitFor();
    assert(await createBinding.isEnabled(), 'New binding action is disabled');
    await createBinding.click();
    const dialog = page.getByRole('dialog');
    await dialog.waitFor();
    const title = await dialog.getByRole('heading').innerText();
    assert(['暂无可绑定患者', '新建 MCP 绑定'].includes(title), 'Expected binding workflow is missing');
    if (title === '暂无可绑定患者') {
      assert.match(await dialog.innerText(), /患者在 App 完成注册后，刷新本页即可选择/);
    }
    await dialog.getByRole('button', { name: '关闭', exact: true }).click();
    await dialog.waitFor({ state: 'hidden' });
    await page.screenshot({ path: path.join(__dirname, 'mcp-public.png'), fullPage: true });
    const report = { result: 'passed', public_ui: true, new_binding_enabled: true, dialog: title, mutations: 'none' };
    fs.writeFileSync(path.join(__dirname, 'mcp-public-verification.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report));
  } finally {
    await browser.close();
  }
}

main().catch(() => {
  console.error('Public MCP deployment smoke check failed; no credentials are printed.');
  process.exitCode = 1;
});
