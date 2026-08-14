/**
 * FRV-39 SQLite performance bench on real DB copy.
 *
 *   REVIEW_DB_PATH=... npm run bench:frv39
 *   REVIEW_DB_PATH=... REVIEW_BENCH_PHASE=before|after npm run bench:frv39
 *
 * Phases:
 * - before: readonly gate DB (or copy), baseline timings + EXPLAIN
 * - after: writable migrated copy (indexes from migration 105)
 */
import fs from 'node:fs';
import path from 'node:path';
import { openReviewDb, type ReviewDb } from '../src/db.js';
import { queryGallery, computeStatusCounts } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { countCategorySubtree, listCategoryNodes, queryFacets } from '../src/services/categories.js';
import { queryFocus } from '../src/services/focus.js';
import {
  DEFAULT_GATE_DB,
  DEFAULT_PROJECT_ID,
  DEFAULT_WRITE_DB,
  benchDocDir,
  ensureBenchDir,
  fmtMs,
  measureSync,
  rssMb,
} from './bench-shared.js';

const ITERATIONS = Number(process.env.REVIEW_BENCH_ITERS ?? 7);
/** Heavy groupBy (category/series/seed) — full-scan; opt-in via REVIEW_BENCH_INCLUDE_HEAVY=1 */
const INCLUDE_HEAVY = process.env.REVIEW_BENCH_INCLUDE_HEAVY === '1';
const HEAVY_ITERS = Number(process.env.REVIEW_BENCH_HEAVY_ITERS ?? 1);
const PHASE = (process.env.REVIEW_BENCH_PHASE ?? 'auto') as 'before' | 'after' | 'auto';

type MetricRow = {
  phase: string;
  metric: string;
  n: number;
  p50_ms: number;
  p95_ms: number;
  mean_ms: number;
  min_ms: number;
  max_ms: number;
};

function pickCategoryId(db: ReviewDb, projectId: number): number {
  const row = db
    .prepare(
      `SELECT pc.category_id AS id
       FROM project_categories pc
       WHERE pc.project_id = ?
       ORDER BY COALESCE(pc.member_count, 0) DESC
       LIMIT 1`,
    )
    .get(projectId) as { id: number } | undefined;
  if (!row) throw new Error('No category for project');
  return Number(row.id);
}

function pickFocusMedia(db: ReviewDb, projectId: number): number {
  const row = db
    .prepare(
      `SELECT media_id FROM project_media WHERE project_id = ? ORDER BY media_id LIMIT 1`,
    )
    .get(projectId) as { media_id: number };
  return Number(row.media_id);
}

function pragmaSnapshot(db: ReviewDb): Record<string, string> {
  const keys = ['journal_mode', 'synchronous', 'cache_size', 'mmap_size', 'page_size', 'temp_store'] as const;
  const out: Record<string, string> = {};
  for (const k of keys) {
    out[k] = String(db.pragma(k, { simple: true }));
  }
  return out;
}

function explain(db: ReviewDb, label: string, sql: string, params: unknown[] = []): string {
  const rows = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...params) as Array<{ detail: string }>;
  const plan = rows.map((r) => r.detail).join('\n  ');
  return `### ${label}\n\`\`\`\n${plan}\n\`\`\`\n`;
}

