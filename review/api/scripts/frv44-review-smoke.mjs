/**
 * FRV-44 review smoke against REVIEW_DB_PATH (Temp migrate-work copy only).
 * No physical finalize. Refuses productive DB path.
 */
import assert from 'node:assert/strict';
import path from 'node:path';
import { openReviewDb } from '../src/db.js';
import { listProjects } from '../src/services/projects.js';
import { queryGallery } from '../src/services/gallery.js';
import { listCategoryNodes, queryFacets } from '../src/services/categories.js';
import { queryGroups } from '../src/services/groups.js';
import { queryFocus } from '../src/services/focus.js';
import { applyBulk, undoBatch } from '../src/services/bulk.js';

const PRODUCTION = path.normalize('C:\\FindSeriesV5-Workspace\\findseries-v5.db').toLowerCase();
const dbPath = process.env.REVIEW_DB_PATH;
if (!dbPath) {
  console.error('REVIEW_DB_PATH required');
  process.exit(1);
}
if (path.normalize(dbPath).toLowerCase() === PRODUCTION) {
  console.error('REFUSING smoke on productive DB');
  process.exit(2);
}

const ALL = ['unreviewed', 'keep', 'reject', 'unsure'];
const db = openReviewDb(dbPath);
try {
  const { projects } = listProjects(db);
  assert.ok(projects.length >= 1, 'projects');

  const gallery = queryGallery(db, {
    projectId: 7,
    statuses: [...ALL],
    limit: 5,
    sort: 'media_id',
    dir: 'asc',
  });
  assert.ok(gallery.total >= 1, 'gallery total');
  assert.ok(gallery.items.length >= 1, 'gallery items');

  const nodes = listCategoryNodes(db, {
    projectId: 7,
    parentCategoryId: null,
  });
  assert.ok(Array.isArray(nodes), 'category nodes');

  const facets = queryFacets(db, { projectId: 7, statuses: [...ALL] });
  assert.ok(facets.provenance.length >= 1, 'provenance facets');

  const groups = queryGroups(db, {
    projectId: 7,
    statuses: [...ALL],
    groupBy: 'uploader',
    limit: 3,
    sampleSize: 1,
  });
  assert.ok(groups.groups.length >= 1, 'groups');

  const focusMediaId = gallery.items[0].mediaId;
  const focus = queryFocus(db, {
    projectId: 7,
    focusMediaId,
    baseFilter: { statuses: [...ALL] },
  });
  assert.equal(focus.relations.length, 6, 'focus relations');

  // Small review mutation + undo (sparse restore)
  const mediaId = gallery.items[0].mediaId;
  const before = db
    .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=?`)
    .get(mediaId);
  const batch = applyBulk(db, {
    projectId: 7,
    action: 'set_status',
    targetStatus: 'unsure',
    mediaIds: [mediaId],
    protectKeep: false,
    source: 'frv44-smoke',
  });
  assert.ok(batch.batchId, 'batchId');
  const mid = db
    .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=?`)
    .get(mediaId);
  assert.equal(mid?.status, 'unsure');
  const undo = undoBatch(db, { projectId: 7, batchId: batch.batchId });
  assert.equal(undo.restoredCount, 1);
  const after = db
    .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=?`)
    .get(mediaId);
  if (before) {
    assert.equal(after?.status, before.status);
  } else {
    assert.equal(after, undefined, 'sparse unreviewed restored');
  }

  console.log(
    JSON.stringify({
      ok: true,
      projects: projects.length,
      galleryTotal: gallery.total,
      categoryNodes: nodes.length,
      groups: groups.groups.length,
      focusRelations: focus.relations.length,
      smokeMediaId: mediaId,
      priorStatus: before?.status ?? 'sparse-unreviewed',
      afterUndo: after?.status ?? 'sparse-unreviewed',
      undoRestored: undo.restoredCount,
      sparseRestored: !before && after === undefined,
    }),
  );
} finally {
  db.close();
}
