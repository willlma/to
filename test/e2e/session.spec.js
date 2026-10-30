const {test, expect} = require('@playwright/test');
const {mkdtemp, rm} = require('node:fs/promises');
const {tmpdir} = require('node:os');
const {join} = require('node:path');

// Each browser lifetime gets its own trace below.
test.use({trace:'off'});

test('remember sign-in across browser restarts until explicitly signed out', async ({playwright}, testInfo) => {
  const profile = await mkdtemp(join(tmpdir(), 'town-session-'));
  let context;
  const openBrowser = async () => {
    context = await playwright.chromium.launchPersistentContext(profile, {
      ...testInfo.project.use.launchOptions,
      baseURL: testInfo.project.use.baseURL
    });
    await context.tracing.start({screenshots:true, snapshots:true});
    return context.pages()[0];
  };
  const closeBrowser = async name => {
    const path = testInfo.outputPath(`${name}.zip`);
    await context.tracing.stop({path});
    await testInfo.attach(name, {path, contentType:'application/zip'});
    await context.close();
    context = null;
  };
  const sessionCookie = async () =>
    (await context.cookies()).find(cookie => cookie.name === '_to_key');
  const expectLongLivedCookie = async () => {
    expect((await sessionCookie()).expires).toBeGreaterThan(
      Date.now() / 1000 + 390 * 24 * 60 * 60
    );
  };

  try {
    let page = await openBrowser();
    await page.goto('/auth/google');
    await page.getByRole('link', {name:'Continue as Will'}).click();
    await expect(page).toHaveURL(/\/lists(?:\/\d+)?$/);
    await expectLongLivedCookie();
    await closeBrowser('signed-in');

    page = await openBrowser();
    await page.goto('/lists');
    await expect(page.locator('.phx-connected')).toBeVisible();
    await expect(page).toHaveURL(/\/lists(?:\/\d+)?$/);

    // A returning visit must extend an existing cookie's expiry as well.
    await context.addCookies([{
      ...await sessionCookie(), expires:Date.now() / 1000 + 24 * 60 * 60
    }]);
    await page.goto('/settings');
    await expectLongLivedCookie();
    await page.getByRole('button', {name:'Sign out',exact:true}).click();
    await expect(page).toHaveURL('http://127.0.0.1:4002/');
    await closeBrowser('reopened-and-signed-out');

    page = await openBrowser();
    await page.goto('/lists');
    await expect(page).toHaveURL('http://127.0.0.1:4002/');
  } finally {
    if (context) await closeBrowser('final-browser');
    await rm(profile, {recursive:true, force:true});
  }
});
