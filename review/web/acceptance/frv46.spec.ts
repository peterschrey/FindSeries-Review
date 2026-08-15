import { test, expect } from '@playwright/test';
import { startFrv46Stack, stopFrv46Stack } from './frv46-stack.mjs';

const CLICK_DELAY_MS = 280;

test.describe.configure({ mode: 'serial' });

let baseURL = '';
let apiOrigin = '';

test.beforeAll(async () => {
  const state = await startFrv46Stack();
  baseURL = state.baseURL;
  apiOrigin = `http://127.0.0.1:${state.apiPort}`;
  const res = await fetch(`${apiOrigin}/api/gallery/query`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      projectId: 7,
      statuses: ['unreviewed', 'unsure'],
      limit: 5,
      sort: 'media_id',
      dir: 'asc',
    }),
  });
  expect(res.ok).toBeTruthy();
  const body = (await res.json()) as { total: number };
  expect(body.total).toBeGreaterThan(50_000);
});

test.afterAll(async () => {
  stopFrv46Stack();
});

async function resultTotal(page: import('@playwright/test').Page) {
  const text = await page.getByTestId('result-total').innerText();
  const m = text.match(/Ergebnis:\s*([\d.]+)/);
  return m ? Number(m[1].replace(/\./g, '')) : -1;
}

async function openApp(page: import('@playwright/test').Page) {
  await page.addInitScript(() => {
    try {
      localStorage.clear();
    } catch {
      /* ignore */
    }
  });
  // Playwright-side proxy: browser stays same-origin; Node fetch hits API (avoids Vite preview proxy hang).
  await page.route('**/api/**', async (route) => {
    const req = route.request();
    const u = new URL(req.url());
    const target = `${apiOrigin}${u.pathname}${u.search}`;
    if (u.pathname.includes('/thumb')) {
      await route.fulfill({
        status: 200,
        contentType: 'image/svg+xml',
        body: '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>',
      });
      return;
    }
    const headers: Record<string, string> = {};
    for (const [k, v] of Object.entries(req.headers())) {
      if (k.toLowerCase() === 'host') continue;
      headers[k] = v;
    }
    const res = await fetch(target, {
      method: req.method(),
      headers,
      body: req.postDataBuffer() ?? undefined,
    });
    const buf = Buffer.from(await res.arrayBuffer());
    const outHeaders: Record<string, string> = {};
    res.headers.forEach((v, k) => {
      if (k.toLowerCase() === 'transfer-encoding') return;
      outHeaders[k] = v;
    });
    await route.fulfill({ status: res.status, headers: outHeaders, body: buf });
  });

  const galleryWait = page.waitForResponse(
    (r) =>
      r.url().includes('/api/gallery/query') &&
      r.request().method() === 'POST' &&
      r.ok(),
    { timeout: 240_000 },
  );
  await page.goto(baseURL, { waitUntil: 'domcontentloaded' });
  await expect(page.getByRole('heading', { name: 'FindSeries Review' })).toBeVisible({
    timeout: 60_000,
  });
  const res = await galleryWait;
  const json = (await res.json()) as { total: number };
  expect(json.total).toBeGreaterThan(1000);
  await expect(page.getByTestId('gallery-scroll')).toBeVisible({ timeout: 60_000 });
  await expect
    .poll(async () => resultTotal(page), { timeout: 60_000, intervals: [500, 1000] })
    .toBeGreaterThan(1000);
}

test('FRV-46 UI — load + category', async ({ page }) => {
  await openApp(page);
  expect(await resultTotal(page)).toBeGreaterThan(50_000);
  const cat = page.locator('[data-testid^="category-"]').first();
  await expect(cat).toBeVisible({ timeout: 120_000 });
  const before = await resultTotal(page);
  await cat.click();
  await expect(page.locator('.crumb', { hasText: 'Kategorien' })).toBeVisible({ timeout: 60_000 });
  await expect.poll(async () => resultTotal(page), { timeout: 120_000 }).not.toBe(before);
});

