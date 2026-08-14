import assert from 'node:assert/strict';
import { describe, it, before, after } from 'node:test';
import { queryGallery, computeStatusCounts } from '../src/services/gallery.js';
import { listProjects } from '../src/services/projects.js';
import { createSyntheticReviewDb } from './helpers.js';

describe('Phase-3 cleanup: inventory/result + AND drilldown + projects', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let cleanup: () => void;

  before(() => {
    const ctx = createSyntheticReviewDb();
    db = ctx.db;
    cleanup = ctx.cleanup;
    db.exec(`
      INSERT OR IGNORE INTO discoveries(
        project_id, media_id, source_type, source_value, score, query_text,
        origin_category_id, parent_media_id, created_at
      ) VALUES
        (7, 1, 'category', 'Category:Instruments', 50, NULL, 103, NULL, '2026-08-14T12:00:00.000Z');
      INSERT OR IGNORE INTO media_review_status(
        project_id, media_id, status, changed_at, source, action, batch_id
      ) VALUES
        (7, 10, 'keep', '2026-08-14T12:00:00.000Z', 'test', 'set_status', 't'),
        (7, 11, 'reject', '2026-08-14T12:00:00.000Z', 'test', 'set_status', 't'),
        (7, 12, 'unsure', '2026-08-14T12:00:00.000Z', 'test', 'set_status', 't');
    `);
  });

  after(() => cleanup());

  it('inventory counts are project-wide all statuses', () => {
    const inv = computeStatusCounts(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
    });
    assert.ok(inv.total > 0);
    assert.equal(inv.keep + inv.reject + inv.unsure + inv.unreviewed, inv.total);
    assert.ok(inv.keep >= 1);
  });

  it('gallery result statusCounts sum equals total (default statuses)', () => {
    const res = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure'],
      limit: 10,
      sort: 'media_id',
      dir: 'asc',
    });
    const sum =
      res.statusCounts.unreviewed +
      res.statusCounts.keep +
      res.statusCounts.reject +
      res.statusCounts.unsure;
    assert.equal(sum, res.total);
    assert.equal(res.statusCounts.total, res.total);
    assert.equal(res.statusCounts.keep, 0);
    assert.equal(res.statusCounts.reject, 0);
  });

  it('all four statuses active: sum == total', () => {
    const res = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      limit: 5,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(res.statusCounts.total, res.total);
  });

  it('search narrows result; inventory unaffected', () => {
    const inv = computeStatusCounts(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
    });
    const res = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
      q: 'Dental_chair',
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(res.total < inv.total);
    assert.equal(res.statusCounts.total, res.total);
  });

  it('statuses [] empty result', () => {
    const res = queryGallery(db, {
      projectId: 7,
      statuses: [],
      limit: 10,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(res.total, 0);
    assert.equal(res.statusCounts.total, 0);
  });

  it('global category + category drilldown AND (not replace)', () => {
    const globalOnly = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      categoryIds: [101],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    const replaced = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      categoryIds: [103],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    const anded = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      categoryIds: [101],
      alsoCategoryIds: [103],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(anded.total <= globalOnly.total);
    assert.ok(anded.total <= replaced.total);
    assert.ok(anded.total >= 1);
    assert.ok(anded.total < replaced.total);
  });

  it('sourceType AND drilldown', () => {
    const anded = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      sourceTypes: ['category'],
      alsoSourceTypes: ['neighbor'],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    for (const it of anded.items) {
      const rows = db
        .prepare(
          `SELECT DISTINCT source_type FROM discoveries WHERE project_id=7 AND media_id=?`,
        )
        .all(it.mediaId) as Array<{ source_type: string }>;
      const types = new Set(rows.map((r) => r.source_type));
      assert.equal(types.has('category'), true);
      assert.equal(types.has('neighbor'), true);
    }
  });

  it('listProjects returns id/name/slug', () => {
    const res = listProjects(db);
    assert.ok(res.projects.length >= 2);
    const p = res.projects.find((x) => x.id === 7);
    assert.ok(p?.name);
    assert.equal(p?.slug, 'cat-dentistry');
  });
});
