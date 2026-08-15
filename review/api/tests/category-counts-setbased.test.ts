import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  batchCountMediaForCategoryNodes,
  countCategorySubtree,
  listCategoryNodes,
} from '../src/services/categories.js';
import { buildFilteredMediaCte } from '../src/sql/filters.js';
import { createSyntheticReviewDb } from './helpers.js';

describe('category node counts — set-based (no N+1)', () => {
  it('matches per-node subtree totals for children under parent 100', () => {
    const { db, cleanup } = createSyntheticReviewDb();
    try {
      const filter = {
        projectId: 7 as const,
        statuses: ['unreviewed', 'unsure'] as const,
      };
      const children = listCategoryNodes(db, {
        projectId: 7,
        parentCategoryId: 100,
        filter: { statuses: [...filter.statuses], categoryIncludeDescendants: true },
      });
      assert.ok(children.length >= 1);
      for (const node of children) {
        const solo = buildFilteredMediaCte({
          ...filter,
          categoryIds: [node.categoryId],
          categoryIncludeDescendants: true,
        });
        const expected = (
          db.prepare(`WITH fm AS (${solo.sql}) SELECT COUNT(*) AS c FROM fm`).get(...solo.params) as {
            c: number;
          }
        ).c;
        assert.equal(
          node.mediaCount,
          expected,
          `cat ${node.categoryId}: mediaCount ${node.mediaCount} !== ${expected}`,
        );
      }
    } finally {
      cleanup();
    }
  });

  it('exact (no descendants) matches categoryMediaSql membership under filter', () => {
    const { db, cleanup } = createSyntheticReviewDb();
    try {
      const nodes = listCategoryNodes(db, {
        projectId: 7,
        parentCategoryId: 100,
        filter: { statuses: ['unreviewed', 'unsure'], categoryIncludeDescendants: false },
      });
      for (const node of nodes) {
        const solo = buildFilteredMediaCte({
          projectId: 7,
          statuses: ['unreviewed', 'unsure'],
          categoryIds: [node.categoryId],
          categoryIncludeDescendants: false,
        });
        const expected = (
          db.prepare(`WITH fm AS (${solo.sql}) SELECT COUNT(*) AS c FROM fm`).get(...solo.params) as {
            c: number;
          }
        ).c;
        assert.equal(node.mediaCount, expected);
      }
    } finally {
      cleanup();
    }
  });

  it('>500 category nodes: one batch query path, not N+1, completes quickly', () => {
    const { db, cleanup } = createSyntheticReviewDb();
    try {
      const now = '2026-08-15T12:00:00.000Z';
      const N = 520;
      const insertCat = db.prepare(
        `INSERT OR IGNORE INTO categories(id, title, normalized_title, created_at) VALUES (?,?,?,?)`,
      );
      const insertPc = db.prepare(
        `INSERT OR IGNORE INTO project_categories(
          project_id, category_id, parent_category_id, depth, status, member_count, file_count, child_count, discovered_at, updated_at
        ) VALUES (7, ?, NULL, 0, 'done', 0, 0, 0, ?, ?)`,
      );
      const insertDisc = db.prepare(
        `INSERT OR IGNORE INTO discoveries(project_id, media_id, source_type, source_value, score, origin_category_id, created_at)
         VALUES (7, 1, 'category', ?, 10, ?, ?)`,
      );
      const tx = db.transaction(() => {
        for (let i = 0; i < N; i++) {
          const id = 900000 + i;
          insertCat.run(id, `Bulk Cat ${i}`, `bulk cat ${i}`, now);
          insertPc.run(id, now, now);
          if (i % 10 === 0) insertDisc.run(`Bulk Cat ${i}`, id, now);
        }
      });
      tx();

      let prepareCount = 0;
      const origPrepare = db.prepare.bind(db);
      (db as { prepare: typeof db.prepare }).prepare = ((sql: string) => {
        const s = String(sql);
        if (s.includes('COUNT(DISTINCT fm.media_id)') || s.includes('COUNT(DISTINCT fm.media_id) AS c')) {
          prepareCount += 1;
        }
        // Also count the batch query shape
        if (s.includes('root_of AS') || s.includes('WITH fm AS')) {
          if (s.includes('COUNT(DISTINCT')) prepareCount += 0; // already counted
        }
        return origPrepare(sql);
      }) as typeof db.prepare;

      const t0 = Date.now();
      const roots = listCategoryNodes(db, {
        projectId: 7,
        filter: { statuses: ['unreviewed', 'unsure'], categoryIncludeDescendants: true },
      });
      const ms = Date.now() - t0;
      (db as { prepare: typeof db.prepare }).prepare = origPrepare;

      assert.ok(roots.length >= N, `expected >=${N} roots, got ${roots.length}`);
      assert.ok(ms < 5000, `listCategoryNodes with ${roots.length} roots took ${ms}ms (budget 5s)`);
      // N+1 would prepare once per node; set-based prepares a small constant number.
      assert.ok(
        prepareCount <= 5,
        `expected <=5 count prepares, got ${prepareCount} (N+1 would be ~${roots.length})`,
      );

      // Spot-check: a seeded bulk root should have mediaCount >= 1
      const seeded = roots.find((r) => r.categoryId === 900000);
      assert.ok(seeded);
      assert.ok((seeded!.mediaCount ?? 0) >= 1);
    } finally {
      cleanup();
    }
  });

  it('batchCountMediaForCategoryNodes agrees with countCategorySubtree on synthetic parent children', () => {
    const { db, cleanup } = createSyntheticReviewDb();
    try {
      const children = listCategoryNodes(db, { projectId: 7, parentCategoryId: 100 });
      const ids = children.map((c) => c.categoryId);
      const batch = batchCountMediaForCategoryNodes(
        db,
        7,
        ids,
        { projectId: 7, statuses: ['unreviewed', 'keep', 'reject', 'unsure'] },
        { includeDescendants: true, parentCategoryId: 100 },
      );
      for (const id of ids) {
        // countCategorySubtree is unfiltered membership; with all statuses + no other filters
        // gallery filter still requires project_media — should align for fixture media.
        const subtree = countCategorySubtree(db, 7, id);
        const filtered = buildFilteredMediaCte({
          projectId: 7,
          statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
          categoryIds: [id],
          categoryIncludeDescendants: true,
        });
        const expected = (
          db
            .prepare(`WITH fm AS (${filtered.sql}) SELECT COUNT(*) AS c FROM fm`)
            .get(...filtered.params) as { c: number }
        ).c;
        assert.equal(batch.get(id), expected);
        assert.ok(subtree >= expected);
      }
    } finally {
      cleanup();
    }
  });
});
