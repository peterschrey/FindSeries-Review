import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  dblclickThumb,
  e2eBaseURL,
  e2eDbPath,
  openFreshApp,
  pressReviewKey,
  resultTotal,
  selectThumb,
  selectionCount,
  setGroupBy,
  toggleStatusChip,
} from './helpers';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../..');
const sqlite3 = path.join(repoRoot, 'Tools/sqlite3.exe');

/** No media_review_status row ⇒ sparse unreviewed (canonical). Explicit "unreviewed" row is NOT sparse. */
function dbStatus(mediaId: number): string {
  const count = execFileSync(
    sqlite3,
    [
      e2eDbPath(),
      `SELECT COUNT(*) FROM media_review_status WHERE project_id=7 AND media_id=${mediaId};`,
    ],
    { encoding: 'utf8' },
  ).trim();
  if (count === '0' || count === '') return 'SPARSE';
  return execFileSync(
    sqlite3,
    [e2eDbPath(), `SELECT status FROM media_review_status WHERE project_id=7 AND media_id=${mediaId};`],
    { encoding: 'utf8' },
  ).trim();
}

function dbExec(sql: string) {
  execFileSync(sqlite3, [e2eDbPath(), sql], { encoding: 'utf8' });
}

function resetFixtureReviewState() {
  dbExec(`
DELETE FROM media_review_history;
DELETE FROM media_review_batches;
DELETE FROM media_review_status;
INSERT OR REPLACE INTO media_review_status(
  project_id, media_id, status, changed_at, changed_by, source, action, batch_id
) VALUES (
  7, 4, 'keep', '2026-08-15T12:00:00.000Z', 'frv43-fixture', 'seed', 'set_status', NULL
);
`);
}

test.describe.configure({ mode: 'serial' });

test.beforeEach(async ({ page }) => {
  resetFixtureReviewState();
  await openFreshApp(page);
});

test('J1 — START / DEFAULT VIEW', async ({ page }) => {
  await expect(page.getByRole('heading', { name: 'FindSeries Review' })).toBeVisible();
  await expect(page.getByTestId('status-chip-unreviewed')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByTestId('status-chip-unsure')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByTestId('status-chip-keep')).toHaveAttribute('aria-pressed', 'false');
  await expect(page.getByTestId('status-chip-reject')).toHaveAttribute('aria-pressed', 'false');
  const total = await resultTotal(page);
  expect(total).toBeGreaterThan(50);
  await expect(page.getByTestId('summary-result-total')).toBeVisible();
  await expect(page.locator('.crumb', { hasText: 'Fehler' })).toHaveCount(0);
});

test('J2 — SINGLE CLICK SELECTION', async ({ page }) => {
  await selectThumb(page, 1);
  expect(await selectionCount(page)).toBe(1);
  await expect(page.getByTestId('thumb-1')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByTestId('summary-selection-total')).toContainText('1');
});

test('J3 — CTRL MULTISELECT / TOGGLE', async ({ page }) => {
  await selectThumb(page, 1);
  await selectThumb(page, 2, ['Control']);
  expect(await selectionCount(page)).toBe(2);
  await selectThumb(page, 2, ['Control']);
  expect(await selectionCount(page)).toBe(1);
  await expect(page.getByTestId('thumb-1')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByTestId('thumb-2')).toHaveAttribute('aria-pressed', 'false');
});

test('J4 — SHIFT RANGE', async ({ page }) => {
  await selectThumb(page, 1);
  await selectThumb(page, 3, ['Shift']);
  expect(await selectionCount(page)).toBe(3);
  await expect(page.getByTestId('thumb-1')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByTestId('thumb-2')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByTestId('thumb-3')).toHaveAttribute('aria-pressed', 'true');
});

test('J5 — RANGE REJECT VIA KEYBOARD', async ({ page }) => {
  const before = await resultTotal(page);
  await selectThumb(page, 1);
  await selectThumb(page, 3, ['Shift']);
  await pressReviewKey(page, 'r');
  await expect(page.getByTestId('bulk-banner')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('bulk-banner')).toContainText(/geändert/);
  await expect(page.getByTestId('thumb-1')).toHaveCount(0);
  const after = await resultTotal(page);
  expect(after).toBeLessThan(before);
});

test('J6 — UNDO VIA KEYBOARD', async ({ page }) => {
  await selectThumb(page, 5);
  await pressReviewKey(page, 'r');
  await expect(page.getByTestId('bulk-banner')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('thumb-5')).toHaveCount(0);
  await pressReviewKey(page, 'Control+z');
  await expect(page.locator('.toast', { hasText: /Undo/ })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('thumb-5')).toBeVisible({ timeout: 15_000 });
});

