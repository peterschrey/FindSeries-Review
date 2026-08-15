/**
 * FRV-40 controlled A/B countercheck on the SAME readonly gate DB.
 *
 * A = Review-Base d5013ba (worktree) — NOT proven historical CSV generator
 * B = current HEAD
 *
 * Alternating pairs A→B→A→B→A→B; ≥10 samples/metric/state.
 * No writes.
 *
 *   REVIEW_FRV40_AB_A_ROOT=... npm run bench:frv40:ab
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  DEFAULT_GATE_DB,
  DEFAULT_PROJECT_ID,
  assertSafeBenchDb,
  benchDocDir,
  ensureBenchDir,
  fmtMs,
  stats,
  writeCsv,
} from './bench-shared.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '../../..');
const IS_WORKER = process.env.REVIEW_FRV40_AB_WORKER === '1';
const MARKER = '__FRV40_AB__';
const PAIRS = Number(process.env.REVIEW_FRV40_AB_PAIRS ?? 3);
const SAMPLES_PER_PHASE = Number(process.env.REVIEW_FRV40_AB_SAMPLES ?? 10);
const METRICS = [
  'gallery',
  'category_subtree',
  'category_gallery',
  'focus',
  'facets',
  'status_counts',
] as const;

type MetricName = (typeof METRICS)[number];

async function runWorker(): Promise<void> {
  const codeRoot = process.env.REVIEW_FRV40_AB_CODE_ROOT;
  const label = process.env.REVIEW_FRV40_AB_LABEL ?? '?';
  const dbPath = assertSafeBenchDb(process.env.REVIEW_PERF_DB_PATH ?? DEFAULT_GATE_DB);
  if (!codeRoot) throw new Error('REVIEW_FRV40_AB_CODE_ROOT required');

  const dbUrl = pathToFileURL(path.join(codeRoot, 'review/api/src/db.ts')).href;
  const galleryUrl = pathToFileURL(path.join(codeRoot, 'review/api/src/services/gallery.ts')).href;
  const groupsUrl = pathToFileURL(path.join(codeRoot, 'review/api/src/services/groups.ts')).href;
  const catsUrl = pathToFileURL(path.join(codeRoot, 'review/api/src/services/categories.ts')).href;
  const focusUrl = pathToFileURL(path.join(codeRoot, 'review/api/src/services/focus.ts')).href;

  const { openReviewDb } = await import(dbUrl);
  const { queryGallery, computeStatusCounts } = await import(galleryUrl);
  const { countCategorySubtree, queryFacets } = await import(catsUrl);
  const { queryFocus } = await import(focusUrl);
  // Touch groups import so A/B trees resolve deps consistently (not measured here).
  await import(groupsUrl);

  const db = openReviewDb(dbPath, { readonly: true });
  const mediaCount = (
    db.prepare(`SELECT COUNT(*) AS c FROM project_media WHERE project_id=?`).get(DEFAULT_PROJECT_ID) as {
      c: number;
    }
  ).c;
  const categoryId = (
    db
      .prepare(
        `SELECT category_id AS id FROM project_categories WHERE project_id=? ORDER BY COALESCE(member_count,0) DESC LIMIT 1`,
      )
      .get(DEFAULT_PROJECT_ID) as { id: number }
  ).id;
  const focusMediaId = (
    db.prepare(`SELECT media_id FROM project_media WHERE project_id=? ORDER BY media_id LIMIT 1`).get(
      DEFAULT_PROJECT_ID,
    ) as { media_id: number }
  ).media_id;

  const filterBase = {
    projectId: DEFAULT_PROJECT_ID,
    statuses: ['unreviewed', 'unsure'] as const,
  };

  const suite: Record<MetricName, () => void> = {
    gallery: () =>
      queryGallery(db, {
        ...filterBase,
        limit: 120,
        sort: 'media_id' as const,
        dir: 'asc' as const,
      }),
    category_subtree: () => countCategorySubtree(db, DEFAULT_PROJECT_ID, categoryId),
    category_gallery: () =>
      queryGallery(db, {
        ...filterBase,
        categoryIds: [categoryId],
        limit: 100,
        sort: 'media_id' as const,
        dir: 'asc' as const,
      }),
    focus: () => queryFocus(db, { projectId: DEFAULT_PROJECT_ID, focusMediaId }),
    facets: () => queryFacets(db, { ...filterBase }),
    status_counts: () =>
      computeStatusCounts(
        db,
        { projectId: DEFAULT_PROJECT_ID, statuses: ['unreviewed', 'keep', 'reject', 'unsure'] },
        { breakdownAllStatuses: true },
      ),
  };

  // Warm once per metric then sample
  const samples: Record<string, number[]> = {};
  for (const name of METRICS) {
    suite[name]();
    const arr: number[] = [];
    for (let i = 0; i < SAMPLES_PER_PHASE; i++) {
      const t0 = performance.now();
      suite[name]();
      arr.push(performance.now() - t0);
    }
    samples[name] = arr;
  }
  db.close();

  process.stdout.write(
    MARKER +
      JSON.stringify({
        label,
        codeRoot,
        dbPath,
        mediaCount,
        categoryId,
        focusMediaId,
        samples,
      }) +
      '\n',
  );
}

function spawnPhase(label: 'A' | 'B', codeRoot: string, dbPath: string): Promise<{
  label: string;
  samples: Record<string, number[]>;
  mediaCount: number;
}> {
  return new Promise((resolve, reject) => {
    // Always run from HEAD api tree (has tsx/node_modules); CODE_ROOT selects imports.
    const headApi = path.join(repoRoot, 'review/api');
    const child = spawn(process.execPath, ['--import', 'tsx', __filename], {
      cwd: headApi,
      env: {
        ...process.env,
        REVIEW_FRV40_AB_WORKER: '1',
        REVIEW_FRV40_AB_LABEL: label,
        REVIEW_FRV40_AB_CODE_ROOT: codeRoot,
        REVIEW_PERF_DB_PATH: dbPath,
      },
      stdio: ['ignore', 'pipe', 'inherit'],
    });
    let out = '';
    child.stdout.on('data', (b: Buffer) => {
      out += b.toString('utf8');
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`AB worker ${label} exited ${code}`));
        return;
      }
      const line = out
        .split(/\r?\n/)
        .map((l) => l.trim())
        .find((l) => l.startsWith(MARKER));
      if (!line) {
        reject(new Error(`AB worker ${label} missing marker`));
        return;
      }
      resolve(JSON.parse(line.slice(MARKER.length)));
    });
  });
}

async function parentMain(): Promise<void> {
  ensureBenchDir();
  const dbPath = assertSafeBenchDb(process.env.REVIEW_PERF_DB_PATH ?? DEFAULT_GATE_DB);
  if (!fs.existsSync(dbPath)) throw new Error(`Gate DB missing: ${dbPath}`);

  const rootA =
    process.env.REVIEW_FRV40_AB_A_ROOT ??
    path.resolve(repoRoot, '../FindSeries-Review-frv40-ab-a');
  const rootB = process.env.REVIEW_FRV40_AB_B_ROOT ?? repoRoot;
  if (!fs.existsSync(path.join(rootA, 'review/api/src/db.ts'))) {
    throw new Error(`A worktree missing: ${rootA}`);
  }

  const shaA = fs.existsSync(path.join(rootA, '.git'))
    ? ''
    : ''; // detached worktree: read via git -C
  void shaA;

  console.log(`FRV-40 A/B countercheck`);
  console.log(`  DB (shared readonly): ${dbPath}`);
  console.log(`  A code: ${rootA}`);
  console.log(`  B code: ${rootB}`);
  console.log(`  pairs=${PAIRS} samples/phase=${SAMPLES_PER_PHASE}`);

  const accA: Record<string, number[]> = Object.fromEntries(METRICS.map((m) => [m, []]));
  const accB: Record<string, number[]> = Object.fromEntries(METRICS.map((m) => [m, []]));
  let mediaCount = 0;

  for (let p = 1; p <= PAIRS; p++) {
    console.log(`\n=== pair ${p}/${PAIRS}: A → B ===`);
    const a = await spawnPhase('A', rootA, dbPath);
    mediaCount = a.mediaCount;
    for (const m of METRICS) accA[m]!.push(...(a.samples[m] ?? []));
    console.log(
      `  A media=${a.mediaCount} gallery_last=${fmtMs((a.samples.gallery ?? []).at(-1) ?? NaN)}`,
    );

    const b = await spawnPhase('B', rootB, dbPath);
    for (const m of METRICS) accB[m]!.push(...(b.samples[m] ?? []));
    console.log(
      `  B media=${b.mediaCount} gallery_last=${fmtMs((b.samples.gallery ?? []).at(-1) ?? NaN)}`,
    );
  }

  const rows: Array<Record<string, string | number | boolean | null>> = [];
  const summary: Array<{
    metric: string;
    a_p50: number;
    a_p95: number;
    b_p50: number;
    b_p95: number;
    delta_pct: number;
  }> = [];

  console.log('\n=== Summary (all samples) ===');
  let anyCodeRegression = false;
  for (const m of METRICS) {
    const sa = stats(accA[m]!);
    const sb = stats(accB[m]!);
    const delta = sa.p50 > 0 ? ((sb.p50 - sa.p50) / sa.p50) * 100 : NaN;
    if (delta > 20) anyCodeRegression = true;
    console.log(
      `  ${m}: A p50=${fmtMs(sa.p50)} p95=${fmtMs(sa.p95)} (n=${sa.n}) | B p50=${fmtMs(sb.p50)} p95=${fmtMs(sb.p95)} (n=${sb.n}) | Δ=${delta.toFixed(1)}%`,
    );
    summary.push({
      metric: m,
      a_p50: sa.p50,
      a_p95: sa.p95,
      b_p50: sb.p50,
      b_p95: sb.p95,
      delta_pct: delta,
    });
    rows.push({
      metric: m,
      state: 'A_d5013ba',
      p50_ms: +sa.p50.toFixed(2),
      p95_ms: +sa.p95.toFixed(2),
      n: sa.n,
      media_count: mediaCount,
      note: 'review-base code on current gate DB',
    });
    rows.push({
      metric: m,
      state: 'B_HEAD',
      p50_ms: +sb.p50.toFixed(2),
      p95_ms: +sb.p95.toFixed(2),
      n: sb.n,
      media_count: mediaCount,
      delta_pct_vs_A: +delta.toFixed(1),
      note: 'current HEAD on same gate DB',
    });
  }

  const classification = anyCodeRegression
    ? 'VERIFIED_CODE_REGRESSION'
    : 'VERIFIED_NO_CODE_REGRESSION';
  const evidence = anyCodeRegression
    ? 'HEAD >20% slower than d5013ba on identical DB for at least one open metric (VERIFIED).'
    : 'HEAD within 20% of d5013ba on identical DB for all open metrics (VERIFIED). Historical CSV deltas are not a current code regression vs Review-Base.';

  console.log(`\nClassification: ${classification}`);
  console.log(evidence);

  writeCsv(
    path.join(benchDocDir, 'frv40-ab-countercheck.csv'),
    ['metric', 'state', 'p50_ms', 'p95_ms', 'n', 'media_count', 'delta_pct_vs_A', 'note'],
    rows,
  );

  const md = `# FRV-40 A/B Countercheck (controlled)

**Date:** ${new Date().toISOString()}
**Shared DB:** \`${dbPath}\` (readonly; media=${mediaCount})
**A:** \`${rootA}\` @ Review-Base \`d5013ba\` (NOT proven historical CSV generator)
**B:** \`${rootB}\` @ current HEAD
**Pairs:** ${PAIRS} × alternating A→B · samples/phase=${SAMPLES_PER_PHASE} · total n/state=${PAIRS * SAMPLES_PER_PHASE}

## Historical baseline provenance

| Item | Status |
|---|---|
| File | \`docs/review-mvp/bench/frv40-results.baseline.csv\` (immutable) |
| Introduced in Git | \`c54ae4ba5b7989c874efb7777e60f9350f86ee9c\` (2026-08-15 01:46 +0200) |
| Exact generation commit / DB copy / host | **NOT_VERIFIED** (file first appears in that commit; run provenance not recorded) |
| Era methodology (from code at c54ae4b) | same-process Cold→Warm suite (INFERRED from \`bench-frv40.ts\` at that commit) |

This A/B is a **code regression countercheck vs Review-Base**, not a reproduction of the historical CSV provenance.

## Results

| Metric | A p50 | A p95 | B p50 | B p95 | Δ B vs A |
|---|---:|---:|---:|---:|---:|
${summary
  .map(
    (s) =>
      `| ${s.metric} | ${fmtMs(s.a_p50)} | ${fmtMs(s.a_p95)} | ${fmtMs(s.b_p50)} | ${fmtMs(s.b_p95)} | ${s.delta_pct.toFixed(1)}% |`,
  )
  .join('\n')}

## Classification

**${classification}**

${evidence}
`;
  fs.writeFileSync(path.join(benchDocDir, 'FRV40_AB_COUNTERCHECK.md'), md, 'utf8');
  console.log('Wrote frv40-ab-countercheck.csv and FRV40_AB_COUNTERCHECK.md');
  if (anyCodeRegression) process.exitCode = 2;
}

async function main() {
  if (IS_WORKER) await runWorker();
  else await parentMain();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
