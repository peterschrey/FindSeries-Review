import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import type {
  FinalizeCommitRequest,
  FinalizeCommitResponse,
  FinalizeItem,
  FinalizePreviewRequest,
  FinalizePreviewResponse,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import { utcNow } from '../db.js';

type Candidate = {
  media_id: number;
  title: string | null;
  local_path: string | null;
};

function loadRejectCandidates(db: ReviewDb, projectId: number, limit: number): Candidate[] {
  return db
    .prepare(
      `SELECT pm.media_id AS media_id,
              m.title AS title,
              (
                SELECT d.local_path FROM downloads d
                WHERE d.media_id = pm.media_id
                LIMIT 1
              ) AS local_path
       FROM project_media pm
       JOIN media m ON m.id = pm.media_id
       JOIN media_review_status mrs
         ON mrs.project_id = pm.project_id AND mrs.media_id = pm.media_id
       WHERE pm.project_id = ?
         AND mrs.status = 'reject'
       ORDER BY pm.media_id ASC
       LIMIT ?`,
    )
    .all(projectId, limit) as Candidate[];
}

function fileExists(p: string | null): boolean | null {
  if (!p) return null;
  try {
    return fs.existsSync(p);
  } catch {
    return null;
  }
}

export function previewFinalize(
  db: ReviewDb,
  req: FinalizePreviewRequest,
): FinalizePreviewResponse {
  const countRow = db
    .prepare(
      `SELECT COUNT(*) AS c
       FROM media_review_status
       WHERE project_id = ? AND status = 'reject'`,
    )
    .get(req.projectId) as { c: number };
  const sampleRows = loadRejectCandidates(db, req.projectId, req.limit);
  const sample: FinalizeItem[] = sampleRows.map((r) => ({
    mediaId: r.media_id,
    title: r.title,
    localPath: r.local_path,
    fileExists: fileExists(r.local_path),
    reviewStatus: 'reject',
  }));
  let withPath = 0;
  let missingPath = 0;
  for (const s of sample) {
    if (s.localPath) withPath += 1;
    else missingPath += 1;
  }
  return {
    candidateCount: Number(countRow.c),
    withPath,
    missingPath,
    sample,
  };
}

export function commitFinalize(
  db: ReviewDb,
  req: FinalizeCommitRequest,
  logDir: string,
): FinalizeCommitResponse {
  if (req.confirm !== true) {
    throw new Error('confirm=true required');
  }
  const candidates = loadRejectCandidates(db, req.projectId, req.maxItems);
  const runId = randomUUID();
  const now = utcNow();
  const logPath = path.join(logDir, `finalize-${req.projectId}-${runId}.jsonl`);
  fs.mkdirSync(logDir, { recursive: true });

  let deletedFiles = 0;
  let missingFiles = 0;
  let lockedOrError = 0;
  let dbMarked = 0;
  const lines: string[] = [];

  const insertHistory = db.prepare(
    `INSERT INTO media_review_history(
       project_id, media_id, old_status, new_status, changed_at, source, action, batch_id, details_json
     ) VALUES (?, ?, 'reject', 'reject', ?, 'finalize', ?, ?, ?)`,
  );

  const logHist = (mediaId: number, action: string, entry: Record<string, unknown>) => {
    if (req.dryRun) return;
    insertHistory.run(req.projectId, mediaId, now, action, runId, JSON.stringify(entry));
    dbMarked += 1;
  };

  for (const c of candidates) {
    const entry: Record<string, unknown> = {
      mediaId: c.media_id,
      localPath: c.local_path,
      dryRun: req.dryRun,
      at: now,
    };
    if (!c.local_path) {
      missingFiles += 1;
      entry.result = 'missing_path';
      lines.push(JSON.stringify(entry));
      logHist(c.media_id, 'finalize_missing_path', entry);
      continue;
    }
    const exists = fileExists(c.local_path);
    if (exists === false) {
      missingFiles += 1;
      entry.result = 'file_missing';
      lines.push(JSON.stringify(entry));
      logHist(c.media_id, 'finalize_file_missing', entry);
      continue;
    }
    if (!req.deleteFiles) {
      entry.result = req.dryRun ? 'would_mark' : 'marked_no_delete';
      lines.push(JSON.stringify(entry));
      logHist(c.media_id, 'finalize_no_delete', entry);
      continue;
    }
    if (req.dryRun) {
      entry.result = 'would_delete';
      deletedFiles += 1;
      lines.push(JSON.stringify(entry));
      continue;
    }
    try {
      fs.unlinkSync(c.local_path);
      deletedFiles += 1;
      entry.result = 'deleted';
      lines.push(JSON.stringify(entry));
      logHist(c.media_id, 'finalize_deleted', entry);
    } catch (err) {
      lockedOrError += 1;
      entry.result = 'error';
      entry.error = err instanceof Error ? err.message : String(err);
      lines.push(JSON.stringify(entry));
      logHist(c.media_id, 'finalize_error', entry);
    }
  }

  fs.writeFileSync(logPath, lines.join('\n') + (lines.length ? '\n' : ''), 'utf8');

  return {
    dryRun: req.dryRun,
    attempted: candidates.length,
    deletedFiles,
    missingFiles,
    lockedOrError,
    dbMarked,
    logPath,
  };
}