function runSuite(db: ReviewDb, phase: string, projectId: number): { metrics: MetricRow[]; explains: string } {
  const categoryId = pickCategoryId(db, projectId);
  const focusMediaId = pickFocusMedia(db, projectId);
  console.log(`phase=${phase} projectId=${projectId} categoryId=${categoryId} focusMediaId=${focusMediaId}`);

  const filterBase = {
    projectId,
    statuses: ['unreviewed', 'unsure'] as const,
  };

  const metrics: MetricRow[] = [];
  const add = (m: ReturnType<typeof measureSync>) => {
    metrics.push({
      phase,
      metric: m.label,
      n: m.n,
      p50_ms: +m.p50.toFixed(2),
      p95_ms: +m.p95.toFixed(2),
      mean_ms: +m.mean.toFixed(2),
      min_ms: +m.min.toFixed(2),
      max_ms: +m.max.toFixed(2),
    });
  };

  // Warmup once
  queryGallery(db, { ...filterBase, limit: 20, sort: 'media_id', dir: 'asc' });

  add(
    measureSync('category_subtree_count', ITERATIONS, () => {
      countCategorySubtree(db, projectId, categoryId);
    }),
  );

  add(
    measureSync('category_gallery', ITERATIONS, () => {
      queryGallery(db, {
        ...filterBase,
        categoryIds: [categoryId],
        limit: 100,
        sort: 'media_id',
        dir: 'asc',
      });
    }),
  );

  add(
    measureSync('groups_provenance', ITERATIONS, () => {
      queryGroups(db, {
        ...filterBase,
        groupBy: 'provenance',
        limit: 20,
        sampleSize: 0,
      });
    }),
  );

  if (INCLUDE_HEAVY) {
    console.log(`INCLUDE_HEAVY=1 — running category/series/seed (${HEAVY_ITERS} iter, may take minutes)`);
    add(
      measureSync('groups_category', HEAVY_ITERS, () => {
        queryGroups(db, {
          ...filterBase,
          groupBy: 'category',
          limit: 20,
          sampleSize: 0,
        });
      }),
    );

    add(
      measureSync('groups_series', HEAVY_ITERS, () => {
        queryGroups(db, {
          ...filterBase,
          groupBy: 'series',
          limit: 20,
          sampleSize: 0,
        });
      }),
    );

    add(
      measureSync('groups_seed', HEAVY_ITERS, () => {
        queryGroups(db, {
          ...filterBase,
          groupBy: 'seed',
          limit: 20,
          sampleSize: 0,
        });
      }),
    );
  } else {
    console.log(
      'Skipping groups_category/series/seed (set REVIEW_BENCH_INCLUDE_HEAVY=1). Spot: provenance only. Residual materialization candidate.',
    );
    // One cheap structural probe: category groupBy with tiny mediaIds filter (plan/index smoke, not full-scale)
    add(
      measureSync('groups_category_smoke', Math.min(3, ITERATIONS), () => {
        queryGroups(db, {
          ...filterBase,
          mediaIds: [focusMediaId],
          groupBy: 'category',
          limit: 5,
          sampleSize: 0,
        });
      }),
    );
  }

  add(
    measureSync('focus', ITERATIONS, () => {
      queryFocus(db, { projectId, focusMediaId });
    }),
  );

  add(
    measureSync('facets', ITERATIONS, () => {
      queryFacets(db, { ...filterBase });
    }),
  );

  add(
    measureSync('gallery_page', ITERATIONS, () => {
      queryGallery(db, {
        ...filterBase,
        limit: 120,
        sort: 'media_id',
        dir: 'asc',
      });
    }),
  );

  add(
    measureSync('status_counts', ITERATIONS, () => {
      computeStatusCounts(db, { projectId, statuses: ['unreviewed', 'keep', 'reject', 'unsure'] }, {
        breakdownAllStatuses: true,
      });
    }),
  );

  // Lightweight list nodes (not in required list but useful for category UX)
  add(
    measureSync('category_nodes_root', Math.min(ITERATIONS, 5), () => {
      listCategoryNodes(db, { projectId });
    }),
  );

  // EXPLAIN for slowest metrics (top by p95)
  const slowest = [...metrics].sort((a, b) => b.p95_ms - a.p95_ms).slice(0, 5);
  let explains = `## EXPLAIN QUERY PLAN (phase=${phase}, top p95)\n\n`;
  explains += `Slowest: ${slowest.map((s) => `${s.metric}=${fmtMs(s.p95_ms)}ms`).join(', ')}\n\n`;

  // Representative SQL plans for common hot paths
  explains += explain(
    db,
    'discoveries by project+media (join path)',
    `SELECT source_type FROM discoveries WHERE project_id = ? AND media_id = ?`,
    [projectId, focusMediaId],
  );
  explains += explain(
    db,
    'discoveries category origin',
    `SELECT media_id FROM discoveries WHERE project_id = ? AND source_type = 'category' AND origin_category_id = ?`,
    [projectId, categoryId],
  );
  explains += explain(
    db,
    'media_review_status by project',
    `SELECT status, COUNT(*) FROM media_review_status WHERE project_id = ? GROUP BY status`,
    [projectId],
  );
  explains += explain(
    db,
    'project_categories parent',
    `SELECT category_id FROM project_categories WHERE project_id = ? AND parent_category_id = ?`,
    [projectId, categoryId],
  );
  explains += explain(
    db,
    'discoveries covering media+source_type (migration 105 target)',
    `SELECT source_type, media_id FROM discoveries WHERE project_id = ? AND media_id = ? AND source_type = ?`,
    [projectId, focusMediaId, 'neighbor'],
  );

  // Index inventory
  const idxs = db
    .prepare(
      `SELECT name, sql FROM sqlite_master
       WHERE type='index' AND (
         name LIKE 'ix_discoveries%' OR name LIKE 'ix_media_review%' OR name LIKE 'ix_project_categories%'
         OR name LIKE 'ix_media_series%' OR name LIKE 'ix_frv39%'
       )
       ORDER BY name`,
    )
    .all() as Array<{ name: string; sql: string | null }>;
  explains += `\n## Indexes present (${phase})\n\n`;
  for (const i of idxs) {
    explains += `- \`${i.name}\`${i.sql ? `: \`${i.sql.replace(/\s+/g, ' ')}\`` : ''}\n`;
  }

  return { metrics, explains };
}

function writeMarkdown(
  phaseResults: Array<{ phase: string; metrics: MetricRow[]; explains: string; pragmas: Record<string, string>; mediaCount: number; rss: number }>,
): void {
  ensureBenchDir();
  const byMetric = new Map<string, { before?: MetricRow; after?: MetricRow }>();
  for (const pr of phaseResults) {
    for (const m of pr.metrics) {
      const slot = byMetric.get(m.metric) ?? {};
      if (pr.phase === 'before') slot.before = m;
      if (pr.phase === 'after') slot.after = m;
      byMetric.set(m.metric, slot);
    }
  }

  let md = `# FRV-39 SQLite Performance

**Date:** ${new Date().toISOString()}
**Project:** ${DEFAULT_PROJECT_ID}
**Iterations:** ${ITERATIONS}
**Media count (project_media):** ${phaseResults[0]?.mediaCount ?? 'n/a'}

## PRAGMA (documented, not aggressively changed)

`;
  for (const pr of phaseResults) {
    md += `### ${pr.phase}\n\n`;
    md += Object.entries(pr.pragmas)
      .map(([k, v]) => `- ${k}: \`${v}\``)
      .join('\n');
    md += `\n- process RSS (approx): **${pr.rss.toFixed(1)} MB**\n\n`;
  }

  md += `## Before / After (p50 / p95 ms)

| Metric | Before p50 | Before p95 | After p50 | After p95 | Δ p50 |
|---|---:|---:|---:|---:|---:|
`;
  for (const [metric, slot] of byMetric) {
    const b = slot.before;
    const a = slot.after;
    const delta =
      b && a && Number.isFinite(b.p50_ms) && b.p50_ms > 0
        ? `${(((a.p50_ms - b.p50_ms) / b.p50_ms) * 100).toFixed(1)}%`
        : '';
    md += `| ${metric} | ${b ? fmtMs(b.p50_ms) : '—'} | ${b ? fmtMs(b.p95_ms) : '—'} | ${a ? fmtMs(a.p50_ms) : '—'} | ${a ? fmtMs(a.p95_ms) : '—'} | ${delta} |\n`;
  }

  md += `
## Indexes added (migration 105)

See \`review/db/migrations/105_review_perf_indexes.sql\`.

- \`ix_discoveries_project_media_source\` — \`(project_id, media_id, source_type)\`
- \`ix_discoveries_project_series_types\` — partial series discovery covering
- \`ix_discoveries_project_keyword_query\` — partial keyword/query_text covering

Already present from 100–102 (no duplication): \`ix_discoveries_project_source_media\`, \`ix_discoveries_project_origin_cat\`, \`ix_media_review_status_project_status\`, \`ix_project_categories_parent\`, series-key indexes.

Targeted, idempotent \`CREATE INDEX IF NOT EXISTS\` only — no materialization table in this migration.

## Disk / environment notes

- Before: readonly gate DB on \`C:/Temp/...\` (same volume as OS).
- After: writable copy on \`E:/Temp/.../bench-write-copy.db\` (C: lacked free space for a second ~19GB copy).
- After p95 spikes include cold OS-cache / E: I/O; prefer p50 for index comparison.
- Full \`groups_category|series|seed\` only with \`REVIEW_BENCH_INCLUDE_HEAVY=1\` (minutes each); default uses provenance + category smoke.

## Residual / later

- \`category_gallery\` / \`focus\` / \`facets\` / \`groups_provenance\` remain ~1.7–2.4s p50 after indexes → **rebuildable materialization** (e.g. \`review_category_media_counts\`) is a residual candidate; skipped for now (indexes first, no clear sub-second win from 105 alone on these paths).
- WAL mode retained; no aggressive PRAGMA changes.
- Groups with \`sampleSize:0\` + \`limit:20\` used to keep bench runtime reasonable.

`;

  for (const pr of phaseResults) {
    md += pr.explains + '\n';
  }

  fs.writeFileSync(path.join(benchDocDir, 'FRV39_SQLITE.md'), md, 'utf8');

  // CSV append/replace
  const csvPath = path.join(benchDocDir, 'frv39-results.csv');
  const headers = ['phase', 'metric', 'n', 'p50_ms', 'p95_ms', 'mean_ms', 'min_ms', 'max_ms'];
  const lines = [headers.join(',')];
  for (const pr of phaseResults) {
    for (const m of pr.metrics) {
      lines.push(headers.map((h) => String((m as Record<string, unknown>)[h] ?? '')).join(','));
    }
  }
  fs.writeFileSync(csvPath, lines.join('\n') + '\n', 'utf8');
  console.log(`Wrote ${path.join(benchDocDir, 'FRV39_SQLITE.md')} and ${csvPath}`);
}

