import { randomUUID } from 'node:crypto';
import type {
  BulkRequest,
  BulkResponse,
  MediaFilter,
  ReviewStatus,
  UndoRequest,
  UndoResponse,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import { utcNow } from '../db.js';
import { buildFilteredMediaCte, resolveStatuses } from '../sql/filters.js';

function resolveTargetIds(db: ReviewDb, req: BulkRequest): number[] {
  if (req.mediaIds?.length) {
    const placeholders = req.mediaIds.map(() => '?').join(',');
    const rows = db
      .prepare(
        `SELECT media_id FROM project_media
         WHERE project_id = ? AND media_id IN (${placeholders})`,
      )
      .all(req.projectId, ...req.mediaIds) as Array<{ media_id: number }>;
    return rows.map((r) => r.media_id);
  }
  const filter: MediaFilter = {
    projectId: req.projectId,
    statuses: req.filter?.statuses,
    q: req.filter?.q,
    sourceTypes: req.filter?.sourceTypes,
    categoryIds: req.filter?.categoryIds,
    alsoCategoryIds: req.filter?.alsoCategoryIds,
    alsoSourceTypes: req.filter?.alsoSourceTypes,
    uploader: req.filter?.uploader,
    seriesKey: req.filter?.seriesKey,
    seedKey: req.filter?.seedKey,
    parentMediaId: req.filter?.parentMediaId,
    mediaIds: req.filter?.mediaIds,
  };
  if (resolveStatuses(filter) === 'empty') return [];
  const base = buildFilteredMediaCte(filter, 'count');
  const rows = db
    .prepare(`WITH fm AS (${base.sql}) SELECT media_id FROM fm`)
    .all(...base.params) as Array<{ media_id: number }>;
  return rows.map((r) => r.media_id);
}

export function applyBulk(db: ReviewDb, req: BulkRequest): BulkResponse {
  if (req.action === 'set_status' && !req.targetStatus) {
    throw new Error('targetStatus required for set_status');
  }
  if (req.action === 'set_status' && req.targetStatus === 'unreviewed') {
    throw new Error('Use reset_unreviewed to clear status (sparse model)');
  }

  const mediaIds = resolveTargetIds(db, req);
  const batchId = randomUUID();
  const now = utcNow();
  const protectKeep = req.protectKeep !== false;
  const targetStatus: ReviewStatus | null =
    req.action === 'reset_unreviewed' ? 'unreviewed' : (req.targetStatus ?? null);

  const selectCurrent = db.prepare(
    `SELECT status, batch_id FROM media_review_status
     WHERE project_id = ? AND media_id = ?`,
  );
  const insertHistory = db.prepare(
    `INSERT INTO media_review_history(
       project_id, media_id, old_status, new_status, changed_at, changed_by,
       source, action, batch_id, session_id
     ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)`,
  );
  const upsertStatus = db.prepare(
    `INSERT INTO media_review_status(
       project_id, media_id, status, changed_at, changed_by, source, action, batch_id
     ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?)
     ON CONFLICT(project_id, media_id) DO UPDATE SET
       status = excluded.status,
       changed_at = excluded.changed_at,
       source = excluded.source,
       action = excluded.action,
       batch_id = excluded.batch_id`,
  );
  const deleteStatus = db.prepare(
    `DELETE FROM media_review_status WHERE project_id = ? AND media_id = ?`,
  );
  const insertBatch = db.prepare(
    `INSERT INTO media_review_batches(
       batch_id, project_id, action, target_status, protect_keep,
       media_count, changed_count, protected_count, created_at, source, session_id
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );

  let changed = 0;
  let protectedCount = 0;
  let skipped = 0;

  // Entire bulk is one SQLite transaction — crash mid-loop rolls back all.
  const tx = db.transaction(() => {
    for (const mediaId of mediaIds) {
      const cur = selectCurrent.get(req.projectId, mediaId) as
        | { status: ReviewStatus; batch_id: string | null }
        | undefined;
      const oldStatus: ReviewStatus = cur?.status ?? 'unreviewed';

      if (protectKeep && oldStatus === 'keep' && targetStatus !== 'keep') {
        protectedCount += 1;
        continue;
      }
      if (req.action === 'reset_unreviewed') {
        if (oldStatus === 'unreviewed' && !cur) {
          skipped += 1;
          continue;
        }
        insertHistory.run(
          req.projectId,
          mediaId,
          oldStatus,
          'unreviewed',
          now,
          req.source,
          'reset_unreviewed',
          batchId,
          req.sessionId ?? null,
        );
        deleteStatus.run(req.projectId, mediaId);
        changed += 1;
        continue;
      }

      if (oldStatus === targetStatus) {
        skipped += 1;
        continue;
      }
      insertHistory.run(
        req.projectId,
        mediaId,
        oldStatus,
        targetStatus,
        now,
        req.source,
        'set_status',
        batchId,
        req.sessionId ?? null,
      );
      upsertStatus.run(
        req.projectId,
        mediaId,
        targetStatus,
        now,
        req.source,
        'set_status',
        batchId,
      );
      changed += 1;
    }

    insertBatch.run(
      batchId,
      req.projectId,
      req.action,
      targetStatus ?? 'unreviewed',
      protectKeep ? 1 : 0,
      mediaIds.length,
      changed,
      protectedCount,
      now,
      req.source,
      req.sessionId ?? null,
    );
  });

  tx();

  return {
    batchId,
    targetStatus,
    mediaCount: mediaIds.length,
    changedCount: changed,
    protectedCount,
    skippedCount: skipped,
  };
}

/**
 * Undo only if no later history row exists for the same project/media
 * after this batch's history entry (covers sparse reset where current row is gone).
 */
export function undoBatch(db: ReviewDb, req: UndoRequest): UndoResponse {
  let batchId = req.batchId;
  if (!batchId) {
    const row = db
      .prepare(
        `SELECT batch_id FROM media_review_batches
         WHERE project_id = ?
           AND undone_at IS NULL
           ${req.sessionId ? 'AND session_id = ?' : ''}
         ORDER BY created_at DESC, batch_id DESC
         LIMIT 1`,
      )
      .get(...(req.sessionId ? [req.projectId, req.sessionId] : [req.projectId])) as
      | { batch_id: string }
      | undefined;
    if (!row) throw new Error('No undoable batch found');
    batchId = row.batch_id;
  }

  const batch = db
    .prepare(
      `SELECT batch_id, undone_at FROM media_review_batches
       WHERE project_id = ? AND batch_id = ?`,
    )
    .get(req.projectId, batchId) as { batch_id: string; undone_at: string | null } | undefined;
  if (!batch) throw new Error('Batch not found');
  if (batch.undone_at) throw new Error('Batch already undone');

  const now = utcNow();
  const hist = db
    .prepare(
      `SELECT id, media_id, old_status, new_status
       FROM media_review_history
       WHERE project_id = ? AND batch_id = ?
       ORDER BY id ASC`,
    )
    .all(req.projectId, batchId) as Array<{
    id: number;
    media_id: number;
    old_status: ReviewStatus;
    new_status: ReviewStatus;
  }>;

  const laterExists = db.prepare(
    `SELECT 1 AS x FROM media_review_history
     WHERE project_id = ? AND media_id = ? AND id > ?
     LIMIT 1`,
  );
  const selectCurrent = db.prepare(
    `SELECT status, batch_id FROM media_review_status
     WHERE project_id = ? AND media_id = ?`,
  );
  const upsertStatus = db.prepare(
    `INSERT INTO media_review_status(
       project_id, media_id, status, changed_at, changed_by, source, action, batch_id
     ) VALUES (?, ?, ?, ?, NULL, 'undo', 'undo', ?)
     ON CONFLICT(project_id, media_id) DO UPDATE SET
       status = excluded.status,
       changed_at = excluded.changed_at,
       source = excluded.source,
       action = excluded.action,
       batch_id = excluded.batch_id`,
  );
  const deleteStatus = db.prepare(
    `DELETE FROM media_review_status WHERE project_id = ? AND media_id = ?`,
  );
  const insertHistory = db.prepare(
    `INSERT INTO media_review_history(
       project_id, media_id, old_status, new_status, changed_at, source, action, batch_id, session_id
     ) VALUES (?, ?, ?, ?, ?, 'undo', 'undo', ?, ?)`,
  );
  const markUndone = db.prepare(
    `UPDATE media_review_batches SET undone_at = ? WHERE batch_id = ?`,
  );

  let restored = 0;
  let skippedProtected = 0;
  const undoBatchId = randomUUID();

  const tx = db.transaction(() => {
    for (const h of hist) {
      const later = laterExists.get(req.projectId, h.media_id, h.id);
      if (later) {
        skippedProtected += 1;
        continue;
      }
      const cur = selectCurrent.get(req.projectId, h.media_id) as
        | { status: ReviewStatus; batch_id: string | null }
        | undefined;
      const currentStatus: ReviewStatus = cur?.status ?? 'unreviewed';
      insertHistory.run(
        req.projectId,
        h.media_id,
        currentStatus,
        h.old_status,
        now,
        undoBatchId,
        req.sessionId ?? null,
      );
      if (h.old_status === 'unreviewed') {
        deleteStatus.run(req.projectId, h.media_id);
      } else {
        upsertStatus.run(req.projectId, h.media_id, h.old_status, now, undoBatchId);
      }
      restored += 1;
    }
    markUndone.run(now, batchId);
  });
  tx();

  return {
    batchId,
    restoredCount: restored,
    skippedProtectedCount: skippedProtected,
  };
}
