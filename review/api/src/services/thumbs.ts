import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import sharp from 'sharp';
import type { ReviewDb } from '../db.js';

export type ThumbOpts = {
  cacheDir: string;
  deleteRoots: string[];
  maxConcurrent?: number;
  size?: number;
};

type QueueItem = {
  resolve: (v: Buffer | null) => void;
  reject: (e: unknown) => void;
  work: () => Promise<Buffer | null>;
};

let active = 0;
const queue: QueueItem[] = [];
const MAX_DEFAULT = 2;

function pump(max: number) {
  while (active < max && queue.length) {
    const item = queue.shift()!;
    active += 1;
    item
      .work()
      .then(item.resolve, item.reject)
      .finally(() => {
        active -= 1;
        pump(max);
      });
  }
}

function enqueue<T>(max: number, work: () => Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    queue.push({
      resolve: resolve as (v: Buffer | null) => void,
      reject,
      work: work as () => Promise<Buffer | null>,
    });
    pump(max);
  });
}

function pathAllowed(raw: string, roots: string[]): string | null {
  if (!roots.length) return null;
  try {
    let resolved = path.resolve(raw);
    try {
      resolved = fs.realpathSync(resolved);
    } catch {
      /* missing file */
    }
    const norm = resolved.replace(/\//g, '\\').toLowerCase();
    for (const root of roots) {
      let rootResolved = path.resolve(root);
      try {
        rootResolved = fs.realpathSync(rootResolved);
      } catch {
        /* keep */
      }
      const rootNorm = rootResolved.replace(/\//g, '\\').toLowerCase();
      const prefix = rootNorm.endsWith('\\') ? rootNorm : rootNorm + '\\';
      if (norm === rootNorm || norm.startsWith(prefix)) return resolved;
    }
    return null;
  } catch {
    return null;
  }
}

function cacheKey(mediaId: number, size: number, mtimeMs: number): string {
  const h = createHash('sha1')
    .update(`${mediaId}|${size}|${mtimeMs}`)
    .digest('hex')
    .slice(0, 16);
  return `${mediaId}-${size}-${h}.jpg`;
}

export function getMediaLocalPath(db: ReviewDb, mediaId: number): string | null {
  const row = db
    .prepare(
      `SELECT local_path FROM downloads WHERE media_id = ? AND local_path IS NOT NULL LIMIT 1`,
    )
    .get(mediaId) as { local_path: string } | undefined;
  return row?.local_path ?? null;
}

export async function getOrCreateThumb(
  db: ReviewDb,
  mediaId: number,
  opts: ThumbOpts,
): Promise<{ buffer: Buffer; cacheHit: boolean } | { error: string }> {
  const size = opts.size ?? 160;
  const max = opts.maxConcurrent ?? MAX_DEFAULT;
  const localPath = getMediaLocalPath(db, mediaId);
  if (!localPath) return { error: 'no_path' };

  const allowed = pathAllowed(localPath, opts.deleteRoots);
  // Prefer deleteRoots as media roots; if empty, refuse (same safety as finalize)
  if (!allowed) {
    // Allow read if file exists under any configured root alias via REVIEW_MEDIA_ROOTS fallback already in deleteRoots
    if (!opts.deleteRoots.length) return { error: 'no_roots' };
    if (!fs.existsSync(localPath)) return { error: 'missing' };
    return { error: 'path_not_allowed' };
  }

  if (!fs.existsSync(allowed)) return { error: 'missing' };

  const st = fs.statSync(allowed);
  const name = cacheKey(mediaId, size, Math.floor(st.mtimeMs));
  const outPath = path.join(opts.cacheDir, name);
  fs.mkdirSync(opts.cacheDir, { recursive: true });

  if (fs.existsSync(outPath)) {
    return { buffer: fs.readFileSync(outPath), cacheHit: true };
  }

  const buffer = await enqueue(max, async () => {
    if (fs.existsSync(outPath)) return fs.readFileSync(outPath);
    const buf = await sharp(allowed)
      .rotate()
      .resize(size, size, { fit: 'cover', withoutEnlargement: true })
      .jpeg({ quality: 72, mozjpeg: true })
      .toBuffer();
    fs.writeFileSync(outPath, buf);
    return buf;
  });

  if (!buffer) return { error: 'generate_failed' };
  return { buffer, cacheHit: false };
}
