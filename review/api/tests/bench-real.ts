/**
 * Real-DB benchmarks. Default for *this* script is the full gate copy via REVIEW_PERF_DB_PATH.
 * Day-to-day API default is review-dev-mini.db (see src/index.ts).
 */
import fs from 'node:fs';
import path from 'node:path';
import { openReviewDb } from '../src/db.js';
import { queryGallery } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { listCategoryNodes, countCategorySubtree } from '../src/services/categories.js';
import { queryFocus } from '../src/services/focus.js';
import { applyBulk, undoBatch } from '../src/services/bulk.js';

const dbPath =
  process.env.REVIEW_PERF_DB_PATH ??
  process.env.REVIEW_DB_PATH ??
  'C:/Temp/FindSeries-Review-Test/review-dev-mini.db';

function timed<T>(label: string, fn: () => T): T {
  const t0 = performance.now();
  const out = fn();
  const ms = performance.now() - t0;
  console.log(`${label}: ${ms.toFixed(1)} ms`);
  return out;
}

function main() {
  if (!fs.existsSync(dbPath)) {
    console.error(`DB missing: ${dbPath}`);
    process.exit(2);
  }
  console.log(`Opening ${dbPath} (${(fs.statSync(dbPath).size / 1e9).toFixed(2)} GB)`);
  const db = openReviewDb(dbPath); // writable for small bulk bench; never production path

  const projectId = Number(process.env.REVIEW_BENCH_PROJECT_ID ?? 7);
  console.log(`projectId=${projectId}`);

  // Warmup
  timed('warmup gallery limit 50', () =>
    queryGallery(db, {
      projectId,
      statuses: ['unreviewed', 'unsure'],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    }),
  );

  const g1 = timed('gallery page1 limit 100', () =>
    queryGallery(db, {
      projectId,
      statuses: ['unreviewed', 'unsure'],
      limit: 100,
      sort: 'media_id',
      dir: 'asc',
    }),
  );
  timed('gallery page2 seek', () =>
    queryGallery(db, {
      projectId,
      statuses: ['unreviewed', 'unsure'],
      limit: 100,
      sort: 'media_id',
      dir: 'asc',
      cursor: g1.nextCursor,
    }),
  );

  const root = listCategoryNodes(db, { projectId })[0];
  if (root) {
    timed(`category subtree count cat=${root.categoryId}`, () =>
      countCategorySubtree(db, projectId, root.categoryId),
    );
    timed('gallery category filter limit 100', () =>
      queryGallery(db, {
        projectId,
        statuses: ['unreviewed', 'unsure'],
        categoryIds: [root.categoryId],
        limit: 100,
        sort: 'media_id',
        dir: 'asc',
      }),
    );
  }

  timed('groups provenance limit 20', () =>
    queryGroups(db, {
      projectId,
      statuses: ['unreviewed', 'unsure'],
      groupBy: 'provenance',
      limit: 20,
      sampleSize: 0,
    }),
  );

  const sampleMedia = (
    db
      .prepare(`SELECT media_id FROM project_media WHERE project_id=? ORDER BY media_id LIMIT 1`)
      .get(projectId) as { media_id: number }
  ).media_id;
  timed(`focus media=${sampleMedia}`, () =>
    queryFocus(db, { projectId, focusMediaId: sampleMedia }),
  );

  // Small write bench on copy only
  const ids = (
    db
      .prepare(
        `SELECT media_id FROM project_media WHERE project_id=? ORDER BY media_id LIMIT 100`,
      )
      .all(projectId) as Array<{ media_id: number }>
  ).map((r) => r.media_id);

  const bulk = timed('bulk set reject n=100 protectKeep', () =>
    applyBulk(db, {
      projectId,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: ids,
      protectKeep: true,
      source: 'bench',
      sessionId: 'bench-session',
    }),
  );
  timed('undo bulk batch', () => undoBatch(db, { projectId, batchId: bulk.batchId }));

  // 10k sample if available
  const ids10k = (
    db
      .prepare(
        `SELECT media_id FROM project_media WHERE project_id=? ORDER BY media_id LIMIT 10000`,
      )
      .all(projectId) as Array<{ media_id: number }>
  ).map((r) => r.media_id);
  if (ids10k.length >= 1000) {
    const b = timed(`bulk set unsure n=${ids10k.length}`, () =>
      applyBulk(db, {
        projectId,
        action: 'set_status',
        targetStatus: 'unsure',
        mediaIds: ids10k,
        protectKeep: true,
        source: 'bench',
      }),
    );
    timed('undo 10k batch', () => undoBatch(db, { projectId, batchId: b.batchId }));
  }

  console.log('bench done');
  db.close();
}

main();
