import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFrv46Stack, stopFrv46Stack } from './frv46-stack.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../..');
const sqlite3 = path.join(repoRoot, 'Tools/sqlite3.exe');
const CLICK_DELAY_MS = 280;
const CAT_DENTISTRY = 7;
const SERIES_SUPPLEMENT_PROJECT = 9;
const SERIES_KEY = '02866_New_Luce_Church_of_Scotland,_New_Luce_';
const CATEGORY_ID = 14367; // Smiling men in the United States (API report)

test.describe.configure({ mode: 'serial' });

let baseURL = '';
let dbPath = '';
/** mediaIds touched by browser mutations — restored in afterAll */
const touchedByProject = new Map<number, Map<number, string>>(); // project -> (mediaId -> before status)

function dbExec(sql: string) {
  execFileSync(sqlite3, [dbPath, sql], { encoding: 'utf8' });
}

function dbStatus(projectId: number, mediaId: number): string {
  const count = execFileSync(
    sqlite3,
    [
      dbPath,
      `SELECT COUNT(*) FROM media_review_status WHERE project_id=${projectId} AND media_id=${mediaId};`,
    ],
    { encoding: 'utf8' },
  ).trim();
  if (count === '0' || count === '') return 'SPARSE';
  return execFileSync(
    sqlite3,
    [
      dbPath,
      `SELECT status FROM media_review_status WHERE project_id=${projectId} AND media_id=${mediaId};`,
    ],
    { encoding: 'utf8' },
  ).trim();
}

function snapshotIds(projectId: number, ids: number[]) {
  let map = touchedByProject.get(projectId);
  if (!map) {
    map = new Map();
    touchedByProject.set(projectId, map);
  }
  for (const id of ids) {
    if (!map.has(id)) map.set(id, dbStatus(projectId, id));
  }
}

function restoreAllTouched() {
  for (const [projectId, map] of touchedByProject) {
    for (const [id, expected] of map) {
      dbExec(
        `DELETE FROM media_review_status WHERE project_id=${projectId} AND media_id=${id};`,
      );
      if (expected !== 'SPARSE') {
        const esc = expected.replace(/'/g, "''");
        dbExec(`
INSERT INTO media_review_status(project_id, media_id, status, changed_at, changed_by, source, action, batch_id)
VALUES (${projectId}, ${id}, '${esc}', '2026-08-15T00:00:00.000Z', 'frv46-restore', 'test', 'set_status', NULL);
`);
      }
    }
  }
}

function verifyRestored() {
  let mismatch = 0;
  for (const [projectId, map] of touchedByProject) {
    for (const [id, expected] of map) {
      if (dbStatus(projectId, id) !== expected) mismatch += 1;
    }
  }
  if (mismatch > 0) {
    throw new Error(`FRV-46 cleanup restore mismatch for ${mismatch} media`);
  }
  // No FRV-46 fixture leftovers
  const leftovers = execFileSync(
    sqlite3,
    [
      dbPath,
      `SELECT COUNT(*) FROM media_review_status WHERE changed_by IN ('frv46-fixture','frv46-range-reject','frv46-seed-keep');`,
    ],
    { encoding: 'utf8' },
  ).trim();
  if (Number(leftovers) > 0) {
    throw new Error(`FRV-46 leftover test statuses: ${leftovers}`);
  }
}

async function pressReviewKey(page: import('@playwright/test').Page, key: string) {
  await page.locator('body').click({ position: { x: 5, y: 5 } });
  await page.keyboard.press(key);
}

test.beforeAll(async () => {
  const state = await startFrv46Stack();
  baseURL = state.baseURL;
  dbPath = state.dbPath;
  const res = await fetch(`${baseURL}/api/gallery/query`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      projectId: CAT_DENTISTRY,
      statuses: ['unreviewed', 'unsure'],
      limit: 5,
      sort: 'media_id',
      dir: 'asc',
    }),
  });
  expect(res.ok).toBeTruthy();
  const body = (await res.json()) as { total: number };
  expect(body.total).toBeGreaterThan(100_000);
});

