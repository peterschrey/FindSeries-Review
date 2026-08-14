import assert from 'node:assert/strict';
import { describe, it, before, after } from 'node:test';
import { applyBulk, undoBatch } from '../src/services/bulk.js';
import { createSyntheticReviewDb } from './helpers.js';
import type { ReviewDb } from '../src/db.js';
import type { ReviewStatus } from '@findseries/review-shared';

function statusOf(db: ReviewDb, mediaId: number): ReviewStatus {
  const row = db
    .prepare(`SELECT status FROM media_review_status WHERE project_id=7 AND media_id=?`)
    .get(mediaId) as { status: ReviewStatus } | undefined;
  return row?.status ?? 'unreviewed';
}

describe('FRV-25 multi-batch undo sequences', () => {
  let db: ReviewDb;
  let cleanup: () => void;

  before(() => {
    const ctx = createSyntheticReviewDb();
    db = ctx.db;
    cleanup = ctx.cleanup;
  });

  after(() => cleanup());

  it('1: A -> Undo A restores unreviewed', () => {
    const mediaId = 50;
    const a = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [mediaId],
      protectKeep: true,
      source: 'test',
    });
    assert.equal(statusOf(db, mediaId), 'keep');
    const u = undoBatch(db, { projectId: 7, batchId: a.batchId });
    assert.equal(u.restoredCount, 1);
    assert.equal(statusOf(db, mediaId), 'unreviewed');
  });

  it('2: A -> B -> Undo B -> Undo A', () => {
    const mediaId = 51;
    const a = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [mediaId],
      protectKeep: true,
      source: 'test',
    });
    const b = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'unsure',
      mediaIds: [mediaId],
      protectKeep: false,
      source: 'test',
    });
    assert.equal(statusOf(db, mediaId), 'unsure');
    const ub = undoBatch(db, { projectId: 7, batchId: b.batchId });
    assert.equal(ub.restoredCount, 1);
    assert.equal(statusOf(db, mediaId), 'keep');
    const ua = undoBatch(db, { projectId: 7, batchId: a.batchId });
    assert.equal(ua.restoredCount, 1);
    assert.equal(ua.skippedProtectedCount, 0);
    assert.equal(statusOf(db, mediaId), 'unreviewed');
  });

  it('3: A -> B -> C -> Undo C -> Undo B -> Undo A', () => {
    const mediaId = 52;
    const a = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [mediaId],
      protectKeep: true,
      source: 'test',
    });
    const b = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'unsure',
      mediaIds: [mediaId],
      protectKeep: false,
      source: 'test',
    });
    const c = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [mediaId],
      protectKeep: true,
      source: 'test',
    });
    assert.equal(statusOf(db, mediaId), 'reject');
    assert.equal(undoBatch(db, { projectId: 7, batchId: c.batchId }).restoredCount, 1);
    assert.equal(statusOf(db, mediaId), 'unsure');
    assert.equal(undoBatch(db, { projectId: 7, batchId: b.batchId }).restoredCount, 1);
    assert.equal(statusOf(db, mediaId), 'keep');
    assert.equal(undoBatch(db, { projectId: 7, batchId: a.batchId }).restoredCount, 1);
    assert.equal(statusOf(db, mediaId), 'unreviewed');
  });

  it('4: A -> B; Undo A before Undo B stays protected', () => {
    const mediaId = 53;
    const a = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [mediaId],
      protectKeep: true,
      source: 'test',
    });
    applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'unsure',
      mediaIds: [mediaId],
      protectKeep: false,
      source: 'test',
    });
    const ua = undoBatch(db, { projectId: 7, batchId: a.batchId });
    assert.equal(ua.restoredCount, 0);
    assert.equal(ua.skippedProtectedCount, 1);
    assert.equal(statusOf(db, mediaId), 'unsure');
  });

  it('5: sparse reset in A→B→UndoB→UndoA', () => {
    const mediaId = 54;
    const a = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [mediaId],
      protectKeep: true,
      source: 'test',
    });
    const b = applyBulk(db, {
      projectId: 7,
      action: 'reset_unreviewed',
      mediaIds: [mediaId],
      protectKeep: false,
      source: 'test',
    });
    assert.equal(statusOf(db, mediaId), 'unreviewed');
    assert.equal(undoBatch(db, { projectId: 7, batchId: b.batchId }).restoredCount, 1);
    assert.equal(statusOf(db, mediaId), 'keep');
    assert.equal(undoBatch(db, { projectId: 7, batchId: a.batchId }).restoredCount, 1);
    assert.equal(statusOf(db, mediaId), 'unreviewed');
  });

  it('6: same media in multiple batches chain', () => {
    const mediaId = 55;
    const a = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [mediaId],
      protectKeep: true,
      source: 'test',
    });
    const b = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [mediaId],
      protectKeep: true,
      source: 'test',
    });
    undoBatch(db, { projectId: 7, batchId: b.batchId });
    undoBatch(db, { projectId: 7, batchId: a.batchId });
    assert.equal(statusOf(db, mediaId), 'unreviewed');
  });

  it('7: different media in multiple batches undo independently', () => {
    const a = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'keep',
      mediaIds: [56],
      protectKeep: true,
      source: 'test',
    });
    const b = applyBulk(db, {
      projectId: 7,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: [57],
      protectKeep: true,
      source: 'test',
    });
    // Undo A first while B still active on different media — should succeed
    const ua = undoBatch(db, { projectId: 7, batchId: a.batchId });
    assert.equal(ua.restoredCount, 1);
    assert.equal(statusOf(db, 56), 'unreviewed');
    assert.equal(statusOf(db, 57), 'reject');
    const ub = undoBatch(db, { projectId: 7, batchId: b.batchId });
    assert.equal(ub.restoredCount, 1);
    assert.equal(statusOf(db, 57), 'unreviewed');
  });
});
