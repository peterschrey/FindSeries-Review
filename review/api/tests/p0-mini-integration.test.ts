/**
 * FRV-42 optional mini-DB integration.
 * Skips when review-dev-mini.db is absent (CI / clean machines).
 * Never opens production or the 19GB gate DB.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { describe, it, before, after } from 'node:test';
import type { GroupBy, ReviewStatus } from '@findseries/review-shared';
import { openReviewDb, type ReviewDb } from '../src/db.js';
import { queryGallery } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { listProjects } from '../src/services/projects.js';
import { queryFocus } from '../src/services/focus.js';

const MINI_DB =
  process.env.REVIEW_MINI_DB_PATH ??
  process.env.REVIEW_DB_PATH ??
  'C:/Temp/FindSeries-Review-Test/review-dev-mini.db';

const ALL: ReviewStatus[] = ['unreviewed', 'keep', 'reject', 'unsure'];
const GROUP_TYPES: GroupBy[] = ['provenance', 'category', 'series', 'uploader', 'seed'];

const present = fs.existsSync(MINI_DB);

describe('FRV-42 mini-DB integration (skip if absent)', { skip: !present }, () => {
  let db: ReviewDb;

  before(() => {
    db = openReviewDb(MINI_DB, { readonly: true });
  });

  after(() => {
    db.close();
  });

  it('opens mini DB readonly and lists projects', () => {
    const { projects } = listProjects(db);
    assert.ok(projects.length >= 1);
    assert.ok(projects.some((p) => p.id === 7));
  });

  it('gallery seek: two pages without duplicate mediaIds', () => {
    const p1 = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      limit: 40,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(p1.total > 40, `expected mini p7 total > 40, got ${p1.total}`);
    assert.ok(p1.nextCursor);
    const p2 = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      limit: 40,
      sort: 'media_id',
      dir: 'asc',
      cursor: p1.nextCursor,
    });
    const ids = [...p1.items, ...p2.items].map((i) => i.mediaId);
    assert.equal(new Set(ids).size, ids.length);
  });

  it('group types return groups; GroupCard.total == gallery drilldown (sample)', () => {
    let withGroups = 0;
    for (const groupBy of GROUP_TYPES) {
      const res = queryGroups(db, {
        projectId: 7,
        statuses: [...ALL],
        groupBy,
        limit: 3,
        sampleSize: 2,
      });
      // Seed keys depend on neighbor/keyword provenance; mini sample may be empty.
      if (res.groups.length === 0) {
        assert.ok(groupBy === 'seed', `unexpected empty groups for ${groupBy}`);
        continue;
      }
      withGroups += 1;
      const g = res.groups[0]!;
      const gallery = queryGallery(db, {
        ...g.drilldown,
        statuses: [...ALL],
        limit: 50,
        sort: 'media_id',
        dir: 'asc',
      });
      assert.equal(g.total, gallery.total, `${groupBy}/${g.key}`);
    }
    assert.ok(withGroups >= 4, `expected ≥4 group types with cards, got ${withGroups}`);
  });

  it('focus returns six relation kinds for a project media', () => {
    const sample = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      limit: 1,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(sample.items[0]);
    const focus = queryFocus(db, {
      projectId: 7,
      focusMediaId: sample.items[0]!.mediaId,
      baseFilter: { statuses: [...ALL] },
    });
    assert.equal(focus.relations.length, 6);
  });
});

describe('FRV-42 mini-DB presence note', () => {
  it('documents skip when mini DB missing (CI-safe)', () => {
    if (!present) {
      console.log(`SKIP mini integration: ${MINI_DB} not found`);
    }
    assert.ok(true);
  });
});
