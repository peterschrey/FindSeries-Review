import { defineConfig, devices } from '@playwright/test';

/**
 * FRV-46 real-DB browser acceptance — local only, never CI by default.
 * Requires C: gate DB + built api/web dist.
 */
export default defineConfig({
  testDir: './acceptance',
  testMatch: /frv46\.spec\.ts/,
  timeout: 300_000,
  expect: { timeout: 120_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    ...devices['Desktop Chrome'],
    headless: true,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    actionTimeout: 60_000,
    navigationTimeout: 120_000,
  },
  outputDir: './acceptance-results',
});
