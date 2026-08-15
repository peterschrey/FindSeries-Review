import assert from 'node:assert/strict';
import { describe, it, before, after } from 'node:test';
import { queryGallery } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { queryFocus } from '../src/services/focus.js';
import { categoryMediaSql, resolvedCategoryMembershipSql } from '../src/sql/filters.js';
import { createSyntheticReviewDb } from './helpers.js';
import type { ReviewStatus } from '@findseries/review-shared';

const ALL: ReviewStatus[] = ['unreviewed', 'keep', 'reject', 'unsure'];

describe('P0 A: category grouping = CATEGORY_GRAPH semantics', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let cleanup: () => void;

  before(() => {
    const ctx = createSyntheticReviewDb();
    db = ctx.db;
    cleanup = ctx.cleanup;
    // No invented fallback: unmatched title, and category not in project_categories
    db.exec(`
      INSERT OR IGNORE INTO categories(id, title, normalized_title, created_at) VALUES
        (210, 'Orphan Global Cat', 'orphan global cat', '2026-08-14T12:00:00.000Z');
      -- 210 intentionally NOT in project_categories for project 7
      INSERT OR IGNORE INTO media(id, title, current_uploader, created_at, updated_at) VALUES
        (220, 'File:NoMatch.jpg', 'UploaderC', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (221, 'File:OrphanCat.jpg', 'UploaderC', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
      INSERT OR IGNORE INTO project_media(project_id, media_id, score, selected, download_requested, first_seen_at, updated_at)
      VALUES
        (7, 220, 5, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (7, 221, 5, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
      INSERT OR IGNORE INTO discoveries(
        project_id, media_id, source_type, source_value, score, query_text, origin_category_id, parent_media_id, created_at
      ) VALUES
        (7, 220, 'category', 'Totally Unknown Title', 10, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z'),
        (7, 221, 'category', 'Orphan Global Cat', 10, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z');
    `);
  });

  after(() => cleanup());

  it('origin-only keys present; fallback-only media 200 under cat 200', () => {
    const groups = queryGroups(db, {
      projectId: 7,
      statuses: [...ALL],
      groupBy: 'category',
      limit: 50,
      sampleSize: 4,
    });
    const chairs = groups.groups.find((g) => g.key === '101');
    assert.ok(chairs, 'origin category 101 present');
    assert.ok(chairs!.total >= 3);

    const fallback = groups.groups.find((g) => g.key === '200');
    assert.ok(fallback, 'fallback-only category 200 present');
    assert.ok(fallback!.sampleMedia.some((m) => m.mediaId === 200));
  });

  it('unmatched / non-project source_value is not invented as group membership', () => {
    const groups = queryGroups(db, {
      projectId: 7,
      statuses: [...ALL],
      groupBy: 'category',
      limit: 50,
      sampleSize: 4,
    });
    assert.equal(groups.groups.find((g) => g.key === '210'), undefined);
    for (const g of groups.groups) {
      assert.ok(!g.sampleMedia.some((m) => m.mediaId === 220 || m.mediaId === 221));
    }
    const resolved = resolvedCategoryMembershipSql(7);
    const invented = db
      .prepare(
        `SELECT media_id FROM (${resolved.sql}) WHERE media_id IN (220, 221)`,
      )
      .all(...resolved.params) as Array<{ media_id: number }>;
    assert.equal(invented.length, 0);
  });

  it('no double-count: origin+fallback same (media_id, category_id) once', () => {
    const resolved = resolvedCategoryMembershipSql(7);
    const rows = db
      .prepare(
        `SELECT media_id, category_id, COUNT(*) AS c FROM (${resolved.sql})
         GROUP BY media_id, category_id HAVING c > 1`,
      )
      .all(...resolved.params) as Array<{ media_id: number; category_id: number; c: number }>;
    assert.equal(rows.length, 0);
  });

  it('group total == drilldown gallery total; navigator membership aligns', () => {
    const groups = queryGroups(db, {
      projectId: 7,
      statuses: [...ALL],
      groupBy: 'category',
      limit: 50,
      sampleSize: 2,
    });
    for (const g of groups.groups) {
      const gallery = queryGallery(db, {
        ...g.drilldown,
        statuses: [...ALL],
        limit: 200,
        sort: 'media_id',
        dir: 'asc',
      });
      assert.equal(g.total, gallery.total, `key=${g.key}`);

      const catId = Number(g.key);
      const mem = categoryMediaSql(7, [catId], { includeDescendants: false });
      const memberIds = new Set(
        (
          db.prepare(`SELECT media_id FROM (${mem.sql})`).all(...mem.params) as Array<{
            media_id: number;
          }>
        ).map((r) => r.media_id),
      );
      for (const m of g.sampleMedia) {
        assert.ok(memberIds.has(m.mediaId), `sample ${m.mediaId} in cat ${g.key}`);
      }
    }
  });
});

