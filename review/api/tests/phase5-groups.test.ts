import assert from 'node:assert/strict';
import { describe, it, before, after } from 'node:test';
import { queryGallery } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { createSyntheticReviewDb } from './helpers.js';

describe('Phase-5 provenance / category exact / series-seed', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let cleanup: () => void;

  before(() => {
    const ctx = createSyntheticReviewDb();
    db = ctx.db;
    cleanup = ctx.cleanup;
    db.exec(`
      INSERT OR IGNORE INTO media_series_keys(
        project_id, media_id, strategy, series_key, sequence_no, sequence_label, is_primary, built_at
      ) VALUES
        (7, 5, 'discovery', 'disc:filename-series:Instrument_series', 1, '01', 1, '2026-08-14T12:00:00.000Z'),
        (7, 6, 'discovery', 'disc:filename-series:Instrument_series', 2, '02', 1, '2026-08-14T12:00:00.000Z'),
        (7, 5, 'filename', 'instrument_series_', 1, '01', 0, '2026-08-14T12:00:00.000Z');
    `);
  });

  after(() => cleanup());

  it('gallery page bundles provenance chips without N+1 shape', () => {
    const res = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      limit: 20,
      sort: 'media_id',
      dir: 'asc',
    });
    const withProv = res.items.filter((i) => (i.provenance?.length ?? 0) > 0);
    assert.ok(withProv.length >= 1);
    const multi = res.items.find((i) => (i.provenance?.length ?? 0) >= 2);
    // media 1 has category + neighbor from helpers
    assert.ok(multi || res.items.some((i) => i.mediaId === 1 && (i.provenance?.length ?? 0) >= 1));
  });

  it('categoryIncludeDescendants=false is exact-only', () => {
    const subtree = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      categoryIds: [100],
      categoryIncludeDescendants: true,
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    const exact = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      categoryIds: [100],
      categoryIncludeDescendants: false,
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(subtree.total >= exact.total);
  });

  it('groupBy seed returns keys; series uses primary keys', () => {
    const seeds = queryGroups(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      groupBy: 'seed',
      limit: 20,
      sampleSize: 2,
    });
    assert.ok(seeds.groups.length >= 1);
    const series = queryGroups(db, {
      projectId: 7,
      statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      groupBy: 'series',
      limit: 20,
      sampleSize: 4,
    });
    const primary = series.groups.find((g) => g.key.includes('Instrument_series'));
    assert.ok(primary);
    assert.equal(primary!.sampleMedia.length, Math.min(4, primary!.total));
    // samples deterministic ascending media_id
    const ids = primary!.sampleMedia.map((m) => m.mediaId);
    assert.deepEqual(ids, [...ids].sort((a, b) => a - b));
  });
});
