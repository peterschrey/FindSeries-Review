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
import { previewFinalize, commitFinalize } from '../src/services/finalize.js';
import { createSyntheticReviewDb } from './helpers.js';

describe('FRV-11..16 review API (synthetic)', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let cleanup: () => void;
  let logDir: string;

  before(() => {
    const created = createSyntheticReviewDb();
    db = created.db;
    cleanup = created.cleanup;
    logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'finalize-log-'));
    const filesDir = path.join('C:/Temp/FindSeries-Review-Test/files');
    fs.mkdirSync(filesDir, { recursive: true });
    fs.writeFileSync(path.join(filesDir, 'present-1.jpg'), 'ok');
  });

  after(() => {
    cleanup();
    try {
      fs.rmSync(logDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  });

  it('FRV-11: gallery seek pagination has no dupes/gaps', () => {
    const page1 = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
      limit: 20,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(page1.items.length, 20);
    assert.ok(page1.nextCursor);
    const page2 = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
      limit: 20,
      sort: 'media_id',
      dir: 'asc',
      cursor: page1.nextCursor,
    });
    const ids = [...page1.items, ...page2.items].map((i) => i.mediaId);
    assert.equal(new Set(ids).size, ids.length);
    for (let i = 1; i < ids.length; i++) {
      assert.ok(ids[i] > ids[i - 1]);
    }
    assert.ok(page1.total >= 100);
  });

  it('FRV-11: category filter uses origin + fallback', () => {
    const withOrigin = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
      categoryIds: [101],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(withOrigin.total >= 3);
    const fallback = queryGallery(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
      categoryIds: [200],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(fallback.total, 1);
    assert.equal(fallback.items[0].mediaId, 200);
  });

  it('FRV-12: groups by uploader with status counts', () => {
    const groups = queryGroups(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
      groupBy: 'uploader',
      limit: 20,
      sampleSize: 2,
    });
    assert.ok(groups.groups.length >= 2);
    const a = groups.groups.find((g) => g.key === 'UploaderA');
    assert.ok(a);
    assert.ok(a!.total >= 3);
    assert.equal(a!.statusCounts.total, a!.total);
    assert.ok(a!.sampleMedia.length > 0);
    assert.equal(a!.drilldown.uploader, 'UploaderA');
  });

  it('FRV-13: lazy category nodes + facets', () => {
    const roots = listCategoryNodes(db, { projectId: 7 });
    assert.ok(roots.some((n) => n.categoryId === 100));
    const children = listCategoryNodes(db, { projectId: 7, parentCategoryId: 100 });
    assert.ok(children.some((n) => n.categoryId === 101));
    const subtree = countCategorySubtree(db, 7, 100);
    assert.ok(subtree >= 4);
    const facets = queryFacets(db, {
      projectId: 7,
      statuses: ['unreviewed', 'unsure', 'keep', 'reject'],
    });
    assert.ok(facets.provenance.length >= 1);
    assert.ok(facets.uploaders.length >= 1);
  });

  it('FRV-14: focus relations for real media', () => {
    const focus = queryFocus(db, { projectId: 7, focusMediaId: 1 });
    assert.equal(focus.focusMediaId, 1);
    const kinds = focus.relations.map((r) => r.kind);
    assert.deepEqual(kinds, ['similar', 'series', 'category', 'seed', 'uploader', 'provenance']);
    const cat = focus.relations.find((r) => r.kind === 'category');
    assert.ok(cat && cat.total >= 1);
    const up = focus.relations.find((r) => r.kind === 'uploader');
    assert.ok(up && up.total >= 1);
  });

  it('FRV-15: bulk protect keep + undo', () => {
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [1],
      protectKeep: true,
      source: 'test',
    });
    const reject = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [1, 2, 3],
      protectKeep: true,
      source: 'test',
      sessionId: 's1',
    });
    assert.equal(reject.protectedCount, 1);
    assert.equal(reject.changedCount, 2);

    const st1 = db
      .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=1`)
      .get() as { status: string };
    assert.equal(st1.status, 'keep');

    const undo = undoBatch(db, { projectId: 7, batchId: reject.batchId });
    assert.equal(undo.restoredCount, 2);
    const st2 = db
      .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=2`)
      .get() as { status: string } | undefined;
    assert.equal(st2, undefined);

    const reset = applyBulk(db, {
      projectId: 7,
      action: 'reset_unreviewed',
      mediaIds: [1],
      protectKeep: false,
      source: 'test',
    });
    assert.equal(reset.changedCount, 1);
    const gone = db
      .prepare(`SELECT 1 AS x FROM media_review_status WHERE project_id=7 AND media_id=1`)
      .get();
    assert.equal(gone, undefined);
  });

  it('FRV-16: finalize preview + dry-run never deletes keep', () => {
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [1, 2],
      protectKeep: false,
      source: 'test',
    });
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [3],
      protectKeep: false,
      source: 'test',
    });
    const preview = previewFinalize(db, { projectId: 7, limit: 50 });
    assert.ok(preview.candidateCount >= 2);
    assert.ok(preview.sample.every((s) => s.reviewStatus === 'reject'));
    const dry = commitFinalize(
      db,
      { projectId: 7, confirm: true, dryRun: true, deleteFiles: true, maxItems: 50 },
      logDir,
    );
    assert.equal(dry.dryRun, true);
    assert.ok(fs.existsSync(path.join('C:/Temp/FindSeries-Review-Test/files/present-1.jpg')));
    const keep = db
      .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=3`)
      .get() as { status: string };
    assert.equal(keep.status, 'keep');
  });

  it('HTTP contracts via Fastify', async () => {
    const app = await buildServer({ db, finalizeLogDir: logDir });
    const res = await app.inject({
      method: 'POST',
      url: '/api/gallery/query',
      payload: { projectId: 7, limit: 5 },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.ok(Array.isArray(body.items));
    assert.ok(typeof body.total === 'number');
    await app.close();
  });
});
