/**
 * FRV-40 100k+ API benchmark → docs/review-mvp/bench/frv40-results.csv
 *
 * Primary (baseline-compatible, used for >20% regression gate):
 *   one process / one SQLite connection per run_id, Cold suite → Warm suite
 *
 * Supplemental (optional, REVIEW_FRV40_SUPPLEMENTAL_CHILD=1):
 *   fresh-process cold-ish via child workers — NOT comparable 1:1 to baseline CSV
 *
 *   npm run bench:frv40
 *
 * Read queries: gate DB (readonly).
 * Bulk writes: assertSafeBenchWriteDb under C:\Temp\FindSeries-Review-Test only.
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
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
  assertSafeBenchDb,
  assertSafeBenchWriteDb,
  benchDocDir,
  ensureBenchDir,
  fmtMs,
  regressionFlags,
  rssMb,
  stats,
  timedMs,
  writeCsv,
} from './bench-shared.js';
import { ensureFrv40WriteDb } from './ensure-frv40-write-db.js';

const __filename = fileURLToPath(import.meta.url);
const IS_CHILD = process.env.REVIEW_FRV40_CHILD === '1';
const SUPPLEMENTAL_CHILD = process.env.REVIEW_FRV40_SUPPLEMENTAL_CHILD === '1';
const RUNS = Number(process.env.REVIEW_FRV40_RUNS ?? 2);
const ITERS = Number(process.env.REVIEW_BENCH_ITERS ?? 5);
const RESULT_MARKER = '__FRV40_RESULT__';

type Row = Record<string, string | number | boolean | null>;

type MetricResult = {
  label: string;
  cold: boolean;
  p50: number;
  p95: number;
  mean: number;
  n: number;
  rss_mb: number;
};

type ChildPayload = {
  mediaCount: number;
  metrics: MetricResult[];
  note: string;
};

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

function buildSuite(db: ReviewDb, categoryId: number, focusMediaId: number) {
  const filterBase = {
    projectId: DEFAULT_PROJECT_ID,
    statuses: ['unreviewed', 'unsure'] as const,
  };
  return [
    {
      name: 'gallery',
      fn: () =>
        queryGallery(db, {
          ...filterBase,
          limit: 120,
          sort: 'media_id' as const,
          dir: 'asc' as const,
        }),
    },
    {
      name: 'groups_provenance',
      fn: () =>
        queryGroups(db, {
          ...filterBase,
          groupBy: 'provenance' as const,
          limit: 20,
          sampleSize: 0,
        }),
    },
    {
      name: 'category_subtree',
      fn: () => countCategorySubtree(db, DEFAULT_PROJECT_ID, categoryId),
    },
    {
      name: 'category_gallery',
      fn: () =>
        queryGallery(db, {
          ...filterBase,
          categoryIds: [categoryId],
          limit: 100,
          sort: 'media_id' as const,
          dir: 'asc' as const,
        }),
    },
    {
      name: 'focus',
      fn: () => queryFocus(db, { projectId: DEFAULT_PROJECT_ID, focusMediaId }),
    },
    {
      name: 'facets',
      fn: () => queryFacets(db, { ...filterBase }),
    },
    {
      name: 'status_counts',
      fn: () =>
        computeStatusCounts(
          db,
          { projectId: DEFAULT_PROJECT_ID, statuses: ['unreviewed', 'keep', 'reject', 'unsure'] },
          { breakdownAllStatuses: true },
        ),
    },
  ];
}

function measureApi(
  label: string,
  cold: boolean,
  iterations: number,
  fn: () => void,
): MetricResult {
  if (!cold) fn();
  const samples: number[] = [];
  for (let i = 0; i < iterations; i++) samples.push(timedMs(fn).ms);
  const s = stats(samples);
  console.log(
    `  ${cold ? 'COLD' : 'WARM'} ${label}: p50=${fmtMs(s.p50)} p95=${fmtMs(s.p95)} (n=${s.n})`,
  );
  return {
    label,
    cold,
    p50: s.p50,
    p95: s.p95,
    mean: s.mean,
    n: s.n,
    rss_mb: rssMb(),
  };
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
  process.env.REVIEW_THUMB_CACHE_DIR = cacheDir;
  const app = await buildServer({
    db,
    mediaRoots: roots,
    thumbCacheDir: cacheDir,
    logDir,
  });
  await app.ready();
  const coldSamples: number[] = [];
  for (const id of ids) {
    const t0 = performance.now();
    await app.inject({ method: 'GET', url: `/api/media/${id}/thumb` });
    coldSamples.push(performance.now() - t0);
  }
  const warmSamples: number[] = [];
  for (const id of ids) {
    const t0 = performance.now();
    await app.inject({ method: 'GET', url: `/api/media/${id}/thumb` });
    warmSamples.push(performance.now() - t0);
  }
  await app.close();
  try {
    fs.rmSync(cacheDir, { recursive: true, force: true });
    fs.rmSync(logDir, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
  return {
    cold_p50: stats(coldSamples).p50,
    warm_p50: stats(warmSamples).p50,
    n: ids.length,
    note: 'ok',
  };
}

function runBulk(
  writeDb: ReviewDb,
  projectId: number,
  n: number,
): { ms: number; undoneMs: number; restoreOk: boolean } {
  const ids = (
    writeDb
      .prepare(
        `SELECT media_id FROM project_media WHERE project_id=? ORDER BY media_id LIMIT ?`,
      )
      .all(projectId, n) as Array<{ media_id: number }>
  ).map((r) => r.media_id);
  const sel = writeDb.prepare(
    `SELECT status FROM media_review_status WHERE project_id=? AND media_id=?`,
  );
  const before = new Map<number, string>();
  for (const id of ids) {
    const row = sel.get(projectId, id) as { status: string } | undefined;
    before.set(id, row?.status ?? 'SPARSE');
  }
  const { ms, value } = timedMs(() =>
    applyBulk(writeDb, {
      projectId,
      mediaIds: ids,
      action: 'set_status',
      targetStatus: 'reject',
      protectKeep: true,
      source: 'frv40-bench',
      sessionId: 'frv40',
    }),
  );
  const undone = timedMs(() => undoBatch(writeDb, { projectId, batchId: value.batchId }));
  let restoreOk = true;
  for (const id of ids) {
    const row = sel.get(projectId, id) as { status: string } | undefined;
    const st = row?.status ?? 'SPARSE';
    if (st !== before.get(id)) restoreOk = false;
  }
  return { ms, undoneMs: undone.ms, restoreOk };
}

function runWorkerPhase(cold: boolean, iterations: number): ChildPayload {
  const db = openReviewDb(DEFAULT_GATE_DB, { readonly: true });
  const mediaCount = (
    db.prepare(`SELECT COUNT(*) AS c FROM project_media WHERE project_id=?`).get(DEFAULT_PROJECT_ID) as {
      c: number;
    }
  ).c;
  const suite = buildSuite(db, pickCategoryId(db, DEFAULT_PROJECT_ID), pickFocus(db, DEFAULT_PROJECT_ID));
  const metrics: MetricResult[] = [];
  for (const s of suite) {
    metrics.push(measureApi(s.name, cold, iterations, s.fn));
  }
  const gal = metrics.find((m) => m.label === 'gallery');
  if (gal) metrics.push({ ...gal, label: 'time_to_first_grid' });
  db.close();
  return {
    mediaCount,
    metrics,
    note: cold
      ? 'supplemental fresh-process cold-ish (NOT baseline-comparable)'
      : 'supplemental warm in fresh child (NOT baseline-comparable)',
  };
}

function spawnWorker(cold: boolean, iterations: number, runId: number): Promise<ChildPayload> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', __filename], {
      env: {
        ...process.env,
        REVIEW_FRV40_CHILD: '1',
        REVIEW_FRV40_PHASE: cold ? 'cold' : 'warm',
        REVIEW_FRV40_ITERS: String(iterations),
        REVIEW_FRV40_RUN_ID: String(runId),
      },
      cwd: path.dirname(__filename),
      stdio: ['ignore', 'pipe', 'inherit'],
    });
    let out = '';
    child.stdout.on('data', (buf: Buffer) => {
      out += buf.toString('utf8');
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`FRV-40 child exited ${code}`));
        return;
      }
      const line = out
        .split(/\r?\n/)
        .map((l) => l.trim())
        .find((l) => l.startsWith(RESULT_MARKER));
      if (!line) {
        reject(new Error(`FRV-40 child missing ${RESULT_MARKER}`));
        return;
      }
      resolve(JSON.parse(line.slice(RESULT_MARKER.length)) as ChildPayload);
    });
  });
}

async function runChildMain(): Promise<void> {
  const cold = process.env.REVIEW_FRV40_PHASE !== 'warm';
  const iterations = Number(process.env.REVIEW_FRV40_ITERS ?? ITERS);
  process.stdout.write(RESULT_MARKER + JSON.stringify(runWorkerPhase(cold, iterations)) + '\n');
}

function pushMetricRows(
  rows: Row[],
  runId: number,
  cache: string,
  mediaCount: number,
  metrics: MetricResult[],
  note: string,
  coldDefinition: string,
): void {
  for (const m of metrics) {
    rows.push({
      run_id: runId,
      cache,
      metric: m.label,
      p50_ms: +m.p50.toFixed(2),
      p95_ms: +m.p95.toFixed(2),
      mean_ms: +m.mean.toFixed(2),
      n: m.n,
      media_count: mediaCount,
      rss_mb: +m.rss_mb.toFixed(1),
      note:
        m.label === 'time_to_first_grid'
          ? `API proxy ≈ gallery limit 120 (browser first-grid is authoritative); ${note}`
          : note,
      cold_definition: coldDefinition,
    });
  }
}

async function runParentMain(): Promise<void> {
  ensureBenchDir();
  assertSafeBenchDb(DEFAULT_GATE_DB);
  if (!fs.existsSync(DEFAULT_GATE_DB)) {
    console.error(`Gate DB missing: ${DEFAULT_GATE_DB}`);
    process.exit(2);
  }

  const readDb = openReviewDb(DEFAULT_GATE_DB, { readonly: true });
  const mediaCount = (
    readDb.prepare(`SELECT COUNT(*) AS c FROM project_media WHERE project_id=?`).get(DEFAULT_PROJECT_ID) as {
      c: number;
    }
  ).c;
  console.log(`project_media count=${mediaCount}`);
  if (mediaCount < 100_000) {
    console.error(`Need >=100k media; got ${mediaCount}`);
    process.exit(3);
  }

  const suite = buildSuite(
    readDb,
    pickCategoryId(readDb, DEFAULT_PROJECT_ID),
    pickFocus(readDb, DEFAULT_PROJECT_ID),
  );

  const rows: Row[] = [];
  const regressionMetrics: Array<{ metric: string; p50: number; p95: number }> = [];

  for (let runId = 1; runId <= RUNS; runId++) {
    console.log(`\n=== run_id=${runId} PRIMARY baseline-compatible (RSS=${rssMb().toFixed(1)}MB) ===`);
    for (const cold of [true, false]) {
      const tag = cold ? 'Cold' : 'Warm';
      const note = cold
        ? 'baseline-compatible: same process/connection; Cold suite first'
        : 'baseline-compatible: same process/connection after Cold suite';
      const coldDef = cold
        ? 'same-process suite (baseline-compatible)'
        : 'same-process suite after Cold (baseline-compatible)';
      console.log(`--- ${tag} ---`);
      const metrics: MetricResult[] = [];
      for (const s of suite) {
        metrics.push(measureApi(s.name, cold, ITERS, s.fn));
      }
      const gal = metrics.find((m) => m.label === 'gallery');
      if (gal) metrics.push({ ...gal, label: 'time_to_first_grid' });
      pushMetricRows(rows, runId, tag, mediaCount, metrics, note, coldDef);
      if (runId === RUNS && !cold) {
        for (const m of metrics) {
          if (m.label === 'time_to_first_grid') continue;
          regressionMetrics.push({ metric: m.label, p50: m.p50, p95: m.p95 });
        }
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
      note: 'See frv40-browser.csv / FRV40_BROWSER.md / FRV40_PERFORMANCE.md',
      cold_definition: '',
    });
  }

  if (SUPPLEMENTAL_CHILD) {
    console.log('\n=== SUPPLEMENTAL fresh-process children (not used for baseline regression) ===');
    for (let runId = 1; runId <= RUNS; runId++) {
      const coldPayload = await spawnWorker(true, ITERS, runId);
      pushMetricRows(
        rows,
        runId,
        'Cold',
        coldPayload.mediaCount,
        coldPayload.metrics.map((m) => ({ ...m, label: `supp_${m.label}` })),
        coldPayload.note,
        'supplemental fresh-process',
      );
      const warmPayload = await spawnWorker(false, ITERS, runId);
      pushMetricRows(
        rows,
        runId,
        'Warm',
        warmPayload.mediaCount,
        warmPayload.metrics.map((m) => ({ ...m, label: `supp_${m.label}` })),
        warmPayload.note,
        'supplemental fresh-process',
      );
    }
  }

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
      cold_definition: 'empty thumb cache in process',
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
      cold_definition: 'same-process',
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
      cold_definition: '',
    });
  }

  readDb.close();

  console.log('\nEnsuring C: write DB…');
  const writePath = ensureFrv40WriteDb();
  assertSafeBenchWriteDb(writePath);
  console.log(`\nBulk writes on ${writePath}`);
  const writeDb = openReviewDb(writePath, { readonly: false });
  let bulkRestoreFailed = false;
  for (const n of [1, 100, 10_000]) {
    const b = runBulk(writeDb, DEFAULT_PROJECT_ID, n);
    console.log(
      `  bulk n=${n}: ${fmtMs(b.ms)}ms (undo ${fmtMs(b.undoneMs)}ms; restoreOk=${b.restoreOk})`,
    );
    if (!b.restoreOk) bulkRestoreFailed = true;
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
      note: `undo_ms=${b.undoneMs.toFixed(1)}; restoreOk=${b.restoreOk}; db=C:compact`,
      cold_definition: '',
    });
  }
  writeDb.close();
  if (bulkRestoreFailed) {
    throw new Error('FRV-40 bulk restore verification failed — write DB status not restored');
  }

  const outCsv = path.join(benchDocDir, 'frv40-results.csv');
  const baselineCsv = path.join(benchDocDir, 'frv40-results.baseline.csv');
  writeCsv(
    outCsv,
    [
      'run_id',
      'cache',
      'metric',
      'p50_ms',
      'p95_ms',
      'mean_ms',
      'n',
      'media_count',
      'rss_mb',
      'note',
      'cold_definition',
    ],
    rows,
  );

  const flags = regressionFlags(baselineCsv, regressionMetrics, 0.2);
  if (flags.length) {
    console.log('\nRegression check (baseline-compatible Warm only):');
    for (const f of flags) console.log(' ', f);
  } else {
    console.log('\nRegression check: no >20% regressions vs baseline (method-matched Warm)');
  }

  console.log(`Wrote ${outCsv}`);
  console.log(
    'Primary Cold/Warm = same-process suite (baseline-compatible). Supplemental child: REVIEW_FRV40_SUPPLEMENTAL_CHILD=1.',
  );
}

async function main() {
  if (IS_CHILD) {
    await runChildMain();
    return;
  }
  await runParentMain();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