test.afterAll(async () => {
  let cleanupError: unknown;
  try {
    if (dbPath && fs.existsSync(dbPath) && touchedByProject.size) {
      restoreAllTouched();
      verifyRestored();
    }
  } catch (e) {
    cleanupError = e;
  }
  try {
    await stopFrv46Stack();
  } catch (e) {
    if (!cleanupError) cleanupError = e;
  }
  if (cleanupError) throw cleanupError;
});

async function resultTotal(page: import('@playwright/test').Page) {
  const text = await page.getByTestId('result-total').innerText();
  const m = text.match(/Ergebnis:\s*([\d.]+)/);
  return m ? Number(m[1].replace(/\./g, '')) : -1;
}

async function openApp(page: import('@playwright/test').Page, projectId = CAT_DENTISTRY) {
  await page.addInitScript(() => {
    try {
      localStorage.clear();
    } catch {
      /* ignore */
    }
  });
  await page.route('**/api/media/*/thumb**', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'image/svg+xml',
      body: '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>',
    });
  });

  await page.goto(baseURL, { waitUntil: 'domcontentloaded' });
  await expect(page.getByRole('heading', { name: 'FindSeries Review' })).toBeVisible({
    timeout: 60_000,
  });
  await expect(page.getByTestId('gallery-scroll')).toBeVisible({ timeout: 60_000 });
  await expect
    .poll(async () => resultTotal(page), { timeout: 300_000, intervals: [1000, 2000, 5000] })
    .toBeGreaterThan(1000);

  if (projectId !== CAT_DENTISTRY) {
    await page.getByTestId('project-select').selectOption(String(projectId));
    await expect
      .poll(async () => resultTotal(page), { timeout: 300_000, intervals: [1000, 2000, 5000] })
      .toBeGreaterThan(100);
  }
}

test('A — Kategorieast UI', async ({ page }) => {
  await openApp(page);
  expect(await resultTotal(page)).toBeGreaterThan(100_000);
  const cat = page.getByTestId(`category-${CATEGORY_ID}`);
  await expect(cat).toBeVisible({ timeout: 120_000 });
  const before = await resultTotal(page);
  await cat.click();
  await expect(page.locator('.crumb', { hasText: 'Kategorien' })).toBeVisible({ timeout: 60_000 });
  await expect.poll(async () => resultTotal(page), { timeout: 120_000 }).toBeLessThan(before);
  const after = await resultTotal(page);
  expect(after).toBeGreaterThan(0);
  // Align with API report (~1621 for this category subtree under default statuses)
  expect(after).toBeGreaterThan(500);
  expect(after).toBeLessThan(5000);
});

test('B — Provenienz GroupCard → Drilldown', async ({ page }) => {
  await openApp(page);
  await page.getByTestId('group-by').selectOption('provenance');
  const card = page.getByTestId('group-card-category:category');
  await expect(card).toBeVisible({ timeout: 180_000 });
  const cardTotal = Number((await card.locator('.relCount').innerText()).replace(/\D/g, ''));
  expect(cardTotal).toBeGreaterThan(100_000);
  await card.click();
  await expect.poll(async () => resultTotal(page), { timeout: 180_000 }).toBe(cardTotal);
});

