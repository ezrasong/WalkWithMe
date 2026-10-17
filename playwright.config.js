import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './test/browser', fullyParallel: false, workers: 1,
  use: { baseURL: 'http://127.0.0.1:4180', viewport: { width: 1440, height: 1000 }, screenshot: 'only-on-failure' },
  webServer: { command: 'node src/server.js', url: 'http://127.0.0.1:4180/api/health', reuseExistingServer: false,
    env: { PORT: '4180', KAZE_DB: ':memory:' } }
});
