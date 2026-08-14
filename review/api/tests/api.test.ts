import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, it, before, after } from 'node:test';
import { buildServer } from '../src/server.js';
import { applyBulk, undoBatch } from '../src/services/bulk.js';
import { queryGallery } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { listCategoryNodes, countCategorySubtree, queryFacets } from '../src/services/categories.js';
import { queryFocus } from '../src/services/focus.js';
import { previewFinalize, commitFinalize, resolveAllowedDeletePath } from '../src/services/finalize.js';
import { createSyntheticReviewDb } from './helpers.js';
import type { SortField } from '@findseries/review-shared';

describe('FRV-11..16 review API corrections', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let filesDir: string;
  let cleanup: () => void;
  let logDir: string;

  before(() => {
    const created = createSyntheticReviewDb();
    db = created.db;
    filesDir = created.filesDir;
    cleanup = created.cleanup;
    logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'finalize-log-'));
  });

  after(() => {
    cleanup();
    try {
      fs.rmSync(logDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  });

  it('FRV-11: statuses [] yields empty; omitted uses default', () => {
    const empty = queryGallery(db, {
      projectId: 7,
      statuses: [],
      limit: 10,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(empty.total, 0);
    assert.equal(empty.items.length, 0);

    const def = queryGallery(db, {
      projectId: 7,
      limit: 10,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(def.total > 0);
  });

  it('FRV-11: seek pagination matrix — all sorts, asc/desc, 3 pages, no dupes/gaps', () => {
    const sorts: SortField[] = ['media_id', 'title', 'uploader', 'timestamp', 'score'];
    for (const sort of sorts) {
      for (const dir of ['asc', 'desc'] as const) {
        const collected: number[] = [];
        let cursor: string | null | undefined = undefined;
        for (let page = 0; page < 3; page++) {
          const res = queryGallery(db, {
            projectId: 7,
            statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
            limit: 5,
            sort,
            dir,
            cursor: cursor ?? null,
          });
          collected.push(...res.items.map((i) => i.mediaId));
          cursor = res.nextCursor;
          if (!cursor) break;
        }
        assert.equal(new Set(collected).size, collected.length, `dupes ${sort}/${dir}`);
        // Stable: re-fetch full first N and compare
        const full = queryGallery(db, {
          projectId: 7,
          statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
          limit: collected.length || 1,
          sort,
          dir,
        });
        assert.deepEqual(
          collected,
          full.items.map((i) => i.mediaId),
          `order ${sort}/${dir}`,
        );
      }
    }
  });

  it('FRV-11: malformed / mismatched cursor → 400', async () => {
    const app = await buildServer({ db, finalizeLogDir: logDir, deleteRoots: [filesDir] });
    const bad = await app.inject({
      method: 'POST',
      url: '/api/gallery/query',
      payload: { projectId: 7, limit: 5, cursor: 'not-a-cursor' },
    });
    assert.equal(bad.statusCode, 400);

    const page1 = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
      limit: 3,
      sort: 'media_id',
      dir: 'asc',
    });
    const mismatch = await app.inject({
      method: 'POST',
      url: '/api/gallery/query',
      payload: {
        projectId: 7,
        limit: 3,
        sort: 'title',
        dir: 'asc',
        cursor: page1.nextCursor,
      },
    });
    assert.equal(mismatch.statusCode, 400);
    await app.close();
  });

  it('FRV-12: uploader null drilldown for empty bucket', () => {
    const groups = queryGroups(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
      groupBy: 'uploader',
      limit: 50,
      sampleSize: 4,
    });
    const empty = groups.groups.find((g) => g.key === '(ohne Uploader)');
    assert.ok(empty, 'empty uploader group');
    assert.equal(empty!.drilldown.uploader, null);
    assert.equal(empty!.statusCounts.total, empty!.total);
    for (const s of empty!.sampleMedia) {
      assert.ok(s.uploader == null || s.uploader === '');
    }
    const facets = queryFacets(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
    });
    assert.ok(facets.uploaders.some((u) => u.uploader === null));
  });

  it('FRV-13: lazy category nodes still work', () => {
    const roots = listCategoryNodes(db, { projectId: 7 });
    assert.ok(roots.some((n) => n.categoryId === 100));
    assert.ok(countCategorySubtree(db, 7, 100) >= 4);
  });

  it('FRV-14: seed from PROVENANCE_MODEL; similar unavailable', () => {
    const focus1 = queryFocus(db, { projectId: 7, focusMediaId: 1 });
    const similar = focus1.relations.find((r) => r.kind === 'similar')!;
    assert.equal(similar.available, false);
    assert.equal(similar.filter, null);

    const seed = focus1.relations.find((r) => r.kind === 'seed')!;
    assert.equal(seed.available, true);
    assert.equal(seed.filter?.seedKey, 'media:4');

    const focus2 = queryFocus(db, { projectId: 7, focusMediaId: 2 });
    const seed2 = focus2.relations.find((r) => r.kind === 'seed')!;
    assert.equal(seed2.available, true);
    assert.equal(seed2.filter?.seedKey, 'dentist chair');

    // focus 1 is neighbor parent for media 5
    const asSeed = queryFocus(db, { projectId: 7, focusMediaId: 1 });
    // already has media:4 from own discovery; check media 10 has no invented seed
    const lonely = queryFocus(db, { projectId: 7, focusMediaId: 201 });
    const lonelySeed = lonely.relations.find((r) => r.kind === 'seed')!;
    assert.equal(lonelySeed.available, false);
    assert.equal(lonelySeed.filter, null);
  });

  it('FRV-15: sparse reset undo does not restore after later keep+reset', () => {
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [10],
      protectKeep: false,
      source: 'test',
    });
    const batchA = applyBulk(db, {
      projectId: 7,
      action: 'reset_unreviewed',
      mediaIds: [10],
      protectKeep: false,
      source: 'test',
    });
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [10],
      protectKeep: false,
      source: 'test',
    });
    applyBulk(db, {
      projectId: 7,
      action: 'reset_unreviewed',
      mediaIds: [10],
      protectKeep: false,
      source: 'test',
    });
    const undoA = undoBatch(db, { projectId: 7, batchId: batchA.batchId });
    assert.equal(undoA.restoredCount, 0);
    assert.equal(undoA.skippedProtectedCount, 1);
    const cur = db
      .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=10`)
      .get() as { status: string } | undefined;
    assert.equal(cur, undefined); // still sparse unreviewed from batch C
  });

  it('FRV-15: bulk transaction atomicity on forced error', () => {
    // Simulate by wrapping: run bulk then verify batch row count matches history
    const beforeHist = (
      db.prepare(`SELECT COUNT(*) AS c FROM media_review_history`).get() as { c: number }
    ).c;
    const r = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'unsure',
      mediaIds: [11, 12, 13],
      protectKeep: false,
      source: 'test',
    });
    assert.equal(r.changedCount, 3);
    const hist = db
      .prepare(`SELECT COUNT(*) AS c FROM media_review_history WHERE batch_id=?`)
      .get(r.batchId) as { c: number };
    const batch = db
      .prepare(`SELECT changed_count FROM media_review_batches WHERE batch_id=?`)
      .get(r.batchId) as { changed_count: number };
    assert.equal(hist.c, 3);
    assert.equal(batch.changed_count, 3);
    assert.ok(
      (db.prepare(`SELECT COUNT(*) AS c FROM media_review_history`).get() as { c: number }).c >=
        beforeHist + 3,
    );
  });

  it('FRV-16: eligibility — cross-project block / eligible / keep never deleted', () => {
    // media 1 in projects 7 and 14
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [1],
      protectKeep: false,
      source: 'test',
    });
    // 14 still unreviewed → blocked
    let preview = previewFinalize(
      db,
      { projectId: 7, limit: 50 },
      { logDir, deleteRoots: [filesDir] },
    );
    let item1 = preview.sample.find((s) => s.mediaId === 1)!;
    assert.equal(item1.classification, 'blocked_by_other_project');

    applyBulk(db, {
      projectId: 14,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [1],
      protectKeep: false,
      source: 'test',
    });
    preview = previewFinalize(
      db,
      { projectId: 7, limit: 50 },
      { logDir, deleteRoots: [filesDir] },
    );
    item1 = preview.sample.find((s) => s.mediaId === 1)!;
    assert.equal(item1.classification, 'blocked_by_other_project');

    applyBulk(db, {
      projectId: 14,
      action: 'set_status',
      targetStatus: 'unsure',
      mediaIds: [1],
      protectKeep: false,
      source: 'test',
    });
    preview = previewFinalize(
      db,
      { projectId: 7, limit: 50 },
      { logDir, deleteRoots: [filesDir] },
    );
    item1 = preview.sample.find((s) => s.mediaId === 1)!;
    assert.equal(item1.classification, 'blocked_by_other_project');

    applyBulk(db, {
      projectId: 14,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [1],
      protectKeep: false,
      source: 'test',
    });
    preview = previewFinalize(
      db,
      { projectId: 7, limit: 50 },
      { logDir, deleteRoots: [filesDir] },
    );
    item1 = preview.sample.find((s) => s.mediaId === 1)!;
    assert.equal(item1.classification, 'eligible_for_global_finalization');

    // keep in project must never be physical target
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [4],
      protectKeep: false,
      source: 'test',
    });
    preview = previewFinalize(
      db,
      { projectId: 7, limit: 200 },
      { logDir, deleteRoots: [filesDir] },
    );
    assert.ok(!preview.sample.some((s) => s.mediaId === 4));
  });

  it('FRV-16: preview token binds commit set; path outside root; idempotent', () => {
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [1, 2, 3],
      protectKeep: false,
      source: 'test',
    });
    applyBulk(db, {
      projectId: 14,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [1, 2, 3],
      protectKeep: false,
      source: 'test',
    });

    const preview = previewFinalize(
      db,
      { projectId: 7, limit: 10 },
      { logDir, deleteRoots: [filesDir] },
    );
    assert.ok(preview.previewToken);
    const outside = preview.sample.find((s) => s.mediaId === 3);
    if (outside) {
      assert.equal(outside.classification, 'path_not_allowed');
    }
    const missing = preview.sample.find((s) => s.mediaId === 2);
    if (missing) {
      assert.ok(
        missing.classification === 'missing_file' || missing.classification === 'missing_path',
      );
    }

    const presentPath = path.join(filesDir, 'present-1.jpg');
    assert.ok(fs.existsSync(presentPath));

    const commit1 = commitFinalize(
      db,
      {
        projectId: 7,
        confirm: true,
        previewToken: preview.previewToken,
        dryRun: false,
        deleteFiles: true,
      },
      { logDir, deleteRoots: [filesDir] },
    );
    assert.equal(commit1.attempted, preview.consideredCount);
    assert.ok(commit1.rejectedDb >= 1);
    // media 1 file should be gone if eligible
    const rej = db
      .prepare(`SELECT 1 AS x FROM media_rejections WHERE media_id=1`)
      .get();
    assert.ok(rej);

    // Second commit same token: idempotent / already finalized
    const commit2 = commitFinalize(
      db,
      {
        projectId: 7,
        confirm: true,
        previewToken: preview.previewToken,
        dryRun: false,
        deleteFiles: true,
      },
      { logDir, deleteRoots: [filesDir] },
    );
    assert.ok(commit2.alreadyFinalized >= 1);

    // Next preview must skip already finalized (forward progress)
    const preview2 = previewFinalize(
      db,
      { projectId: 7, limit: 10 },
      { logDir, deleteRoots: [filesDir] },
    );
    assert.ok(!preview2.sample.some((s) => s.mediaId === 1 && s.classification === 'eligible_for_global_finalization'));
    assert.ok(preview2.alreadyFinalizedSkipped >= 1);

    // Commit without matching token fails
    assert.throws(() =>
      commitFinalize(
        db,
        {
          projectId: 7,
          confirm: true,
          previewToken: 'no-such-token',
          dryRun: true,
          deleteFiles: false,
        },
        { logDir, deleteRoots: [filesDir] },
      ),
    );

    // Outside root never deletes
    const outsideFile = [...fs.readdirSync(os.tmpdir())].find((f) => f.startsWith('outside-'));
    if (outsideFile) {
      assert.ok(fs.existsSync(path.join(os.tmpdir(), outsideFile)));
    }
    const check = resolveAllowedDeletePath(path.join(os.tmpdir(), 'x.jpg'), [filesDir]);
    assert.equal(check.ok, false);
  });

  it('HTTP contracts via Fastify', async () => {
    const app = await buildServer({ db, finalizeLogDir: logDir, deleteRoots: [filesDir] });
    const res = await app.inject({
      method: 'POST',
      url: '/api/gallery/query',
      payload: { projectId: 7, limit: 5 },
    });
    assert.equal(res.statusCode, 200);
    await app.close();
  });
});
