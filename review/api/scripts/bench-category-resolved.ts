/**
 * Lightweight probe: origin-only vs full-resolved category key aggregation.
 * Logs progress; writes FRV39_CATEGORY_RESOLVED.md
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openReviewDb } from '../src/db.js';
import { buildFilteredMediaCte, resolvedCategoryMembershipSql } from '../src/sql/filters.js';
import { queryGroups } from '../src/services/groups.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../..');
const dbPath =
  process.env.REVIEW_DB_PATH ?? 'C:/Temp/FindSeries-Review-Test/review-dev-mini.db';
const projectId = Number(process.env.REVIEW_BENCH_PROJECT_ID ?? 7);
const limit = Number(process.env.REVIEW_BENCH_LIMIT ?? 20);

console.log(`DB=${dbPath}`);
console.log(`projectId=${projectId} limit=${limit}`);

const db = openReviewDb(dbPath);

function timed<T>(label: string, fn: () => T): { ms: number; result: T } {
  const t0 = performance.now();
  const result = fn();
  const ms = performance.now() - t0;
  console.log(`${label}: ${ms.toFixed(0)}ms`);
  return { ms, result };
}

const counts = timed('discovery counts', () => {
  const row = db
    .prepare(
      `SELECT
         SUM(CASE WHEN source_type='category' THEN 1 ELSE 0 END) AS cat_all,
         SUM(CASE WHEN source_type='category' AND origin_category_id IS NOT NULL THEN 1 ELSE 0 END) AS cat_origin,
         SUM(CASE WHEN source_type='category' AND origin_category_id IS NULL THEN 1 ELSE 0 END) AS cat_null_origin
       FROM discoveries WHERE project_id = ?`,
    )
    .get(projectId) as { cat_all: number; cat_origin: number; cat_null_origin: number };
  return row;
});
console.log(JSON.stringify(counts.result));

const filter = {
  projectId,
  statuses: ['unreviewed', 'keep', 'reject', 'unsure'] as const,
};
const uiBase = buildFilteredMediaCte({ ...filter }, 'count');

const origin = timed('origin-only keys', () => {
  const selectKey = `CAST(d.origin_category_id AS TEXT)`;
  const join = `
JOIN discoveries d
  ON d.project_id = ? AND d.media_id = fm.media_id
 AND d.source_type = 'category'
 AND d.origin_category_id IS NOT NULL`;
  return db
    .prepare(
      `WITH fm AS (${uiBase.sql})
       SELECT ${selectKey} AS gkey, COUNT(DISTINCT fm.media_id) AS approx_total
       FROM fm
       ${join}
       WHERE ${selectKey} IS NOT NULL
       GROUP BY gkey
       ORDER BY approx_total DESC
       LIMIT ?`,
    )
    .all(...uiBase.params, projectId, limit) as Array<{ gkey: string; approx_total: number }>;
});

const resolved = resolvedCategoryMembershipSql(projectId);

const resolvedSize = timed('resolved membership COUNT', () => {
  return db
    .prepare(`SELECT COUNT(*) AS c FROM (${resolved.sql})`)
    .get(...resolved.params) as { c: number };
});
console.log(`resolved pairs=${resolvedSize.result.c}`);

const fallbackOnly = timed('fallback-only media count', () => {
  return db
    .prepare(
      `SELECT COUNT(DISTINCT r.media_id) AS c
       FROM (${resolved.sql}) r
       WHERE NOT EXISTS (
         SELECT 1 FROM discoveries d
         WHERE d.project_id = ? AND d.media_id = r.media_id
           AND d.source_type = 'category' AND d.origin_category_id IS NOT NULL
       )`,
    )
    .get(...resolved.params, projectId) as { c: number };
});

const fullKeys = timed('full-resolved keys (MATERIALIZED CTE)', () => {
  const selectKey = `CAST(rc.category_id AS TEXT)`;
  return db
    .prepare(
      `WITH resolved_category AS MATERIALIZED (${resolved.sql}),
            fm AS (${uiBase.sql})
       SELECT ${selectKey} AS gkey, COUNT(DISTINCT fm.media_id) AS approx_total
       FROM fm
       JOIN resolved_category rc ON rc.media_id = fm.media_id
       WHERE ${selectKey} IS NOT NULL
       GROUP BY gkey
       ORDER BY approx_total DESC
       LIMIT ?`,
    )
    .all(...resolved.params, ...uiBase.params, limit) as Array<{
    gkey: string;
    approx_total: number;
  }>;
});

const fullGroups = timed('queryGroups category sampleSize=0', () => {
  return queryGroups(db, {
    projectId,
    statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
    groupBy: 'category',
    limit,
    sampleSize: 0,
  });
});

const tooSlow = fullGroups.ms > 5000 || fullKeys.ms > 5000;
const originKeySet = new Set(origin.result.map((k) => String(k.gkey)));
const fullKeySet = new Set(fullKeys.result.map((g) => String(g.gkey)));
const onlyInFull = [...fullKeySet].filter((k) => !originKeySet.has(k));

const md = `# FRV-39 Category Resolved Membership

Comparison of **origin-only** vs **full-resolved** (\`resolvedCategoryMembershipSql\` + \`resolved_category AS MATERIALIZED\`) category grouping.

## Environment

- DB: \`${dbPath}\`
- projectId: ${projectId}
- limit: ${limit}
- sampleSize: 0 (for \`queryGroups\`)
- statuses: all 4
- measured: ${new Date().toISOString()}

## Discovery volume

| Metric | Count |
|--------|------:|
| category discoveries | ${counts.result.cat_all} |
| with origin_category_id | ${counts.result.cat_origin} |
| null origin (fallback candidates) | ${counts.result.cat_null_origin} |

## Results

| Mode | Keys | ms |
|------|------|---:|
| origin-only key aggregation | ${origin.result.length} | ${origin.ms.toFixed(0)} |
| resolved membership COUNT (pairs) | ${resolvedSize.result.c} | ${resolvedSize.ms.toFixed(0)} |
| full-resolved keys (MATERIALIZED CTE) | ${fullKeys.result.length} | ${fullKeys.ms.toFixed(0)} |
| queryGroups(category, sampleSize=0) | ${fullGroups.result.groups.length} | ${fullGroups.ms.toFixed(0)} |

- Media via **fallback-only** (no origin on any category discovery): **${fallbackOnly.result.c}** (${fallbackOnly.ms.toFixed(0)}ms to count)
- Keys present only in full-resolved top-${limit}: ${onlyInFull.length}${onlyInFull.length ? ` (\`${onlyInFull.slice(0, 10).join('`, `')}\`${onlyInFull.length > 10 ? ', …' : ''})` : ''}

## Materialization decision

${
  tooSlow
    ? `Full-resolved exceeded ~5s (keys ${fullKeys.ms.toFixed(0)}ms / queryGroups ${fullGroups.ms.toFixed(0)}ms). A persistent materialization migration would be warranted.`
    : `Full-resolved is **under** the ~5s threshold (keys **${fullKeys.ms.toFixed(0)}ms**, queryGroups **${fullGroups.ms.toFixed(0)}ms** for limit ${limit}). **No persistent materialization migration** — query-local \`resolved_category AS MATERIALIZED\` CTE is sufficient for MVP.

Note: a nested \`JOIN (origin UNION fallback)\` subquery (without MATERIALIZED CTE) was pathologically slow on this DB (multi-minute); the CTE form matches the intended set-based shape and stays interactive.`
}

## Notes

- Filters already use the same membership rules via \`categoryMediaSql\`.
- Grouping uses \`resolvedCategoryMembershipSql(projectId)\` as \`resolved_category AS MATERIALIZED (...)\` then \`JOIN resolved_category ON media_id = fm.media_id\`.
- Probe times a single pass (no warmup average) to keep wall-clock bounded on the ~20GB gate DB.
`;

const outDir = path.join(repoRoot, 'docs/review-mvp/bench');
fs.mkdirSync(outDir, { recursive: true });
const outPath = path.join(outDir, 'FRV39_CATEGORY_RESOLVED.md');
fs.writeFileSync(outPath, md, 'utf8');
console.log(md);
console.log(`Wrote ${outPath}`);
db.close();
