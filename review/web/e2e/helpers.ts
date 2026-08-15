import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, type Page } from '@playwright/test';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CLICK_DELAY_MS = 260;

export function e2eBaseURL(): string {
  const statePath = path.join(__dirname, '.run-state.json');
  const state = JSON.parse(fs.readFileSync(statePath, 'utf8')) as { baseURL: string };
  return state.baseURL;
}

export function e2eDbPath(): string {
  const statePath = path.join(__dirname, '.run-state.json');
  const state = JSON.parse(fs.readFileSync(statePath, 'utf8')) as { dbPath: string };
  return state.dbPath;
}

export async function openFreshApp(page: Page) {
  await page.addInitScript(() => {
    try {
      localStorage.clear();
    } catch {
      /* ignore */
    }
  });
  await page.goto(e2eBaseURL(), { waitUntil: 'domcontentloaded' });
  await expect(page.getByRole('heading', { name: 'FindSeries Review' })).toBeVisible();
  await expect(page.getByTestId('gallery-scroll')).toBeVisible({ timeout: 30_000 });
  // Wait until gallery finished initial load (result crumb present)
  await expect(page.getByTestId('result-total')).toContainText(/Ergebnis:/, { timeout: 30_000 });
  // Ensure thumbs rendered
  await expect(page.getByTestId('thumb-1')).toBeVisible({ timeout: 30_000 });
}

export async function selectThumb(page: Page, mediaId: number, modifiers: ('Control' | 'Shift')[] = []) {
  await page.getByTestId(`thumb-${mediaId}`).click({ modifiers });
  await page.waitForTimeout(CLICK_DELAY_MS);
}

export async function dblclickThumb(page: Page, mediaId: number) {
  await page.getByTestId(`thumb-${mediaId}`).dblclick();
}

export async function selectionCount(page: Page): Promise<number> {
  const text = await page.getByTestId('header-selection').innerText();
  const m = text.match(/Auswahl\s+(\d+)/);
  return m ? Number(m[1]) : -1;
}

export async function resultTotal(page: Page): Promise<number> {
  const text = await page.getByTestId('result-total').innerText();
  const m = text.match(/Ergebnis:\s*([\d.]+)/);
  if (!m) return -1;
  return Number(m[1].replace(/\./g, ''));
}

export async function pressReviewKey(page: Page, key: string) {
  // Ensure focus is not in an input
  await page.locator('body').click({ position: { x: 5, y: 5 } });
  await page.keyboard.press(key);
}

export async function toggleStatusChip(page: Page, status: string) {
  await page.getByTestId(`status-chip-${status}`).click();
}

export async function setGroupBy(page: Page, value: string) {
  await page.getByTestId('group-by').selectOption(value);
}

/** Sparse check via API through web proxy: no keep/reject/unsure row or explicit unreviewed. */
export async function mediaStatusViaApi(page: Page, projectId: number, mediaId: number): Promise<string> {
  const res = await page.request.post(`${e2eBaseURL()}/api/gallery/query`, {
    data: {
      projectId,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      mediaIds: [mediaId],
      limit: 1,
    },
  });
  expect(res.ok()).toBeTruthy();
  const body = await res.json();
  const item = body.items?.[0];
  return item?.reviewStatus ?? 'missing';
}