test('J7 — KEEP VIA KEYBOARD', async ({ page }) => {
  await selectThumb(page, 6);
  await pressReviewKey(page, 'k');
  await expect(page.getByTestId('bulk-banner')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('thumb-6')).toHaveCount(0);
  await toggleStatusChip(page, 'keep');
  await expect(page.getByTestId('thumb-6')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('thumb-6')).toHaveClass(/keep/);
});

test('J8 — KEEP PROTECTION IN BULK', async ({ page }) => {
  await toggleStatusChip(page, 'keep');
  await expect(page.getByTestId('thumb-4')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('thumb-1')).toBeVisible();
  await selectThumb(page, 1);
  await selectThumb(page, 4, ['Shift']);
  expect(await selectionCount(page)).toBe(4);
  await pressReviewKey(page, 'r');
  await expect(page.getByTestId('bulk-banner')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('bulk-banner')).toContainText(/Keep geschützt\s+[1-9]/);
  await expect(page.getByTestId('thumb-4')).toBeVisible();
  await expect(page.getByTestId('thumb-4')).toHaveClass(/keep/);
  expect(dbStatus(4)).toBe('keep');
  expect(dbStatus(1)).toBe('reject');
});

test('J9 — UNSURE + RESET (sparse)', async ({ page }) => {
  await expect(page.getByTestId('thumb-10')).toBeVisible({ timeout: 15_000 });
  await selectThumb(page, 10);
  await pressReviewKey(page, 'u');
  await expect(page.getByTestId('bulk-banner')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('thumb-10')).toBeVisible();
  await expect(page.getByTestId('thumb-10')).toHaveClass(/unsure/);
  expect(dbStatus(10)).toBe('unsure');
  await selectThumb(page, 10);
  await pressReviewKey(page, 'n');
  await expect(page.getByTestId('bulk-banner')).toBeVisible({ timeout: 15_000 });
  // reset_unreviewed must delete the row (sparse model) — not insert explicit unreviewed
  expect(dbStatus(10)).toBe('SPARSE');
});

test('J10 — CATEGORY NAVIGATION', async ({ page }) => {
  await expect(page.getByTestId('category-100')).toBeVisible({ timeout: 15_000 });
  const expand = page.locator('.catRow', { has: page.getByTestId('category-100') }).locator('.catExp');
  if (await expand.count()) {
    await expand.click();
  }
  await expect(page.getByTestId('category-101')).toBeVisible({ timeout: 10_000 });
  const before = await resultTotal(page);
  await page.getByTestId('category-101').click();
  await expect(page.locator('.crumb', { hasText: 'Kategorien' })).toBeVisible({ timeout: 10_000 });
  await expect.poll(async () => resultTotal(page)).toBeLessThan(before);
  const filtered = await resultTotal(page);
  expect(filtered).toBeGreaterThan(0);
  await page.locator('.crumb', { hasText: 'Kategorien' }).getByRole('button', { name: '×' }).click();
  await expect.poll(async () => resultTotal(page)).toBeGreaterThan(filtered);
});

test('J11 — GROUP DRILLDOWN', async ({ page }) => {
  await setGroupBy(page, 'series');
  await expect(page.getByTestId('group-card-Dental_chair_series')).toBeVisible({ timeout: 20_000 });
  const card = page.getByTestId('group-card-Dental_chair_series');
  const cardTotalText = await card.locator('.relCount').innerText();
  const cardTotal = Number(cardTotalText.replace(/\D/g, ''));
  await card.click();
  await expect(page.locator('.crumb', { hasText: /Dental_chair|Serie|series/i })).toBeVisible({ timeout: 10_000 });
  const drilled = await resultTotal(page);
  expect(drilled).toBe(cardTotal);
  await page.locator('.crumb').filter({ has: page.getByRole('button', { name: '×' }) }).last().getByRole('button', { name: '×' }).click();
});

test('J12 — DOUBLECLICK FOCUS + X', async ({ page }) => {
  await dblclickThumb(page, 1);
  await expect(page.getByTestId('focus-card')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('focus-card')).toContainText('#1');
  await expect(page.getByTestId('header-selection')).toContainText('Fokus #1');
  await expect(page.getByTestId('thumb-1').locator('.focusMarker')).toBeVisible();
  await expect(page.getByTestId('focus-relation-series')).toBeVisible({ timeout: 15_000 });
  await page.getByRole('button', { name: 'Fokus aufheben' }).click();
  await expect(page.getByTestId('focus-card')).toHaveCount(0);
});

test('J13 — ESC FOCUS', async ({ page }) => {
  await dblclickThumb(page, 2);
  await expect(page.getByTestId('focus-card')).toBeVisible({ timeout: 15_000 });
  await pressReviewKey(page, 'Escape');
  await expect(page.getByTestId('focus-card')).toHaveCount(0);
});