test('C — Serie Fallback + named Series supplemental (project 9)', async ({ page }) => {
  await openApp(page);
  await page.getByTestId('group-by').selectOption('series');
  const fallback = page.getByTestId('group-card-(ohne Serie)');
  await expect(fallback).toBeVisible({ timeout: 180_000 });
  const fbTotal = Number((await fallback.locator('.relCount').innerText()).replace(/\D/g, ''));
  expect(fbTotal).toBeGreaterThan(100_000);
  await fallback.click();
  await expect.poll(async () => resultTotal(page), { timeout: 180_000 }).toBe(fbTotal);

  // Supplemental named series on same gate DB, project Dental_Context_Search
  await page.getByTestId('project-select').selectOption(String(SERIES_SUPPLEMENT_PROJECT));
  await expect
    .poll(async () => resultTotal(page), { timeout: 180_000, intervals: [1000, 2000] })
    .toBeGreaterThan(1000);
  await page.getByTestId('group-by').selectOption('series');
  const named = page.getByTestId(`group-card-${SERIES_KEY}`);
  await expect(named).toBeVisible({ timeout: 180_000 });
  const namedTotal = Number((await named.locator('.relCount').innerText()).replace(/\D/g, ''));
  expect(namedTotal).toBeGreaterThanOrEqual(5);
  await named.click();
  await expect.poll(async () => resultTotal(page), { timeout: 120_000 }).toBe(namedTotal);
});

test('D — Range Reject + Undo (virtualized)', async ({ page }) => {
  await openApp(page);
  const before = await resultTotal(page);
  const scroller = page.getByTestId('gallery-scroll');
  const first = page.locator('[data-testid^="thumb-"]').first();
  await expect(first).toBeVisible({ timeout: 60_000 });
  const id1 = Number(await first.getAttribute('data-media-id'));
  await first.click();
  await page.waitForTimeout(CLICK_DELAY_MS);
  for (let i = 0; i < 8; i++) {
    await scroller.evaluate((el) => {
      el.scrollTop += 900;
    });
    await page.waitForTimeout(180);
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

  // Snapshot BEFORE mutation (route runs before API handler completes)
  await page.route('**/api/review/bulk**', async (route) => {
    try {
      const post = route.request().postDataJSON() as { mediaIds?: number[] };
      if (Array.isArray(post.mediaIds) && post.mediaIds.length) {
        snapshotIds(CAT_DENTISTRY, post.mediaIds.map(Number));
      }
    } catch {
      snapshotIds(CAT_DENTISTRY, [id1, id2]);
    }
    await route.continue();
  });

  await pressReviewKey(page, 'r');
  await expect(page.getByTestId('bulk-banner')).toBeVisible({ timeout: 90_000 });
  await expect.poll(async () => resultTotal(page), { timeout: 90_000 }).toBeLessThan(before);
  const afterReject = await resultTotal(page);
  expect(afterReject).toBeLessThan(before);

  await pressReviewKey(page, 'Control+z');
  await expect(page.locator('.toast', { hasText: /Undo/ })).toBeVisible({ timeout: 90_000 });
  await expect.poll(async () => resultTotal(page), { timeout: 90_000 }).toBe(before);
});

test('E — Fokusbeziehung + X', async ({ page }) => {
  await openApp(page);
  const thumb = page.locator('[data-testid^="thumb-"]').first();
  await expect(thumb).toBeVisible({ timeout: 60_000 });
  const focusId = Number(await thumb.getAttribute('data-media-id'));
  await thumb.dblclick();
  await expect(page.getByTestId('focus-card')).toBeVisible({ timeout: 90_000 });
  await expect(page.getByTestId('focus-card')).toContainText(`#${focusId}`);
  const rel = page.locator('[data-testid^="focus-relation-"]:not([disabled])').first();
  await expect(rel).toBeVisible({ timeout: 90_000 });
  await expect(rel).toBeEnabled();
  const cardTotal = Number((await rel.locator('.relCount').innerText()).replace(/\D/g, ''));
  expect(cardTotal).toBeGreaterThan(0);
  await rel.click();
  await expect(rel).toHaveClass(/active/);
  await expect.poll(async () => resultTotal(page), { timeout: 90_000 }).toBe(cardTotal);
  await page.getByRole('button', { name: 'Fokus aufheben' }).click();
  await expect(page.getByTestId('focus-card')).toHaveCount(0);
  await thumb.dblclick();
  await expect(page.getByTestId('focus-relation-similar')).toBeDisabled();
  await pressReviewKey(page, 'Escape');
  await expect(page.getByTestId('focus-card')).toHaveCount(0);
});
