/**
 * FRV-23 praxis workflow against a synthetic DB with 500+ media.
 * Run: npx tsx scripts/praxis-frv23.ts
 */
import { applyBulk, undoBatch } from '../src/services/bulk.js';
import { queryGallery } from '../src/services/gallery.js';
import { createSyntheticReviewDb } from '../tests/helpers.js';

function statusOf(db: ReturnType<typeof createSyntheticReviewDb>['db'], id: number) {
  const row = db
    .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=?`)
    .get(id) as { status: string } | undefined;
  return row?.status ?? 'unreviewed';
}

const ctx = createSyntheticReviewDb();
const { db, cleanup } = ctx;

// Expand to 500+ unreviewed media for range review
db.exec(`
WITH RECURSIVE seq(i) AS (SELECT 300 UNION ALL SELECT i+1 FROM seq WHERE i<820)
INSERT OR IGNORE INTO media(id,title,current_uploader,created_at,updated_at)
SELECT i, 'File:Praxis_' || printf('%04d',i) || '.jpg', 'PraxisUser', '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z' FROM seq;
WITH RECURSIVE seq(i) AS (SELECT 300 UNION ALL SELECT i+1 FROM seq WHERE i<820)
INSERT OR IGNORE INTO project_media(project_id,media_id,score,selected,download_requested,first_seen_at,updated_at)
SELECT 7, i, 10, 1, 1, '2026-08-14T12:00:00.000Z', '2026-08-14T12:00:00.000Z' FROM seq;
`);

const t0 = performance.now();
const page1 = queryGallery(db, {
  projectId: 7,
  statuses: ['unreviewed', 'unsure'],
  limit: 120,
  sort: 'media_id',
  dir: 'asc',
});
const galleryMs = performance.now() - t0;

const ids: number[] = [];
let cursor = page1.nextCursor;
ids.push(...page1.items.map((i) => i.mediaId));
while (cursor && ids.length < 520) {
  const page = queryGallery(db, {
    projectId: 7,
    statuses: ['unreviewed', 'unsure'],
    limit: 120,
    sort: 'media_id',
    dir: 'asc',
    cursor,
  });
  ids.push(...page.items.map((i) => i.mediaId));
  cursor = page.nextCursor;
}

const range = ids.slice(10, 510); // ~500 images
const tBulk = performance.now();
const batchA = applyBulk(db, {
  projectId: 7,
  action: 'set_status',
  targetStatus: 'reject',
  mediaIds: range,
  protectKeep: true,
  source: 'praxis',
  sessionId: 'praxis-session',
});
const bulkMs = performance.now() - tBulk;

const after = queryGallery(db, {
  projectId: 7,
  statuses: ['unreviewed', 'unsure'],
  limit: 5,
  sort: 'media_id',
  dir: 'asc',
});

const batchB = applyBulk(db, {
  projectId: 7,
  action: 'set_status',
  targetStatus: 'keep',
  mediaIds: after.items.slice(0, 3).map((i) => i.mediaId),
  protectKeep: true,
  source: 'praxis',
  sessionId: 'praxis-session',
});

const tUndo = performance.now();
const uB = undoBatch(db, { projectId: 7, batchId: batchB.batchId, sessionId: 'praxis-session' });
const uA = undoBatch(db, { projectId: 7, batchId: batchA.batchId, sessionId: 'praxis-session' });
const undoMs = performance.now() - tUndo;

const stillRejected = range.filter((id) => statusOf(db, id) === 'reject').length;

const report = {
  loadedIds: ids.length,
  rangeSize: range.length,
  galleryFirstPageMs: Math.round(galleryMs),
  bulkRejectMs: Math.round(bulkMs),
  bulkChanged: batchA.changedCount,
  bulkProtected: batchA.protectedCount,
  resultAfterReject: after.total,
  undoB: uB.restoredCount,
  undoA: uA.restoredCount,
  undoMs: Math.round(undoMs),
  stillRejectedAfterUndoA: stillRejected,
  wallApproxMs: Math.round(performance.now() - t0),
  notes: [
    'Synthetic 500+ range reject + multi-undo on DB copy (not production).',
    'Subjective: gallery page ~ms; bulk of ~500 is local SQLite-bound.',
    'Auto-advance is UI-coupled to loadGeneration (no fixed 350ms timer).',
  ],
};

console.log(JSON.stringify(report, null, 2));
cleanup();

if (range.length < 500) throw new Error('Need >=500 range');
if (batchA.changedCount < 400) throw new Error('Bulk changed too few');
if (uA.restoredCount < 400) throw new Error('Undo A should restore range');
if (stillRejected !== 0) throw new Error('Undo A incomplete');