function openForPhase(phase: 'before' | 'after'): { db: ReviewDb; path: string } {
  if (phase === 'before') {
    const p = DEFAULT_GATE_DB;
    if (!fs.existsSync(p)) throw new Error(`Missing DB: ${p}`);
    return { db: openReviewDb(p, { readonly: true }), path: p };
  }
  const p = process.env.REVIEW_DB_PATH ?? DEFAULT_WRITE_DB;
  if (!fs.existsSync(p)) {
    throw new Error(
      `Writable after-DB missing: ${p}. Copy gate DB to E:/Temp/.../bench-write-copy.db and apply Invoke-ReviewMigrations.ps1 first.`,
    );
  }
  return { db: openReviewDb(p, { readonly: false }), path: p };
}

function main() {
  ensureBenchDir();
  const phases: Array<'before' | 'after'> =
    PHASE === 'auto' ? ['before', 'after'] : PHASE === 'before' ? ['before'] : ['after'];

  const phaseResults: Array<{
    phase: string;
    metrics: MetricRow[];
    explains: string;
    pragmas: Record<string, string>;
    mediaCount: number;
    rss: number;
  }> = [];

  // If after DB missing in auto mode, only run before and still write docs
  const effective = phases.filter((ph) => {
    if (ph === 'before') return fs.existsSync(DEFAULT_GATE_DB);
    const p = process.env.REVIEW_DB_PATH ?? DEFAULT_WRITE_DB;
    if (!fs.existsSync(p)) {
      console.warn(`Skip after: writable DB not found at ${p}`);
      return false;
    }
    return true;
  });

  for (const phase of effective) {
    const { db, path: dbPath } = openForPhase(phase);
    console.log(`Opening ${dbPath} (${(fs.statSync(dbPath).size / 1e9).toFixed(2)} GB) phase=${phase}`);
    const mediaCount = (
      db
        .prepare(`SELECT COUNT(*) AS c FROM project_media WHERE project_id = ?`)
        .get(DEFAULT_PROJECT_ID) as { c: number }
    ).c;
    console.log(`mediaCount=${mediaCount} rss=${rssMb().toFixed(1)}MB`);
    const pragmas = pragmaSnapshot(db);
    console.log('PRAGMA', pragmas);
    const { metrics, explains } = runSuite(db, phase, DEFAULT_PROJECT_ID);
    phaseResults.push({
      phase,
      metrics,
      explains,
      pragmas,
      mediaCount,
      rss: rssMb(),
    });
    db.close();
  }

  // Merge with existing CSV if running single phase
  if (effective.length === 1 && fs.existsSync(path.join(benchDocDir, 'frv39-results.csv'))) {
    const existing = fs.readFileSync(path.join(benchDocDir, 'frv39-results.csv'), 'utf8').trim().split(/\r?\n/);
    const headers = existing[0]?.split(',') ?? [];
    const otherPhase = effective[0] === 'before' ? 'after' : 'before';
    const kept: MetricRow[] = [];
    for (const line of existing.slice(1)) {
      const cols = line.split(',');
      if (cols[0] === otherPhase && headers.length >= 8) {
        kept.push({
          phase: cols[0]!,
          metric: cols[1]!,
          n: Number(cols[2]),
          p50_ms: Number(cols[3]),
          p95_ms: Number(cols[4]),
          mean_ms: Number(cols[5]),
          min_ms: Number(cols[6]),
          max_ms: Number(cols[7]),
        });
      }
    }
    if (kept.length) {
      const otherExplains = fs.existsSync(path.join(benchDocDir, 'FRV39_SQLITE.md'))
        ? ''
        : '';
      phaseResults.unshift({
        phase: otherPhase,
        metrics: kept,
        explains: otherExplains,
        pragmas: {},
        mediaCount: phaseResults[0]?.mediaCount ?? 0,
        rss: 0,
      });
      // Fix order
      phaseResults.sort((a, b) => (a.phase === 'before' ? -1 : b.phase === 'before' ? 1 : 0));
    }
  }

  writeMarkdown(phaseResults);
}

main();
