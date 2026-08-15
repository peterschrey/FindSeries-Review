/**
 * FRV-42 P0 release-gate: synthetic-DB coverage for paths not fully
 * asserted as an explicit matrix in earlier suites.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, it, before, after } from 'node:test';
import sharp from 'sharp';
import type { GroupBy, ReviewStatus } from '@findseries/review-shared';
import { buildServer } from '../src/server.js';
import { openReviewDb, type ReviewDb } from '../src/db.js';
import { applyBulk, undoBatch } from '../src/services/bulk.js';
import { queryGallery } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { countCategorySubtree, listCategoryNodes, queryFacets } from '../src/services/categories.js';
import { queryFocus } from '../src/services/focus.js';
import { listProjects } from '../src/services/projects.js';
import { previewFinalize, commitFinalize } from '../src/services/finalize.js';
import { createSyntheticReviewDb } from './helpers.js';

const ALL: ReviewStatus[] = ['unreviewed', 'keep', 'reject', 'unsure'];
const GROUP_TYPES: GroupBy[] = ['provenance', 'category', 'series', 'uploader', 'seed'];
const FOCUS_KINDS = ['similar', 'series', 'category', 'seed', 'uploader', 'provenance'] as const;

function statusOf(db: ReviewDb, mediaId: number): ReviewStatus {
  const row = db
    .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=?`)
    .get(mediaId) as { status: ReviewStatus } | undefined;
  return row?.status ?? 'unreviewed';
}

describe('FRV-42 P0 release gate (synthetic DB)', () => {
  let db: ReviewDb;
  let filesDir: string;
  let cleanup: () => void;
  let logDir: string;

  before(async () => {
    const created = createSyntheticReviewDb();
    db = created.db;
    filesDir = created.filesDir;
    cleanup = created.cleanup;
    logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'frv42-log-'));
    const jpg = await sharp({
      create: { width: 32, height: 32, channels: 3, background: { r: 40, g: 80, b: 120 } },
    })
      .jpeg()
      .toBuffer();
    fs.writeFileSync(path.join(filesDir, 'present-1.jpg'), jpg);
    db.exec(`
      INSERT OR IGNORE INTO media_series_keys(
        project_id, media_id, strategy, series_key, sequence_no, sequence_label, is_primary, built_at
      ) VALUES
        (7, 5, 'discovery', 'disc:filename-series:Instrument_series', 1, '01', 1, '2026-08-14T12:00:00.000Z'),
        (7, 6, 'discovery', 'disc:filename-series:Instrument_series', 2, '02', 1, '2026-08-14T12:00:00.000Z');
    `);
  });

  after(() => {
    cleanup();
    try {
      fs.rmSync(logDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  });

  it('projects: listProjects returns id/name/slug for fixture projects', () => {
    const { projects } = listProjects(db);
    assert.ok(projects.some((p) => p.id === 7 && p.slug === 'cat-dentistry'));
    assert.ok(projects.some((p) => p.id === 14));
  });

  it('gallery filters: q / sourceTypes / uploader / empty arrays', () => {
    const byQ = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      q: 'Dental_chair',
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(byQ.total >= 1);
    assert.ok(byQ.items.every((i) => /dental_chair/i.test(i.title)));

    const bySrc = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      sourceTypes: ['category'],
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(bySrc.total >= 1);

    const emptySrc = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      sourceTypes: [],
      limit: 10,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(emptySrc.total, 0);

    const byUploader = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      uploader: 'UploaderA',
      limit: 50,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(byUploader.total >= 1);
    assert.ok(byUploader.items.every((i) => i.uploader === 'UploaderA'));
  });

  it('categories: exact vs subtree vs fallback membership', () => {
    const subtree = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      categoryIds: [100],
      categoryIncludeDescendants: true,
      limit: 100,
      sort: 'media_id',
      dir: 'asc',
    });
    const exact = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      categoryIds: [100],
      categoryIncludeDescendants: false,
      limit: 100,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(subtree.total > exact.total, 'subtree must include descendants');
    assert.ok(countCategorySubtree(db, 7, 100) >= subtree.total);

    const fallback = queryGallery(db, {
      projectId: 7,
      statuses: [...ALL],
      categoryIds: [200],
      categoryIncludeDescendants: false,
      limit: 20,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.ok(fallback.items.some((i) => i.mediaId === 200));

    const children = listCategoryNodes(db, { projectId: 7, parentCategoryId: 100 });
    assert.ok(children.some((n) => n.categoryId === 101));
  });

  it('all group types return groups without throw', () => {
    for (const groupBy of GROUP_TYPES) {
      const res = queryGroups(db, {
        projectId: 7,
        statuses: [...ALL],
        groupBy,
        limit: 20,
        sampleSize: 2,
      });
      assert.ok(Array.isArray(res.groups), groupBy);
      assert.ok(res.groups.length >= 1, `expected groups for ${groupBy}`);
      for (const g of res.groups) {
        assert.equal(g.statusCounts.total, g.total, `${groupBy}/${g.key} statusCounts`);
      }
    }
  });

  it('focus relations: all six kinds present for seeded media', () => {
    const focus = queryFocus(db, { projectId: 7, focusMediaId: 1 });
    assert.deepEqual(
      focus.relations.map((r) => r.kind),
      [...FOCUS_KINDS],
    );
    assert.equal(focus.relations.find((r) => r.kind === 'similar')!.available, false);
    assert.equal(focus.relations.find((r) => r.kind === 'uploader')!.available, true);
    assert.equal(focus.relations.find((r) => r.kind === 'category')!.available, true);
    assert.equal(focus.relations.find((r) => r.kind === 'provenance')!.available, true);
    assert.equal(focus.relations.find((r) => r.kind === 'seed')!.available, true);
  });

  it('bulk K/R/U/N: keep, reject, unsure, reset_unreviewed', () => {
    const ids = [60, 61, 62, 63];
    const keep = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [ids[0]],
      source: 'test-K',
    });
    assert.equal(keep.changedCount, 1);
    assert.equal(statusOf(db, ids[0]), 'keep');

    const reject = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [ids[1]],
      protectKeep: true,
      source: 'test-R',
    });
    assert.equal(reject.changedCount, 1);
    assert.equal(statusOf(db, ids[1]), 'reject');

    const unsure = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'unsure',
      mediaIds: [ids[2]],
      source: 'test-U',
    });
    assert.equal(unsure.changedCount, 1);
    assert.equal(statusOf(db, ids[2]), 'unsure');

    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [ids[3]],
      source: 'test-pre-N',
    });
    const reset = applyBulk(db, {
      projectId: 7,
      action: 'reset_unreviewed',
      mediaIds: [ids[3]],
      source: 'test-N',
    });
    assert.equal(reset.changedCount, 1);
    assert.equal(statusOf(db, ids[3]), 'unreviewed');
    const sparse = db
      .prepare(`SELECT 1 AS x FROM media_review_status WHERE project_id=7 AND media_id=?`)
      .get(ids[3]);
    assert.equal(sparse, undefined);
  });

  it('keep protection: default protectKeep skips keep on mass reject', () => {
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [70, 71],
      source: 'test',
    });
    const mass = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [70, 71, 72],
      // protectKeep omitted → schema/service default true
      source: 'test-mass-R',
    });
    assert.equal(statusOf(db, 70), 'keep');
    assert.equal(statusOf(db, 71), 'keep');
    assert.equal(statusOf(db, 72), 'reject');
    assert.ok(mass.protectedCount >= 2);
    assert.equal(mass.changedCount, 1);
  });

  it('HTTP: projects + malformed bodies → 400; health ok', async () => {
    const app = await buildServer({ db, finalizeLogDir: logDir, deleteRoots: [filesDir] });
    const health = await app.inject({ method: 'GET', url: '/health' });
    assert.equal(health.statusCode, 200);

    const projects = await app.inject({ method: 'GET', url: '/api/projects' });
    assert.equal(projects.statusCode, 200);
    const body = projects.json() as { projects: Array<{ id: number }> };
    assert.ok(body.projects.some((p) => p.id === 7));

    const badGallery = await app.inject({
      method: 'POST',
      url: '/api/gallery/query',
      payload: { projectId: 'nope', limit: 5 },
    });
    assert.equal(badGallery.statusCode, 400);

    const badGroups = await app.inject({
      method: 'POST',
      url: '/api/groups/query',
      payload: { projectId: 7, groupBy: 'not-a-group' },
    });
    assert.equal(badGroups.statusCode, 400);

    const badBulk = await app.inject({
      method: 'POST',
      url: '/api/review/bulk',
      payload: { projectId: 7, action: 'not-an-action', mediaIds: [1] },
    });
    assert.equal(badBulk.statusCode, 400);

    const badFocus = await app.inject({
      method: 'POST',
      url: '/api/focus/query',
      payload: { projectId: 7 },
    });
    assert.equal(badFocus.statusCode, 400);

    const badFinalize = await app.inject({
      method: 'POST',
      url: '/api/finalize/commit',
      payload: { projectId: 7, confirm: false, previewToken: 'x' },
    });
    assert.equal(badFinalize.statusCode, 400);

    await app.close();
  });

  it('all group types: GroupCard.total == gallery after drilldown', () => {
    for (const groupBy of GROUP_TYPES) {
      const res = queryGroups(db, {
        projectId: 7,
        statuses: [...ALL],
        groupBy,
        limit: 10,
        sampleSize: 2,
      });
      assert.ok(res.groups.length >= 1, groupBy);
      for (const g of res.groups.slice(0, 3)) {
        const gallery = queryGallery(db, {
          ...g.drilldown,
          statuses: [...ALL],
          limit: 200,
          sort: 'media_id',
          dir: 'asc',
        });
        assert.equal(g.total, gallery.total, `${groupBy}/${g.key}`);
        for (const s of g.sampleMedia) {
          assert.ok(
            gallery.items.some((i) => i.mediaId === s.mediaId) || gallery.total > gallery.items.length,
            `${groupBy} sample ${s.mediaId} in result set`,
          );
        }
      }
    }
  });

  it('focus uploader AND: Alice + Bob focus → total 0', () => {
    // media 4 = UploaderB
    const focus = queryFocus(db, {
      projectId: 7,
      focusMediaId: 4,
      baseFilter: { statuses: [...ALL], uploader: 'UploaderA' },
    });
    const rel = focus.relations.find((r) => r.kind === 'uploader')!;
    assert.equal(rel.available, true);
    assert.equal(rel.total, 0);
    assert.deepEqual(rel.filter?.mediaIds, []);
    const gallery = queryGallery(db, {
      ...rel.filter!,
      statuses: [...ALL],
      limit: 20,
      sort: 'media_id',
      dir: 'asc',
    });
    assert.equal(gallery.total, 0);
  });

  it('multi-undo: A keep → B unsure → Undo B → Undo A → sparse', () => {
    const mediaId = 80;
    const a = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [mediaId],
      source: 'gate-undo-A',
    });
    // protectKeep defaults true and would block keep→unsure; intentional status chain needs false.
    const b = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'unsure',
      mediaIds: [mediaId],
      protectKeep: false,
      source: 'gate-undo-B',
    });
    assert.equal(statusOf(db, mediaId), 'unsure');
    assert.equal(undoBatch(db, { projectId: 7, batchId: b.batchId }).restoredCount, 1);
    assert.equal(statusOf(db, mediaId), 'keep');
    assert.equal(undoBatch(db, { projectId: 7, batchId: a.batchId }).restoredCount, 1);
    assert.equal(statusOf(db, mediaId), 'unreviewed');
    const row = db
      .prepare(`SELECT 1 AS x FROM media_review_status WHERE project_id=7 AND media_id=?`)
      .get(mediaId);
    assert.equal(row, undefined);
  });

  it('thumbnails: cold MISS then warm HIT; missing → placeholder', async () => {
    const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), 'frv42-thumb-'));
    try {
      const app = await buildServer({
        db,
        finalizeLogDir: logDir,
        deleteRoots: [filesDir],
        mediaRoots: [filesDir],
        thumbCacheDir: cacheDir,
      });
      const cold = await app.inject({ method: 'GET', url: '/api/media/1/thumb?size=80' });
      assert.equal(cold.statusCode, 200);
      assert.equal(cold.headers['x-thumb-cache'], 'MISS');
      const warm = await app.inject({ method: 'GET', url: '/api/media/1/thumb?size=80' });
      assert.equal(warm.statusCode, 200);
      assert.equal(warm.headers['x-thumb-cache'], 'HIT');
      const missing = await app.inject({ method: 'GET', url: '/api/media/2/thumb?size=80' });
      assert.ok([403, 404].includes(missing.statusCode));
      await app.close();
    } finally {
      fs.rmSync(cacheDir, { recursive: true, force: true });
    }
  });

  it('finalize preview/safety: reject-only; keep never candidate; dry-run', () => {
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [1, 2],
      protectKeep: false,
      source: 'gate-fin',
    });
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [3],
      source: 'gate-fin-keep',
    });
    const opts = { logDir, deleteRoots: [filesDir] };
    const preview = previewFinalize(db, { projectId: 7, limit: 50 }, opts);
    assert.ok(preview.consideredCount >= 2);
    assert.ok(preview.sample.every((s) => s.reviewStatus === 'reject'));
    assert.ok(!preview.sample.some((s) => s.mediaId === 3));

    const dry = commitFinalize(
      db,
      {
        projectId: 7,
        confirm: true,
        dryRun: true,
        deleteFiles: true,
        previewToken: preview.previewToken,
      },
      opts,
    );
    assert.equal(dry.dryRun, true);
    assert.equal(statusOf(db, 3), 'keep');
  });

  it('gallery: all sorts seek pagination 2 pages no dupes', () => {
    const sorts = ['media_id', 'title', 'uploader', 'timestamp', 'score'] as const;
    for (const sort of sorts) {
      for (const dir of ['asc', 'desc'] as const) {
        const p1 = queryGallery(db, {
          projectId: 7,
          statuses: [...ALL],
          limit: 15,
          sort,
          dir,
        });
        assert.ok(p1.items.length > 0, `${sort}/${dir}`);
        if (!p1.nextCursor) continue;
        const p2 = queryGallery(db, {
          projectId: 7,
          statuses: [...ALL],
          limit: 15,
          sort,
          dir,
          cursor: p1.nextCursor,
        });
        const ids = [...p1.items, ...p2.items].map((i) => i.mediaId);
        assert.equal(new Set(ids).size, ids.length, `${sort}/${dir} dupes`);
      }
    }
  });

  it('provenance facets return source types', () => {
    const facets = queryFacets(db, { projectId: 7, statuses: [...ALL] });
    assert.ok(facets.provenance.length >= 1);
    assert.ok(facets.uploaders.length >= 1);
  });

  it('busy/error paths: busy_timeout pragma + readonly open', () => {
    const timeout = db.pragma('busy_timeout', { simple: true }) as number | string;
    assert.equal(Number(timeout), 5000);

    const dbPath = (
      db.prepare(`PRAGMA database_list`).all() as Array<{ file: string }>
    ).find((r) => r.file)?.file;
    assert.ok(dbPath);
    const ro = openReviewDb(dbPath!, { readonly: true });
    try {
      const qonly = ro.pragma('query_only', { simple: true });
      assert.ok(qonly === 1 || qonly === '1' || qonly === true);
      assert.throws(() => {
        ro.exec(`CREATE TABLE IF NOT EXISTS __should_fail(x INTEGER)`);
      });
    } finally {
      ro.close();
    }
  });
});
