import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import type {
  FinalizeClass,
  FinalizeCommitRequest,
  FinalizeCommitResponse,
  FinalizeItem,
  FinalizePreviewRequest,
  FinalizePreviewResponse,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import { utcNow } from '../db.js';

export type FinalizeOpts = {
  logDir: string;
  /** Absolute roots allowed for physical deletes. Empty → refuse file deletes. */
  deleteRoots: string[];
};

type SnapshotCandidate = {
  mediaId: number;
  title: string | null;
  localPath: string | null;
  classification: FinalizeClass;
  blockingProjectIds: number[];
  reviewStatus: 'reject';
};

type PreviewSnapshot = {
  previewToken: string;
  projectId: number;
  createdAt: string;
  candidates: SnapshotCandidate[];
  alreadyFinalizedSkipped: number;
};

type Row = {
  media_id: number;
  title: string | null;
  local_path: string | null;
  page_id: number | null;
  sha1: string | null;
  normalized_title: string | null;
};

function snapshotPath(logDir: string, token: string): string {
  return path.join(logDir, `finalize-preview-${token}.json`);
}

function isAlreadyFinalized(db: ReviewDb, mediaId: number): boolean {
  const row = db
    .prepare(`SELECT 1 AS x FROM media_rejections WHERE media_id = ? LIMIT 1`)
    .get(mediaId);
  return Boolean(row);
}

function blockingProjects(db: ReviewDb, mediaId: number): number[] {
  const rows = db
    .prepare(
      `SELECT pm.project_id AS project_id
       FROM project_media pm
       LEFT JOIN media_review_status mrs
         ON mrs.project_id = pm.project_id AND mrs.media_id = pm.media_id
       WHERE pm.media_id = ?
         AND COALESCE(mrs.status, 'unreviewed') <> 'reject'
       ORDER BY pm.project_id`,
    )
    .all(mediaId) as Array<{ project_id: number }>;
  return rows.map((r) => r.project_id);
}

function fileExists(p: string | null): boolean | null {
  if (!p) return null;
  try {
    return fs.existsSync(p);
  } catch {
    return null;
  }
}

/**
 * Resolve path under allowed roots. Uses realpath when possible (junctions).
 * Returns null if outside roots or unresolvable when roots are configured.
 */
export function resolveAllowedDeletePath(
  rawPath: string,
  deleteRoots: string[],
): { ok: true; resolved: string } | { ok: false; reason: 'no_roots' | 'outside' | 'error' } {
  if (!deleteRoots.length) return { ok: false, reason: 'no_roots' };
  try {
    const abs = path.resolve(rawPath);
    let resolved = abs;
    try {
      resolved = fs.realpathSync(abs);
    } catch {
      // File may be missing — still check prefix against resolved roots using abs
      resolved = abs;
    }
    const norm = resolved.replace(/\//g, '\\').toLowerCase();
    for (const root of deleteRoots) {
      let rootResolved = path.resolve(root);
      try {
        rootResolved = fs.realpathSync(rootResolved);
      } catch {
        /* keep resolved */
      }
      const rootNorm = rootResolved.replace(/\//g, '\\').toLowerCase();
      if (norm === rootNorm || norm.startsWith(rootNorm.endsWith('\\') ? rootNorm : rootNorm + '\\')) {
        return { ok: true, resolved };
      }
    }
    return { ok: false, reason: 'outside' };
  } catch {
    return { ok: false, reason: 'error' };
  }
}

function classifyCandidate(
  db: ReviewDb,
  row: Row,
  deleteRoots: string[],
): SnapshotCandidate {
  if (isAlreadyFinalized(db, row.media_id)) {
    return {
      mediaId: row.media_id,
      title: row.title,
      localPath: row.local_path,
      classification: 'already_finalized',
      blockingProjectIds: [],
      reviewStatus: 'reject',
    };
  }
  const blockers = blockingProjects(db, row.media_id);
  if (blockers.length) {
    return {
      mediaId: row.media_id,
      title: row.title,
      localPath: row.local_path,
      classification: 'blocked_by_other_project',
      blockingProjectIds: blockers,
      reviewStatus: 'reject',
    };
  }
  if (!row.local_path) {
    return {
      mediaId: row.media_id,
      title: row.title,
      localPath: null,
      classification: 'missing_path',
      blockingProjectIds: [],
      reviewStatus: 'reject',
    };
  }
  const allowed = resolveAllowedDeletePath(row.local_path, deleteRoots);
  if (!allowed.ok && allowed.reason === 'no_roots') {
    // Still eligible for DB finalization; path_not_allowed only blocks physical delete at commit.
    // Classification for preview: path present but roots missing → path_not_allowed when delete intended.
    return {
      mediaId: row.media_id,
      title: row.title,
      localPath: row.local_path,
      classification: 'path_not_allowed',
      blockingProjectIds: [],
      reviewStatus: 'reject',
    };
  }
  if (!allowed.ok) {
    return {
      mediaId: row.media_id,
      title: row.title,
      localPath: row.local_path,
      classification: 'path_not_allowed',
      blockingProjectIds: [],
      reviewStatus: 'reject',
    };
  }
  const exists = fileExists(row.local_path);
  if (exists === false) {
    return {
      mediaId: row.media_id,
      title: row.title,
      localPath: row.local_path,
      classification: 'missing_file',
      blockingProjectIds: [],
      reviewStatus: 'reject',
    };
  }
  return {
    mediaId: row.media_id,
    title: row.title,
    localPath: row.local_path,
    classification: 'eligible_for_global_finalization',
    blockingProjectIds: [],
    reviewStatus: 'reject',
  };
}

/**
 * Load next project rejects that are NOT already in media_rejections (forward progress).
 * Then classify; eligible requires ALL project memberships = reject.
 */
function loadConsiderationRows(db: ReviewDb, projectId: number, limit: number): {
  rows: Row[];
  skippedFinalized: number;
} {
  // Over-fetch to skip finalized without them occupying the window forever.
  const batch = db
    .prepare(
      `SELECT pm.media_id AS media_id,
              m.title AS title,
              m.page_id AS page_id,
              m.sha1 AS sha1,
              m.normalized_title AS normalized_title,
              (SELECT d.local_path FROM downloads d WHERE d.media_id = pm.media_id LIMIT 1) AS local_path
       FROM project_media pm
       JOIN media m ON m.id = pm.media_id
       JOIN media_review_status mrs
         ON mrs.project_id = pm.project_id AND mrs.media_id = pm.media_id
       WHERE pm.project_id = ?
         AND mrs.status = 'reject'
         AND NOT EXISTS (SELECT 1 FROM media_rejections r WHERE r.media_id = pm.media_id)
       ORDER BY pm.media_id ASC
       LIMIT ?`,
    )
    .all(projectId, limit) as Row[];

  // Count how many finalized rejects exist that would have blocked early pages.
  const skipped = (
    db
      .prepare(
        `SELECT COUNT(*) AS c
         FROM media_review_status mrs
         JOIN media_rejections r ON r.media_id = mrs.media_id
         WHERE mrs.project_id = ? AND mrs.status = 'reject'`,
      )
      .get(projectId) as { c: number }
  ).c;

  return { rows: batch, skippedFinalized: Number(skipped) };
}

export function previewFinalize(
  db: ReviewDb,
  req: FinalizePreviewRequest,
  opts: FinalizeOpts,
): FinalizePreviewResponse {
  fs.mkdirSync(opts.logDir, { recursive: true });
  const { rows, skippedFinalized } = loadConsiderationRows(db, req.projectId, req.limit);
  const candidates = rows.map((r) => classifyCandidate(db, r, opts.deleteRoots));
  const previewToken = randomUUID();
  const snapshot: PreviewSnapshot = {
    previewToken,
    projectId: req.projectId,
    createdAt: utcNow(),
    candidates,
    alreadyFinalizedSkipped: skippedFinalized,
  };
  fs.writeFileSync(snapshotPath(opts.logDir, previewToken), JSON.stringify(snapshot, null, 2), 'utf8');

  const eligibleCount = candidates.filter(
    (c) => c.classification === 'eligible_for_global_finalization',
  ).length;
  const blockedCount = candidates.length - eligibleCount;

  const sample: FinalizeItem[] = candidates.map((c) => ({
    mediaId: c.mediaId,
    title: c.title,
    localPath: c.localPath,
    fileExists: fileExists(c.localPath),
    reviewStatus: 'reject',
    classification: c.classification,
    blockingProjectIds: c.blockingProjectIds,
  }));

  return {
    previewToken,
    projectId: req.projectId,
    consideredCount: candidates.length,
    eligibleCount,
    blockedCount,
    alreadyFinalizedSkipped: skippedFinalized,
    sample,
  };
}

function loadSnapshot(logDir: string, token: string, projectId: number): PreviewSnapshot {
  const p = snapshotPath(logDir, token);
  if (!fs.existsSync(p)) {
    const err = new Error('Unknown or expired previewToken') as Error & { statusCode: number };
    err.statusCode = 400;
    throw err;
  }
  const snap = JSON.parse(fs.readFileSync(p, 'utf8')) as PreviewSnapshot;
  if (snap.projectId !== projectId || snap.previewToken !== token) {
    const err = new Error('previewToken/projectId mismatch') as Error & { statusCode: number };
    err.statusCode = 400;
    throw err;
  }
  return snap;
}

function applyGlobalRejectionDb(
  db: ReviewDb,
  mediaId: number,
  meta: { page_id: number | null; sha1: string | null; normalized_title: string | null },
  now: string,
  reviewPath: string | null,
): void {
  const reason = 'Global verworfen: Review-MVP Finalisierung';
  const source = 'review-mvp-finalize';
  db.prepare(
    `INSERT OR IGNORE INTO media_rejections(media_id, reason, source, review_path, rejected_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  ).run(mediaId, reason, source, reviewPath, now, now);
  if (meta.page_id != null && Number(meta.page_id) > 0) {
    db.prepare(
      `INSERT OR IGNORE INTO media_rejections(page_id, reason, source, review_path, rejected_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(meta.page_id, reason, source, reviewPath, now, now);
  }
  if (meta.sha1) {
    db.prepare(
      `INSERT OR IGNORE INTO media_rejections(sha1, reason, source, review_path, rejected_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(meta.sha1, reason, source, reviewPath, now, now);
  }
  if (meta.normalized_title) {
    db.prepare(
      `INSERT OR IGNORE INTO media_rejections(normalized_title, reason, source, review_path, rejected_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(meta.normalized_title, reason, source, reviewPath, now, now);
  }

  const errMsg = 'Global verworfen: Review-MVP Finalisierung';
  db.prepare(
    `UPDATE project_media
     SET selected=0, download_requested=0, updated_at=?
     WHERE media_id=?`,
  ).run(now, mediaId);
  db.prepare(
    `UPDATE project_downloads
     SET status='skipped', lease_owner=NULL, lease_until=NULL, last_error=?, updated_at=?
     WHERE media_id=?`,
  ).run(errMsg, now, mediaId);
  db.prepare(
    `UPDATE downloads
     SET status='rejected', historical_complete=1, lease_owner=NULL, lease_until=NULL,
         last_error=?, updated_at=?
     WHERE media_id=?`,
  ).run(errMsg, now, mediaId);
  db.prepare(
    `UPDATE review_exports
     SET status='rejected', rejected_at=?, last_seen_at=?
     WHERE media_id=?`,
  ).run(now, now, mediaId);
}

/**
 * Safe order (documented):
 * 1) Persist media_rejections + core status updates (prevents re-download)
 * 2) Attempt physical delete only for allowed roots
 * 3) On unlink failure: keep rejection; log for reconcile (orphan file safer than missing rejection)
 */
export function commitFinalize(
  db: ReviewDb,
  req: FinalizeCommitRequest,
  opts: FinalizeOpts,
): FinalizeCommitResponse {
  if (req.confirm !== true) {
    throw new Error('confirm=true required');
  }
  const snap = loadSnapshot(opts.logDir, req.previewToken, req.projectId);
  const now = utcNow();
  const runId = randomUUID();
  const logPath = path.join(opts.logDir, `finalize-commit-${req.projectId}-${runId}.jsonl`);
  fs.mkdirSync(opts.logDir, { recursive: true });

  let rejectedDb = 0;
  let deletedFiles = 0;
  let missingFiles = 0;
  let pathNotAllowed = 0;
  let lockedOrError = 0;
  let skippedNonEligible = 0;
  let alreadyFinalized = 0;
  let eligibleAttempted = 0;
  const lines: string[] = [];

  const metaStmt = db.prepare(
    `SELECT page_id, sha1, normalized_title FROM media WHERE id = ?`,
  );

  for (const c of snap.candidates) {
    const entry: Record<string, unknown> = {
      mediaId: c.mediaId,
      localPath: c.localPath,
      classification: c.classification,
      dryRun: req.dryRun,
      at: now,
    };

    // Re-classify at commit time (membership may have changed).
    const live = classifyCandidate(
      db,
      {
        media_id: c.mediaId,
        title: c.title,
        local_path: c.localPath,
        page_id: null,
        sha1: null,
        normalized_title: null,
      },
      opts.deleteRoots,
    );
    // Refresh meta for DB writes
    const meta = metaStmt.get(c.mediaId) as {
      page_id: number | null;
      sha1: string | null;
      normalized_title: string | null;
    };

    if (live.classification === 'already_finalized') {
      alreadyFinalized += 1;
      entry.result = 'already_finalized';
      lines.push(JSON.stringify(entry));
      continue;
    }
    if (live.classification === 'blocked_by_other_project') {
      skippedNonEligible += 1;
      entry.result = 'blocked_by_other_project';
      entry.blockingProjectIds = live.blockingProjectIds;
      lines.push(JSON.stringify(entry));
      continue;
    }

    // Eligible for DB finalization: eligible, missing_path, missing_file, path_not_allowed
    // (all require all-projects reject; physical delete only if eligible + allowed)
    const dbEligible = [
      'eligible_for_global_finalization',
      'missing_path',
      'missing_file',
      'path_not_allowed',
    ].includes(live.classification);
    if (!dbEligible) {
      skippedNonEligible += 1;
      entry.result = live.classification;
      lines.push(JSON.stringify(entry));
      continue;
    }

    eligibleAttempted += 1;

    if (req.dryRun) {
      entry.result = 'would_finalize';
      if (req.deleteFiles && live.classification === 'eligible_for_global_finalization') {
        entry.wouldDelete = true;
        deletedFiles += 1;
      }
      lines.push(JSON.stringify(entry));
      continue;
    }

    // 1) DB rejection first
    const tx = db.transaction(() => {
      applyGlobalRejectionDb(db, c.mediaId, meta, now, c.localPath);
      db.prepare(
        `INSERT INTO media_review_history(
           project_id, media_id, old_status, new_status, changed_at, source, action, batch_id, details_json
         ) VALUES (?, ?, 'reject', 'reject', ?, 'finalize', 'finalize_commit', ?, ?)`,
      ).run(req.projectId, c.mediaId, now, runId, JSON.stringify(entry));
    });
    tx();
    rejectedDb += 1;
    entry.dbRejected = true;

    if (!req.deleteFiles) {
      entry.result = 'db_finalized_no_delete';
      lines.push(JSON.stringify(entry));
      continue;
    }

    if (!c.localPath) {
      missingFiles += 1;
      entry.result = 'db_finalized_missing_path';
      lines.push(JSON.stringify(entry));
      continue;
    }

    const allowed = resolveAllowedDeletePath(c.localPath, opts.deleteRoots);
    if (!allowed.ok) {
      pathNotAllowed += 1;
      entry.result = 'db_finalized_path_not_allowed';
      entry.pathReason = allowed.reason;
      lines.push(JSON.stringify(entry));
      continue;
    }

    if (!fileExists(allowed.resolved)) {
      missingFiles += 1;
      // Clear local_path after rejection
      db.prepare(`UPDATE downloads SET local_path=NULL, updated_at=? WHERE media_id=?`).run(
        now,
        c.mediaId,
      );
      entry.result = 'db_finalized_file_missing';
      lines.push(JSON.stringify(entry));
      continue;
    }

    try {
      fs.unlinkSync(allowed.resolved);
      deletedFiles += 1;
      db.prepare(`UPDATE downloads SET local_path=NULL, updated_at=? WHERE media_id=?`).run(
        now,
        c.mediaId,
      );
      entry.result = 'db_finalized_deleted';
      lines.push(JSON.stringify(entry));
    } catch (err) {
      lockedOrError += 1;
      entry.result = 'db_finalized_unlink_error';
      entry.error = err instanceof Error ? err.message : String(err);
      entry.reconcile = 'file_may_remain_rejection_set';
      lines.push(JSON.stringify(entry));
    }
  }

  fs.writeFileSync(logPath, lines.join('\n') + (lines.length ? '\n' : ''), 'utf8');

  return {
    dryRun: req.dryRun,
    previewToken: req.previewToken,
    attempted: snap.candidates.length,
    eligibleAttempted,
    rejectedDb,
    deletedFiles,
    missingFiles,
    pathNotAllowed,
    lockedOrError,
    skippedNonEligible,
    alreadyFinalized,
    logPath,
  };
}
