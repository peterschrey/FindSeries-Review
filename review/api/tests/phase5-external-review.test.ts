import assert from 'node:assert/strict';
import { describe, it, before, after } from 'node:test';
import { queryGallery } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { queryFacets } from '../src/services/categories.js';
import { createSyntheticReviewDb } from './helpers.js';

const ALL = ['unreviewed', 'keep', 'reject', 'unsure'] as const;

describe('Phase-5 group counts with global filters', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let cleanup: () => void;

  before(() => {
    const ctx = createSyntheticReviewDb();
    db = ctx.db;
    cleanup = ctx.cleanup;
  });

  after(() => cleanup());

  it('global cat A + group cat C uses alsoCategoryIds (AND)', () => {
    const groups = queryGroups(db, {
      projectId: 7,
      statuses: [...ALL],
      categoryIds: [100],
      categoryIncludeDescendants: true,
      groupBy: 'category',
      limit: 50,
      sampleSize: 2,
    });
    const instruments = groups.groups.find((g) => g.key === '103');
    assert.ok(instruments, 'Instruments group present under Dentistry subtree');
    assert.deepEqual(instruments!.drilldown.categoryIds, [100]);
    assert.deepEqual(instruments!.drilldown.alsoCategoryIds, [103]);
    assert.equal(instruments!.drilldown.alsoCategoryIncludeDescendants, true);

    const gallery = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      categoryIds: [100],
      categoryIncludeDescendants: true,
      alsoCategoryIds: [103],
      alsoCategoryIncludeDescendants: true,
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(instruments!.total, gallery.total);
    assert.equal(instruments!.statusCounts.total, gallery.total);
  });

  it('exact categoryIncludeDescendants=false preserved in drilldown', () => {
    const groups = queryGroups(db, {
      projectId: 7,
      statuses: [...ALL],
      categoryIds: [100],
      categoryIncludeDescendants: false,
      groupBy: 'category',
      limit: 50,
      sampleSize: 0,
    });
    // Exact-only on 100: media in 100 itself (none in synthetic — origin is children)
    // Group keys still from filtered base; any category drilldown must preserve flag
    for (const g of groups.groups) {
      if (g.drilldown.alsoCategoryIds?.length) {
        assert.equal(g.drilldown.alsoCategoryIncludeDescendants, false);
      } else if (g.drilldown.categoryIds?.length) {
        assert.equal(g.drilldown.categoryIncludeDescendants, false);
      }
    }
  });

  it('global source + provenance group uses alsoSourceTypes (AND)', () => {
    const groups = queryGroups(db, {
      projectId: 7,
      statuses: [...ALL],
      sourceTypes: ['category'],
      groupBy: 'provenance',
      limit: 50,
      sampleSize: 2,
    });
    // Media with both category and neighbor should appear under neighbor when ANDed
    const neighbor = groups.groups.find((g) => g.key.includes('neighbor'));
    if (neighbor) {
      assert.deepEqual(neighbor.drilldown.sourceTypes, ['category']);
      assert.deepEqual(neighbor.drilldown.alsoSourceTypes, ['neighbor']);
      const gallery = queryGallery(db, {
        projectId: 7,
        statuses: [...ALL],
        sourceTypes: ['category'],
        alsoSourceTypes: ['neighbor'],
        limit: 50,
        sort: 'media_id',
        dir: 'asc',
      });
      assert.equal(neighbor.total, gallery.total);
    } else {
      // Without overlap groups, at least category self-group must not replace sourceTypes
      const cat = groups.groups.find((g) => g.key.includes('category'));
      assert.ok(cat);
      assert.deepEqual(cat!.drilldown.sourceTypes, ['category']);
      assert.equal(cat!.drilldown.alsoSourceTypes, undefined);
    }
  });
});

describe('Phase-5 provenance facet OR (own dimension excluded)', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let cleanup: () => void;

  before(() => {
    const ctx = createSyntheticReviewDb();
    db = ctx.db;
    cleanup = ctx.cleanup;
    // Dedicated facet media: A-only, B-only, A+B
    db.exec(`
      INSERT OR IGNORE INTO media(id, title, current_uploader, created_at, updated_at) VALUES
        (401, 'Facet:A-only', 'FacetUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (402, 'Facet:B-only', 'FacetUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (403, 'Facet:A+B', 'FacetUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
      INSERT OR IGNORE INTO project_media(project_id, media_id, score, selected, download_requested, first_seen_at, updated_at)
      VALUES
        (7, 401, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (7, 402, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (7, 403, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
      INSERT OR IGNORE INTO discoveries(
        project_id, media_id, source_type, source_value, score, query_text, origin_category_id, parent_media_id, created_at
      ) VALUES
        (7, 401, 'facet-A', 'a', 1, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z'),
        (7, 402, 'facet-B', 'b', 1, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z'),
        (7, 403, 'facet-A', 'a', 1, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z'),
        (7, 403, 'facet-B', 'b', 1, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z');
    `);
  });

  after(() => cleanup());

  it('select A: B still visible; counts against base minus own dimension', () => {
    const base = {
      projectId: 7,
      statuses: [...ALL] as unknown as ('unreviewed' | 'keep' | 'reject' | 'unsure')[],
      uploader: 'FacetUser',
    };
    const unselected = queryFacets(db, base);
    const aCount = unselected.provenance.find((p) => p.sourceType === 'facet-A')!.count;
    const bCount = unselected.provenance.find((p) => p.sourceType === 'facet-B')!.count;
    assert.equal(aCount, 2); // 401 + 403
    assert.equal(bCount, 2); // 402 + 403

    const withA = queryFacets(db, { ...base, sourceTypes: ['facet-A'] });
    const aStill = withA.provenance.find((p) => p.sourceType === 'facet-A');
    const bStill = withA.provenance.find((p) => p.sourceType === 'facet-B');
    assert.ok(aStill, 'A still visible');
    assert.ok(bStill, 'B still visible when A selected');
    assert.equal(aStill!.count, 2);
    assert.equal(bStill!.count, 2);

    // Gallery with A+B = union (OR), no double-count of 403
    const union = queryGallery(db, {
      ...base,
      sourceTypes: ['facet-A', 'facet-B'],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    const ids = union.items.map((i) => i.mediaId).filter((id) => id >= 401 && id <= 403);
    assert.deepEqual([...ids].sort((x, y) => x - y), [401, 402, 403]);
    assert.equal(ids.length, 3);
  });
});