describe('P0 B: GroupCard total == drilldown gallery (UI statuses)', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let cleanup: () => void;
  const CAT = 300;
  const MEDIA_START = 3000;

  before(() => {
    const ctx = createSyntheticReviewDb();
    db = ctx.db;
    cleanup = ctx.cleanup;
    // 20 unreviewed + 5 unsure + 70 keep + 5 reject under category 300
    db.exec(`
      INSERT OR IGNORE INTO categories(id, title, normalized_title, created_at)
      VALUES (${CAT}, 'Status Mix Cat', 'status mix cat', '2026-08-14T12:00:00.000Z');
      INSERT OR IGNORE INTO project_categories(
        project_id, category_id, parent_category_id, depth, status, member_count, file_count, child_count, discovered_at, updated_at
      ) VALUES (7, ${CAT}, NULL, 0, 'done', 100, 100, 0, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
    `);
    const insMedia = db.prepare(
      `INSERT OR IGNORE INTO media(id, title, current_uploader, created_at, updated_at)
       VALUES (?, ?, 'StatusMixUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z')`,
    );
    const insPm = db.prepare(
      `INSERT OR IGNORE INTO project_media(project_id, media_id, score, selected, download_requested, first_seen_at, updated_at)
       VALUES (7, ?, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z')`,
    );
    const insDisc = db.prepare(
      `INSERT OR IGNORE INTO discoveries(
         project_id, media_id, source_type, source_value, score, query_text, origin_category_id, parent_media_id, created_at
       ) VALUES (7, ?, 'category', 'Status Mix Cat', 10, NULL, ${CAT}, NULL, '2026-08-14T12:00:00.000Z')`,
    );
    const insStatus = db.prepare(
      `INSERT OR REPLACE INTO media_review_status(project_id, media_id, status, changed_at, source, action)
       VALUES (7, ?, ?, '2026-08-14T12:00:00.000Z', 'test', 'set_status')`,
    );

    const plan: Array<{ status: ReviewStatus; n: number }> = [
      { status: 'unreviewed', n: 20 },
      { status: 'unsure', n: 5 },
      { status: 'keep', n: 70 },
      { status: 'reject', n: 5 },
    ];
    let id = MEDIA_START;
    for (const { status, n } of plan) {
      for (let i = 0; i < n; i++) {
        insMedia.run(id, `StatusMix:${status}:${i}`);
        insPm.run(id);
        insDisc.run(id);
        if (status !== 'unreviewed') {
          insStatus.run(id, status);
        }
        id++;
      }
    }
  });

  after(() => cleanup());

  function group300(statuses?: ReviewStatus[]) {
    return queryGroups(db, {
      projectId: 7,
      statuses,
      groupBy: 'category',
      limit: 50,
      sampleSize: 8,
    }).groups.find((g) => g.key === String(CAT));
  }

  it('default unreviewed+unsure → total 25; progress has all 4', () => {
    const g = group300(undefined);
    assert.ok(g);
    assert.equal(g!.total, 25);
    assert.equal(g!.statusCounts.total, 25);
    assert.equal(g!.statusCounts.unreviewed, 20);
    assert.equal(g!.statusCounts.unsure, 5);
    assert.equal(g!.statusCounts.keep, 0);
    assert.equal(g!.statusCounts.reject, 0);
    assert.ok(g!.progressStatusCounts);
    assert.equal(g!.progressStatusCounts!.total, 100);
    assert.equal(g!.progressStatusCounts!.keep, 70);
    assert.equal(g!.progressStatusCounts!.reject, 5);

    const gallery = queryGallery(db, {
      projectId: 7,
      categoryIds: [CAT],
      categoryIncludeDescendants: false,
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(g!.total, gallery.total);
    for (const s of g!.sampleMedia) {
      assert.ok(['unreviewed', 'unsure'].includes(s.reviewStatus));
    }
  });

  it('only unreviewed → total 20', () => {
    const g = group300(['unreviewed']);
    assert.ok(g);
    assert.equal(g!.total, 20);
    assert.equal(g!.statusCounts.unreviewed, 20);
    assert.equal(g!.statusCounts.total, 20);
    assert.ok(g!.progressStatusCounts);
    assert.equal(g!.progressStatusCounts!.total, 100);
  });

  it('keep included → total 90 (20u+70k)', () => {
    const g = group300(['unreviewed', 'keep']);
    assert.ok(g);
    assert.equal(g!.total, 90);
    assert.equal(g!.statusCounts.keep, 70);
    assert.equal(g!.statusCounts.unreviewed, 20);
    const gallery = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep'],
      categoryIds: [CAT],
      limit: 100,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(g!.total, gallery.total);
  });

  it('all statuses → total 100; no progressStatusCounts needed', () => {
    const g = group300([...ALL]);
    assert.ok(g);
    assert.equal(g!.total, 100);
    assert.equal(g!.statusCounts.total, 100);
    assert.equal(g!.progressStatusCounts, undefined);
  });

  it('samples belong to drilldown set (UI status filter)', () => {
    const g = group300(['keep']);
    assert.ok(g);
    assert.ok(g!.sampleMedia.length > 0);
    for (const s of g!.sampleMedia) {
      assert.equal(s.reviewStatus, 'keep');
    }
  });
});

describe('P0 C: focus uploader global filter AND/conflict', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let cleanup: () => void;

  before(() => {
    const ctx = createSyntheticReviewDb();
    db = ctx.db;
    cleanup = ctx.cleanup;
  });

  after(() => cleanup());

  function uploaderRel(focusMediaId: number, baseUploader?: string | null) {
    const res = queryFocus(db, {
      projectId: 7,
      focusMediaId,
      baseFilter:
        baseUploader === undefined
          ? { statuses: [...ALL] }
          : { statuses: [...ALL], uploader: baseUploader },
    });
    return res.relations.find((r) => r.kind === 'uploader')!;
  }

  it('same uploader: available with matching total', () => {
    // media 1 = UploaderA
    const rel = uploaderRel(1, 'UploaderA');
    assert.equal(rel.available, true);
    assert.ok(rel.total > 0);
    assert.equal(rel.filter?.uploader, 'UploaderA');
    const gallery = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      uploader: 'UploaderA',
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(rel.total, gallery.total);
  });

  it('different uploader → total 0, available, does not replace Alice with Bob', () => {
    // media 4 = UploaderB; global Alice
    const rel = uploaderRel(4, 'UploaderA');
    assert.equal(rel.available, true);
    assert.equal(rel.total, 0);
    assert.equal(rel.statusCounts.total, 0);
    // filter carries focus uploader for patch conflict (applyPatch → mediaIds=[])
    assert.equal(rel.filter?.uploader, 'UploaderB');
    assert.deepEqual(rel.filter?.mediaIds, []);
    assert.ok(rel.note);
    const gallery = queryGallery(db, {
      ...rel.filter!,
      statuses: [...ALL],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(gallery.total, 0);
    assert.equal(rel.total, gallery.total);
  });

  it('global null + focus null: match empty uploaders', () => {
    // media 201 = null uploader
    const rel = uploaderRel(201, null);
    assert.equal(rel.available, true);
    assert.equal(rel.filter?.uploader, null);
    const gallery = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      uploader: null,
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(rel.total, gallery.total);
  });

  it('focus null vs global Alice → conflict empty', () => {
    const rel = uploaderRel(201, 'UploaderA');
    assert.equal(rel.available, true);
    assert.equal(rel.total, 0);
    assert.equal(rel.filter?.uploader, null);
  });

  it('relation total == gallery after click (no global uploader)', () => {
    const rel = uploaderRel(1);
    assert.ok(rel.filter);
    const gallery = queryGallery(db, {
      ...rel.filter!,
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(rel.total, gallery.total);
  });

  it('spot-check category/provenance card count == drilldown', () => {
    const res = queryFocus(db, {
      projectId: 7,
      focusMediaId: 1,
      baseFilter: { statuses: [...ALL] },
    });
    for (const kind of ['category', 'provenance'] as const) {
      const rel = res.relations.find((r) => r.kind === kind);
      assert.ok(rel?.available && rel.filter);
      const gallery = queryGallery(db, {
        ...rel!.filter!,
        limit: 50,
        sort: 'media_id',
        dir: 'asc',
      });
      assert.equal(rel!.total, gallery.total, kind);
    }
  });
});
