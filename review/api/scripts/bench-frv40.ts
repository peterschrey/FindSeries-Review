/**
 * FRV-40 100k+ API benchmark → docs/review-mvp/bench/frv40-results.csv
 *
 *   npm run bench:frv40
 *
 * Read queries: gate DB (readonly).
 * Bulk writes: REVIEW_WRITE_DB_PATH only (undo after).
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { openReviewDb, type ReviewDb } from '../src/db.js';
import { queryGallery, computeStatusCounts } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { countCategorySubtree, queryFacets } from '../src/services/categories.js';
import { queryFocus } from '../src/services/focus.js';
import { applyBulk, undoBatch } from '../src/services/bulk.js';
import { buildServer } from '../src/server.js';
import {
  DEFAULT_GATE_DB,
  DEFAULT_MEDIA_ROOTS,
  DEFAULT_PROJECT_ID,
  DEFAULT_WRITE_DB,
  benchDocDir,
  ensureBenchDir,
  fmtMs,
  measureSync,
  regressionFlags,
  rssMb,
  stats,
  timedMs,
  timedMsAsync,
  writeCsv,
} from './bench-shared.js';

const RUNS = Number(process.env.REVIEW_FRV40_RUNS ?? 2);
const ITERS = Number(process.env.REVIEW_BENCH_ITERS ?? 5);

type Row = Record<string, string | number | boolean | null>;

function pickCategoryId(db: ReviewDb, projectId: number): number {
  return (
    db
      .prepare(
        `SELECT category_id AS id FROM project_categories WHERE project_id=? ORDER BY COALESCE(member_count,0) DESC LIMIT 1`,
      )
      .get(projectId) as { id: number }
  ).id;
}

function pickFocus(db: ReviewDb, projectId: number): number {
  return (
    db
      .prepare(`SELECT media_id FROM project_media WHERE project_id=? ORDER BY media_id LIMIT 1`)
      .get(projectId) as { media_id: number }
  ).media_id;
}

function measureApi(
  label: string,
  cold: boolean,
  iterations: number,
  fn: () => void,
): { label: string; cold: boolean; p50: number; p95: number; mean: number; n: number } {
  if (!cold) fn(); // warm touch
  const samples: number[] = [];
  for (let i = 0; i < iterations; i++) samples.push(timedMs(fn).ms);
  const s = stats(samples);
  console.log(
    `  ${cold ? 'COLD' : 'WARM'} ${label}: p50=${fmtMs(s.p50)} p95=${fmtMs(s.p95)} (n=${s.n})`,
  );
  return { label, cold, p50: s.p50, p95: s.p95, mean: s.mean, n: s.n };
}

async function thumbSample(
  db: ReviewDb,
  projectId: number,
): Promise<{ cold_p50: number; warm_p50: number; n: number; note: string } | null> {
  const roots = DEFAULT_MEDIA_ROOTS.filter((r) => fs.existsSync(r));
  if (!roots.length) return null;
  const rows = db
    .prepare(
      `SELECT d.media_id AS media_id, d.local_path AS local_path
       FROM downloads d
       JOIN project_media pm ON pm.media_id=d.media_id AND pm.project_id=?
       WHERE d.local_path IS NOT NULL
       ORDER BY d.media_id LIMIT 80`,
    )
    .all(projectId) as Array<{ media_id: number; local_path: string }>;
  const ids = rows.filter((r) => fs.existsSync(r.local_path)).map((r) => r.media_id).slice(0, 20);
  if (ids.length < 5) return { cold_p50: NaN, warm_p50: NaN, n: 0, note: 'few accessible originals' };

  const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), 'frv40-thumbs-'));
  const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'frv40-log-'));
  const app = await buildServer({
    db,
    finalizeLogDir: logDir,
    deleteRoots: roots,
    mediaRoots: roots,
    thumbCacheDir: cacheDir,
  });
  const coldSamples: number[] = [];
  for (const id of ids) {
    coldSamples.push(
      (await timedMsAsync(() => app.inject({ method: 'GET', url: `/api/media/${id}/thumb?size=80` }))).ms,
    );
  }
  const warmSamples: number[] = [];
  for (const id of ids) {
    warmSamples.push(
      (await timedMsAsync(() => app.inject({ method: 'GET', url: `/api/media/${id}/thumb?size=80` }))).ms,
    );
  }
  await app.close();
  fs.rmSync(cacheDir, { recursive: true, force: true });
  fs.rmSync(logDir, { recursive: true, force: true });
  return {
    cold_p50: stats(coldSamples).p50,
    warm_p50: stats(warmSamples).p50,
    n: ids.length,
    note: 'ok',
  };
}

function runBulk(writeDb: ReviewDb, projectId: number, n: number): { ms: number; undoneMs: number } {
  const ids = (
    writeDb
      .prepare(
        `SELECT media_id FROM project_media WHERE project_id=? ORDER BY media_id LIMIT ?`,
      )
      .all(projectId, n) as Array<{ media_id: number }>
  ).map((r) => r.media_id);
  const { ms, value } = timedMs(() =>
    applyBulk(writeDb, {
      projectId,
      action: 'set_status',
      targetStatus: 'unsure',
      mediaIds: ids,
      protectKeep: true,
      source: 'bench-frv40',
      sessionId: 'frv40',
    }),
  );
  const undone = timedMs(() => undoBatch(writeDb, { projectId, batchId: value.batchId }));
  return { ms, undoneMs: undone.ms };
}

async function main() {
  ensureBenchDir();
  if (!fs.existsSync(DEFAULT_GATE_DB)) {
    console.error(`Gate DB missing: ${DEFAULT_GATE_DB}`);
    process.exit(2);
  }

  const readDb = openReviewDb(DEFAULT_GATE_DB, { readonly: true });
  const mediaCount = (
    readDb
      .prepare(`SELECT COUNT(*) AS c FROM project_media WHERE project_id=?`)
      .get(DEFAULT_PROJECT_ID) as { c: number }
  ).c;
  console.log(`project_media count=${mediaCount}`);
  if (mediaCount < 100_000) {
    console.error(`Need >=100k media; got ${mediaCount}`);
    process.exit(3);
  }

  const categoryId = pickCategoryId(readDb, DEFAULT_PROJECT_ID);
  const focusMediaId = pickFocus(readDb, DEFAULT_PROJECT_ID);
  const filterBase = {
    projectId: DEFAULT_PROJECT_ID,
    statuses: ['unreviewed', 'unsure'] as const,
  };

  const rows: Row[] = [];
  const regressionMetrics: Array<{ metric: string; p50: number; p95: number }> = [];

  for (let runId = 1; runId <= RUNS; runId++) {
    console.log(`\n=== run_id=${runId} RSS=${rssMb().toFixed(1)}MB ===`);
    for (const cold of [true, false]) {
      const tag = cold ? 'Cold' : 'Warm';
      const iters = cold ? Math.max(3, Math.min(ITERS, 5)) : ITERS;

      const suite: Array<{ name: string; fn: () => void }> = [
        {
          name: 'gallery',
          fn: () =>
            queryGallery(readDb, {
              ...filterBase,
              limit: 120,
              sort: 'media_id',
              dir: 'asc',
            }),
        },
        {
          name: 'groups_provenance',
          fn: () =>
            queryGroups(readDb, {
              ...filterBase,
              groupBy: 'provenance',
              limit: 20,
              sampleSize: 0,
            }),
        },
        {
          name: 'category_subtree',
          fn: () => countCategorySubtree(readDb, DEFAULT_PROJECT_ID, categoryId),
        },
        {
          name: 'category_gallery',
          fn: () =>
            queryGallery(readDb, {
              ...filterBase,
              categoryIds: [categoryId],
              limit: 100,
              sort: 'media_id',
              dir: 'asc',
            }),
        },
        {
          name: 'focus',
          fn: () => queryFocus(readDb, { projectId: DEFAULT_PROJECT_ID, focusMediaId }),
        },
        {
          name: 'facets',
          fn: () => queryFacets(readDb, { ...filterBase }),
        },
        {
          name: 'status_counts',
          fn: () =>
            computeStatusCounts(
              readDb,
              { projectId: DEFAULT_PROJECT_ID, statuses: ['unreviewed', 'keep', 'reject', 'unsure'] },
              { breakdownAllStatuses: true },
            ),
        },
      ];

      for (const s of suite) {
        const m = measureApi(s.name, cold, iters, s.fn);
        rows.push({
          run_id: runId,
          cache: tag,
          metric: s.name,
          p50_ms: +m.p50.toFixed(2),
          p95_ms: +m.p95.toFixed(2),
          mean_ms: +m.mean.toFixed(2),
          n: m.n,
          media_count: mediaCount,
          rss_mb: +rssMb().toFixed(1),
          note: '',
        });
        if (runId === RUNS && !cold) {
          regressionMetrics.push({ metric: s.name, p50: m.p50, p95: m.p95 });
        }
      }

      // time-to-first-grid ≈ gallery limit 120 (already measured as gallery)
      if (cold) {
        const ttf = rows.filter((r) => r.run_id === runId && r.cache === 'Cold' && r.metric === 'gallery')[0];
        rows.push({
          run_id: runId,
          cache: tag,
          metric: 'time_to_first_grid',
          p50_ms: ttf?.p50_ms ?? '',
          p95_ms: ttf?.p95_ms ?? '',
          mean_ms: ttf?.mean_ms ?? '',
          n: ttf?.n ?? 0,
          media_count: mediaCount,
          rss_mb: +rssMb().toFixed(1),
          note: '≈ gallery limit 120',
        });
      }
    }

    rows.push({
      run_id: runId,
      cache: 'N/A',
      metric: 'scroll_long_tasks',
      p50_ms: '',
      p95_ms: '',
      mean_ms: '',
      n: 0,
      media_count: mediaCount,
      rss_mb: +rssMb().toFixed(1),
      note: 'N/A — API-only bench; browser Long Tasks not available',
    });
  }

  // Thumbnails sample (once)
  console.log('\nThumbnail sample…');
  const thumbs = await thumbSample(readDb, DEFAULT_PROJECT_ID);
  if (thumbs) {
    rows.push({
      run_id: 1,
      cache: 'Cold',
      metric: 'thumbnail',
      p50_ms: Number.isFinite(thumbs.cold_p50) ? +thumbs.cold_p50.toFixed(2) : '',
      p95_ms: '',
      mean_ms: '',
      n: thumbs.n,
      media_count: mediaCount,
      rss_mb: +rssMb().toFixed(1),
      note: thumbs.note,
    });
    rows.push({
      run_id: 1,
      cache: 'Warm',
      metric: 'thumbnail',
      p50_ms: Number.isFinite(thumbs.warm_p50) ? +thumbs.warm_p50.toFixed(2) : '',
      p95_ms: '',
      mean_ms: '',
      n: thumbs.n,
      media_count: mediaCount,
      rss_mb: +rssMb().toFixed(1),
      note: thumbs.note,
    });
  } else {
    rows.push({
      run_id: 1,
      cache: 'N/A',
      metric: 'thumbnail',
      p50_ms: '',
      p95_ms: '',
      mean_ms: '',
      n: 0,
      media_count: mediaCount,
      rss_mb: +rssMb().toFixed(1),
      note: 'skipped — REVIEW_MEDIA_ROOTS inaccessible',
    });
  }

  readDb.close();

  // Bulk on write copy
  const writePath = fs.existsSync(DEFAULT_WRITE_DB) ? DEFAULT_WRITE_DB : null;
  if (!writePath) {
    console.warn(`Write DB missing at ${DEFAULT_WRITE_DB} — bulk metrics skipped`);
    for (const n of [1, 100, 10_000]) {
      rows.push({
        run_id: 1,
        cache: 'N/A',
        metric: `bulk_${n}`,
        p50_ms: '',
        p95_ms: '',
        mean_ms: '',
        n,
        media_count: mediaCount,
        rss_mb: +rssMb().toFixed(1),
        note: 'skipped — no write copy',
      });
    }
  } else {
    console.log(`\nBulk writes on ${writePath}`);
    const writeDb = openReviewDb(writePath, { readonly: false });
    for (const n of [1, 100, 10_000]) {
      const b = runBulk(writeDb, DEFAULT_PROJECT_ID, n);
      console.log(`  bulk n=${n}: ${fmtMs(b.ms)}ms (undo ${fmtMs(b.undoneMs)}ms)`);
      rows.push({
        run_id: 1,
        cache: 'N/A',
        metric: `bulk_${n}`,
        p50_ms: +b.ms.toFixed(2),
        p95_ms: +b.ms.toFixed(2),
        mean_ms: +b.ms.toFixed(2),
        n,
        media_count: mediaCount,
        rss_mb: +rssMb().toFixed(1),
        note: `undo_ms=${b.undoneMs.toFixed(1)}`,
      });
    }
    writeDb.close();
  }

  const outCsv = path.join(benchDocDir, 'frv40-results.csv');
  const baselineCsv = path.join(benchDocDir, 'frv40-results.baseline.csv');
  writeCsv(
    outCsv,
    ['run_id', 'cache', 'metric', 'p50_ms', 'p95_ms', 'mean_ms', 'n', 'media_count', 'rss_mb', 'note'],
    rows,
  );

  const flags = regressionFlags(baselineCsv, regressionMetrics, 0.2);
  if (flags.length) {
    console.log('\nRegression check:');
    for (const f of flags) console.log(' ', f);
  } else {
    console.log('\nRegression check: no baseline or no >20% regressions');
  }

  // silence unused import
  void measureSync;

  console.log(`Wrote ${outCsv}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
