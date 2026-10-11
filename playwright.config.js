const {defineConfig} = require('@playwright/test');
module.exports = defineConfig({
  testDir: './test/e2e', workers: 1, retries: 0, timeout: 45000,
  reporter: [['list'], ['html', {outputFolder: 'artifacts/e2e/report', open: 'never'}]],
  outputDir: 'artifacts/e2e/results',
  use: {
    baseURL: 'http://127.0.0.1:4002', browserName: 'chromium',
    launchOptions: {args: ['--no-sandbox']},
    trace: 'on', screenshot: 'on', timezoneId: 'America/Los_Angeles'
  },
  webServer: {command: 'bash scripts/e2e.sh', url: 'http://127.0.0.1:4010/__ready', timeout: 180000, reuseExistingServer: false}
});
