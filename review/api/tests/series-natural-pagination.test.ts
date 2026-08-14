import assert from 'node:assert/strict';
import { describe, it, before, after } from 'node:test';
import { queryGallery } from '../src/services/gallery.js';
import { decodeCursor, encodeCursor } from '../src/sql/filters.js';
import { createSyntheticReviewDb } from './helpers.js';

const SERIES = 'nat:test-series';
const ALL = ['unreviewed', 'keep', 'reject', 'unsure'] as const;

describe('series-natural pagination', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let cleanup: () => void;

  before(() => {
    const ctx = createSyntheticReviewDb();
    db = ctx.db;
    cleanup = ctx.cleanup;

    // Extra media for natural-order cases (sequences 1,2,10; tie; null-msk fallback)
    db.exec(`
      INSERT OR IGNORE INTO media(id, title, current_uploader, created_at, updated_at) VALUES
        (301, 'Nat:seq1', 'NatUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (302, 'Nat:seq2', 'NatUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (310, 'Nat:seq10', 'NatUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (320, 'Nat:tie-a', 'NatUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (321, 'Nat:tie-b', 'NatUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (330, 'Nat:fallback', 'NatUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
      INSERT OR IGNORE INTO project_media(project_id, media_id, score, selected, download_requested, first_seen_at, updated_at)
      VALUES
        (7, 301, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (7, 302, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (7, 310, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (7, 320, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (7, 321, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z'),
        (7, 330, 1, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z');
      INSERT OR IGNORE INTO discoveries(
        project_id, media_id, source_type, source_value, score, query_text, origin_category_id, parent_media_id, created_at
      ) VALUES
        (7, 301, 'filename-series', '${SERIES}', 10, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z'),
        (7, 302, 'filename-series', '${SERIES}', 10, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z'),
        (7, 310, 'filename-series', '${SERIES}', 10, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z'),
        (7, 320, 'filename-series', '${SERIES}', 10, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z'),
        (7, 321, 'filename-series', '${SERIES}', 10, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z'),
        (7, 330, 'filename-series', '${SERIES}', 10, NULL, NULL, NULL, '2026-08-14T12:00:00.000Z');
      INSERT OR IGNORE INTO media_series_keys(
        project_id, media_id, strategy, series_key, sequence_no, sequence_label, is_primary, built_at
      ) VALUES
        (7, 301, 'discovery', '${SERIES}', 1, '01', 1, '2026-08-14T12:00:00.000Z'),
        (7, 302, 'discovery', '${SERIES}', 2, '02', 1, '2026-08-14T12:00:00.000Z'),
        (7, 310, 'discovery', '${SERIES}', 10, '10', 1, '2026-08-14T12:00:00.000Z'),
        (7, 320, 'discovery', '${SERIES}', 5, '05a', 1, '2026-08-14T12:00:00.000Z'),
        (7, 321, 'discovery', '${SERIES}', 5, '05b', 1, '2026-08-14T12:00:00.000Z');
      -- 330: discovery membership only (no msk) → COALESCE falls back to media_id
    `);
  });

  after(() => cleanup());

  function naturalOrder(dir: 'asc' | 'desc'): number[] {
    // seq 1,2,5(tie 320<321),10, then fallback 330 (seq=media_id=330)
    const asc = [301, 302, 320, 321, 310, 330];
    return dir === 'asc' ? asc : [...asc].reverse();
  }

  function collectPages(dir: 'asc' | 'desc', limit: number): number[] {
    const collected: number[] = [];
    let cursor: string | null | undefined = undefined;
    for (let i = 0; i < 20; i++) {
      const res = queryGallery(db, {
        projectId: 7,
        statuses: [...ALL],
        seriesKey: SERIES,
        limit,
        sort: 'media_id',
        dir,
        cursor: cursor ?? null,
      });
      collected.push(...res.items.map((m) => m.mediaId));
      cursor = res.nextCursor;
      if (!cursor) break;
    }
    return collected;
  }

  it('ASC: sequences 1,2,10 across pages; no gaps/dupes', () => {
    const expected = naturalOrder('asc');
    const collected = collectPages('asc', 2);
    assert.deepEqual(collected, expected);
    assert.equal(new Set(collected).size, collected.length);
    const full = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      seriesKey: SERIES,
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.deepEqual(
      full.items.map((m) => m.mediaId),
      expected,
    );
  });

  it('DESC inverse of natural order', () => {
    const expected = naturalOrder('desc');
    const collected = collectPages('desc', 2);
    assert.deepEqual(collected, expected);
  });

  it('same sequence_no tie-break by media_id', () => {
    const full = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      seriesKey: SERIES,
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    const ids = full.items.map((m) => m.mediaId);
    const i320 = ids.indexOf(320);
    const i321 = ids.indexOf(321);
    assert.ok(i320 >= 0 && i321 >= 0);
    assert.ok(i320 < i321, 'tie ASC: lower media_id first');
  });

  it('NULL sequence (missing msk) falls back to media_id', () => {
    const full = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      seriesKey: SERIES,
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    const ids = full.items.map((m) => m.mediaId);
    assert.ok(ids.includes(330));
    // 330 after seq 10 (310) because effective seq = 330
    assert.ok(ids.indexOf(330) > ids.indexOf(310));
  });

  it('decodeCursor validates seriesKey / mode', () => {
    const cur = encodeCursor({
      mode: 'series-natural',
      mediaId: 301,
      sequenceNo: 1,
      seriesKey: SERIES,
      sort: 'media_id',
      dir: 'asc',
    });
    const ok = decodeCursor(cur, { sort: 'media_id', dir: 'asc', seriesKey: SERIES });
    assert.equal(ok.mode, 'series-natural');
    assert.equal(ok.seriesKey, SERIES);

    assert.throws(
      () => decodeCursor(cur, { sort: 'media_id', dir: 'asc', seriesKey: 'other' }),
      /seriesKey/,
    );
    assert.throws(
      () =>
        decodeCursor(
          encodeCursor({ mediaId: 1, sort: 'media_id', dir: 'asc' }),
          { sort: 'media_id', dir: 'asc', seriesKey: SERIES },
        ),
      /series-natural/,
    );
  });
});