test('FRV-46 UI — provenance group', async ({ page }) => {
  await openApp(page);
  await page.getByTestId('group-by').selectOption('provenance');
  const card = page.locator('[data-testid^="group-card-"]').first();
  await expect(card).toBeVisible({ timeout: 180_000 });
  const cardTotal = Number((await card.locator('.relCount').innerText()).replace(/\D/g, ''));
  await card.click();
  await expect.poll(async () => resultTotal(page), { timeout: 180_000 }).toBe(cardTotal);
});

test('FRV-46 UI — series group', async ({ page }) => {
  await openApp(page);
  await page.getByTestId('group-by').selectOption('series');
  const card = page.locator('[data-testid^="group-card-"]').first();
  await expect(card).toBeVisible({ timeout: 180_000 });
  const cardTotal = Number((await card.locator('.relCount').innerText()).replace(/\D/g, ''));
  await card.click();
  await expect.poll(async () => resultTotal(page), { timeout: 180_000 }).toBe(cardTotal);
});

test('FRV-46 UI — range reject + undo', async ({ page }) => {
  await openApp(page);
  const before = await resultTotal(page);
  const scroller = page.getByTestId('gallery-scroll');
  const first = page.locator('[data-testid^="thumb-"]').first();
  await expect(first).toBeVisible({ timeout: 60_000 });
  const id1 = Number(await first.getAttribute('data-media-id'));
  await first.click();
  await page.waitForTimeout(CLICK_DELAY_MS);
  for (let i = 0; i < 6; i++) {
    await scroller.evaluate((el) => {
      el.scrollTop += 800;
    });
    await page.waitForTimeout(200);
  }
  const thumbs = page.locator('[data-testid^="thumb-"]');
  const count = await thumbs.count();
  expect(count).toBeGreaterThan(1);
  const last = thumbs.nth(count - 1);
  const id2 = Number(await last.getAttribute('data-media-id'));
  expect(id2).not.toBe(id1);
  await last.click({ modifiers: ['Shift'] });
  await page.waitForTimeout(CLICK_DELAY_MS);
  const selText = await page.getByTestId('header-selection').innerText();
  const sel = Number((selText.match(/Auswahl\s+(\d+)/) || [])[1] || 0);
  expect(sel).toBeGreaterThanOrEqual(2);
  await page.locator('body').click({ position: { x: 5, y: 5 } });
  await page.keyboard.press('r');
  await expect(page.getByTestId('bulk-banner')).toBeVisible({ timeout: 90_000 });
  await expect.poll(async () => resultTotal(page), { timeout: 90_000 }).toBeLessThan(before);
  await page.keyboard.press('Control+z');
  await expect(page.locator('.toast', { hasText: /Undo/ })).toBeVisible({ timeout: 90_000 });
  await expect.poll(async () => resultTotal(page), { timeout: 90_000 }).toBe(before);
});

test('FRV-46 UI — focus relation', async ({ page }) => {
  await openApp(page);
  const thumb = page.locator('[data-testid^="thumb-"]').first();
  await expect(thumb).toBeVisible({ timeout: 60_000 });
  const focusId = Number(await thumb.getAttribute('data-media-id'));
  await thumb.dblclick();
  await expect(page.getByTestId('focus-card')).toBeVisible({ timeout: 90_000 });
  await expect(page.getByTestId('focus-card')).toContainText(`#${focusId}`);
  const rel = page.locator('[data-testid^="focus-relation-"]:not([disabled])').first();
  await expect(rel).toBeEnabled({ timeout: 90_000 });
  const cardTotal = Number((await rel.locator('.relCount').innerText()).replace(/\D/g, ''));
  await rel.click();
  await expect(rel).toHaveClass(/active/);
  await expect.poll(async () => resultTotal(page), { timeout: 90_000 }).toBe(cardTotal);
  await page.getByRole('button', { name: 'Fokus aufheben' }).click();
  await expect(page.getByTestId('focus-card')).toHaveCount(0);
  await thumb.dblclick();
  await expect(page.getByTestId('focus-relation-similar')).toBeDisabled();
  await page.keyboard.press('Escape');
});