test('J14 — FOCUS RELATION', async ({ page }) => {
  await dblclickThumb(page, 1);
  await expect(page.getByTestId('focus-card')).toBeVisible({ timeout: 15_000 });
  const seriesRel = page.getByTestId('focus-relation-series');
  await expect(seriesRel).toBeVisible({ timeout: 15_000 });
  await expect(seriesRel).toBeEnabled();
  const cardTotal = Number((await seriesRel.locator('.relCount').innerText()).replace(/\D/g, ''));
  expect(cardTotal).toBeGreaterThan(0);
  const before = await resultTotal(page);
  await seriesRel.click();
  await expect(seriesRel).toHaveClass(/active/);
  await expect(page.getByTestId('focus-card')).toBeVisible();
  const after = await resultTotal(page);
  expect(after).toBeLessThan(before);
  expect(after).toBe(cardTotal);
  await seriesRel.click();
  await expect(seriesRel).not.toHaveClass(/active/);
  const similar = page.getByTestId('focus-relation-similar');
  await expect(similar).toBeVisible();
  await expect(similar).toBeDisabled();
  await expect(similar).toContainText(/P1|similar/i);
});

test('CHAIN — Notion kritische Journey', async ({ page }) => {
  // Kategorie 100 (Subtree) → Herkunft-Gruppe → Range≥2 → Reject → Stats → Undo → Fokus → Serie → Fokus-X
  // Herkunft-Gruppe lässt beide Serien (Dental + Instrument); Series-Relation muss danach einschränken.
  await expect(page.getByTestId('category-100')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('category-100').click();
  await expect(page.locator('.crumb', { hasText: 'Kategorien' })).toBeVisible({ timeout: 10_000 });
  await expect.poll(async () => resultTotal(page)).toBeGreaterThanOrEqual(5);

  await setGroupBy(page, 'provenance');
  const provenanceCard = page.getByTestId('group-card-category:category');
  await expect(provenanceCard).toBeVisible({ timeout: 20_000 });
  const groupCardTotal = Number((await provenanceCard.locator('.relCount').innerText()).replace(/\D/g, ''));
  expect(groupCardTotal).toBeGreaterThanOrEqual(2);
  await provenanceCard.click();
  await expect(page.locator('.crumb', { hasText: 'Category Search' })).toBeVisible({
    timeout: 10_000,
  });
  await expect.poll(async () => resultTotal(page)).toBe(groupCardTotal);

  const beforeReject = await resultTotal(page);
  expect(beforeReject).toBeGreaterThanOrEqual(2);
  await expect(page.getByTestId('thumb-1')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('thumb-3')).toBeVisible();
  await selectThumb(page, 1);
  await selectThumb(page, 3, ['Shift']);
  const selected = await selectionCount(page);
  expect(selected).toBeGreaterThanOrEqual(2);

  await pressReviewKey(page, 'r');
  await expect(page.getByTestId('bulk-banner')).toBeVisible({ timeout: 15_000 });
  await expect.poll(async () => resultTotal(page)).toBeLessThan(beforeReject);
  const afterReject = await resultTotal(page);

  await pressReviewKey(page, 'Control+z');
  await expect(page.locator('.toast', { hasText: /Undo/ })).toBeVisible({ timeout: 15_000 });
  await expect.poll(async () => resultTotal(page)).toBe(beforeReject);
  expect(afterReject).toBeLessThan(beforeReject);

  await dblclickThumb(page, 1);
  await expect(page.getByTestId('focus-card')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('focus-card')).toContainText('#1');
  const seriesRel = page.getByTestId('focus-relation-series');
  await expect(seriesRel).toBeVisible({ timeout: 15_000 });
  await expect(seriesRel).toBeEnabled();
  const seriesCardTotal = Number((await seriesRel.locator('.relCount').innerText()).replace(/\D/g, ''));
  expect(seriesCardTotal).toBeGreaterThan(0);
  const beforeRelation = await resultTotal(page);
  await seriesRel.click();
  await expect(seriesRel).toHaveClass(/active/);
  await expect.poll(async () => resultTotal(page)).toBeLessThan(beforeRelation);
  const afterRelation = await resultTotal(page);
  expect(afterRelation).toBe(seriesCardTotal);
  await expect(page.getByTestId('focus-card')).toBeVisible();

  await page.getByRole('button', { name: 'Fokus aufheben' }).click();
  await expect(page.getByTestId('focus-card')).toHaveCount(0);

  const health = await page.request.get(`${e2eBaseURL()}/api/projects`);
  expect(health.ok()).toBeTruthy();
});
