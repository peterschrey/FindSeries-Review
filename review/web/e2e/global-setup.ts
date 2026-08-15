import { startE2eStack } from './stack.mjs';

export default async function globalSetup() {
  const state = await startE2eStack();
  process.env.E2E_BASE_URL = state.baseURL;
  process.env.E2E_API_PORT = String(state.apiPort);
  process.env.E2E_WEB_PORT = String(state.webPort);
  process.env.E2E_DB_PATH = state.dbPath;
  // Playwright reads this in tests via process.env set from config.
  // Persist for workers:
  process.env.PLAYWRIGHT_E2E_BASE_URL = state.baseURL;
}
