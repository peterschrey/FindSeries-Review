/**
 * FRV-38 Thumbnail DoD bench.
 * Prefer real paths under REVIEW_MEDIA_ROOTS; fall back to synthetic fixtures.
 *
 *   npm run bench:thumbs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { buildServer } from '../src/server.js';
import { openReviewDb } from '../src/db.js';
import { createSyntheticReviewDb } from '../tests/helpers.js';
import {
  DEFAULT_GATE_DB,
  DEFAULT_MEDIA_ROOTS,
  DEFAULT_PROJECT_ID,
  benchDocDir,
  ensureBenchDir,
  fmtMs,
  measureSync,
  stats,
  timedMsAsync,
  writeCsv,
} from './bench-shared.js';

const MAX_N = Number(process.env.REVIEW_THUMB_N ?? 1000);
const SIZE = Number(process.env.REVIEW_THUMB_SIZE ?? 80);

type Mode = 'real' | 'synthetic';

async function makeJpeg(filePath: string, seed: number): Promise<void> {
  const buf = await sharp({
    create: {
      width: 64,
      height: 64,
      channels: 3,
      background: { r: (seed * 37) % 200, g: (seed * 17) % 200, b: (seed * 53) % 200 },
    },
  })
    .jpeg()
    .toBuffer();
  fs.writeFileSync(filePath, buf);
}

async function resolveTargets(): Promise<{
  mode: Mode;
  mediaIds: number[];
  mediaRoots: string[];
  db: ReturnType<typeof openReviewDb>;
  cleanup: () => void;
  note: string;
}> {
  const gateExists = fs.existsSync(DEFAULT_GATE_DB);
  const roots = DEFAULT_MEDIA_ROOTS.filter((r) => fs.existsSync(r));

  if (gateExists && roots.length) {
    const db = openReviewDb(DEFAULT_GATE_DB, { readonly: true });
    const rows = db
      .prepare(
        `SELECT d.media_id AS media_id, d.local_path AS local_path
         FROM downloads d
         JOIN project_media pm ON pm.media_id = d.media_id AND pm.project_id = ?
         WHERE d.local_path IS NOT NULL AND d.status = 'done'
         ORDER BY d.media_id
         LIMIT ?`,
      )
      .all(DEFAULT_PROJECT_ID, MAX_N * 3) as Array<{ media_id: number; local_path: string }>;

    const mediaIds: number[] = [];
    for (const r of rows) {
      if (fs.existsSync(r.local_path)) {
        mediaIds.push(r.media_id);
        if (mediaIds.length >= MAX_N) break;
      }
    }

    if (mediaIds.length >= 10) {
      return {
        mode: 'real',
        mediaIds,
        mediaRoots: roots,
        db,
        cleanup: () => db.close(),
        note: `Real downloads under ${roots.join('; ')}; accessible=${mediaIds.length}`,
      };
    }
    db.close();
  }

  // Synthetic fallback (same shape as thumbs.test.ts)
  const created = createSyntheticReviewDb();
  const n = Math.min(MAX_N, 200);
  const mediaIds: number[] = [];
  for (let i = 1; i <= n; i++) {
    const id = 1000 + i;
    const file = path.join(created.filesDir, `syn-${i}.jpg`);
    await makeJpeg(file, i);
    created.db
      .prepare(
        `INSERT OR REPLACE INTO media(id, title, current_uploader, created_at, updated_at)
         VALUES (?, ?, 'bench', '2026-08-15T00:00:00.000Z', '2026-08-15T00:00:00.000Z')`,
      )
      .run(id, `syn-${i}.jpg`);
    created.db
      .prepare(
        `INSERT OR REPLACE INTO project_media(project_id, media_id, score, selected, download_requested, first_seen_at, updated_at)
         VALUES (7, ?, 1, 1, 1, '2026-08-15T00:00:00.000Z', '2026-08-15T00:00:00.000Z')`,
      )
      .run(id);
    created.db
      .prepare(
        `INSERT OR REPLACE INTO downloads(media_id, status, local_path, historical_complete, attempts, created_at, updated_at)
         VALUES (?, 'done', ?, 1, 0, '2026-08-15T00:00:00.000Z', '2026-08-15T00:00:00.000Z')`,
      )
      .run(id, file.replace(/\\/g, '/'));
    mediaIds.push(id);
  }

  return {
    mode: 'synthetic',
    mediaIds,
    mediaRoots: [created.filesDir],
    db: created.db,
    cleanup: created.cleanup,
    note:
      'Originals on gate DB were inaccessible or REVIEW_MEDIA_ROOTS missing — used synthetic JPEG fixtures (thumbs.test.ts style).',
  };
}

async function main() {
  ensureBenchDir();
  const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), 'frv38-thumb-cache-'));
  const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'frv38-finalize-log-'));
  const targets = await resolveTargets();
  const { mediaIds, mediaRoots, db, cleanup, mode, note } = targets;
  console.log(`FRV-38 thumbs mode=${mode} n=${mediaIds.length}`);
  console.log(note);

  const app = await buildServer({
    db,
    finalizeLogDir: logDir,
    deleteRoots: mediaRoots,
    mediaRoots,
    thumbCacheDir: cacheDir,
  });

  // Error placeholder path
  const missing = await app.inject({ method: 'GET', url: '/api/media/999999999/thumb?size=80' });
  const placeholderOk =
    [403, 404].includes(missing.statusCode) &&
    String(missing.headers['content-type'] ?? '').includes('svg');
  console.log(
    `error placeholder: status=${missing.statusCode} content-type=${missing.headers['content-type']} ok=${placeholderOk}`,
  );

  // Cold: empty cache, sequential first N (cap 100 for cold to keep runtime reasonable, then more for rate)
  const coldN = Math.min(mediaIds.length, 100);
  const coldSamples: number[] = [];
  for (let i = 0; i < coldN; i++) {
    const id = mediaIds[i]!;
    const { ms, value } = await timedMsAsync(() =>
      app.inject({ method: 'GET', url: `/api/media/${id}/thumb?size=${SIZE}` }),
    );
    coldSamples.push(ms);
    if (value.statusCode !== 200) {
      console.warn(`cold miss status=${value.statusCode} media=${id}`);
    }
  }
  const cold = stats(coldSamples);
  console.log(`cold cache n=${cold.n} p50=${fmtMs(cold.p50)} p95=${fmtMs(cold.p95)} mean=${fmtMs(cold.mean)}`);

  // Warm: same IDs again
  const warmSamples: number[] = [];
  for (let i = 0; i < coldN; i++) {
    const id = mediaIds[i]!;
    const { ms, value } = await timedMsAsync(() =>
      app.inject({ method: 'GET', url: `/api/media/${id}/thumb?size=${SIZE}` }),
    );
    warmSamples.push(ms);
    if (value.headers['x-thumb-cache'] !== 'HIT') {
      console.warn(`warm expected HIT media=${id} got=${value.headers['x-thumb-cache']}`);
    }
  }
  const warm = stats(warmSamples);
  console.log(`warm cache n=${warm.n} p50=${fmtMs(warm.p50)} p95=${fmtMs(warm.p95)} mean=${fmtMs(warm.mean)}`);

  // Generation rate: clear cache subset, generate remaining up to mediaIds.length
  const rateIds = mediaIds.slice(0, Math.min(mediaIds.length, MAX_N));
  // wipe cache for rate measurement on IDs beyond cold set OR re-generate all after wipe
  for (const f of fs.readdirSync(cacheDir)) {
    fs.unlinkSync(path.join(cacheDir, f));
  }
  const tRate0 = performance.now();
  let ok = 0;
  for (const id of rateIds) {
    const res = await app.inject({ method: 'GET', url: `/api/media/${id}/thumb?size=${SIZE}` });
    if (res.statusCode === 200 && res.headers['content-type'] === 'image/jpeg') ok += 1;
  }
  const rateMs = performance.now() - tRate0;
  const perSec = ok / (rateMs / 1000);
  console.log(`generation rate: ${ok} thumbs in ${fmtMs(rateMs)}ms → ${perSec.toFixed(2)} img/s`);

  // Concurrent queue behavior
  const concIds = mediaIds.slice(0, Math.min(40, mediaIds.length));
  for (const f of fs.readdirSync(cacheDir)) {
    fs.unlinkSync(path.join(cacheDir, f));
  }
  const tConc0 = performance.now();
  const concResults = await Promise.all(
    concIds.map((id) => app.inject({ method: 'GET', url: `/api/media/${id}/thumb?size=${SIZE}` })),
  );
  const concMs = performance.now() - tConc0;
  const concOk = concResults.filter((r) => r.statusCode === 200).length;
  console.log(`concurrent queue: ${concOk}/${concIds.length} ok in ${fmtMs(concMs)}ms (maxConcurrent default=2)`);

  const md = `# FRV-38 Thumbnail Benchmark

**Date:** ${new Date().toISOString()}
**Mode:** ${mode}
**N measured (cold/warm):** ${coldN}
**N generation rate:** ${ok}
**Size:** ${SIZE}px
**Media roots:** ${mediaRoots.join(', ') || '(none)'}

## Note

${note}

## Error placeholder

- status: ${missing.statusCode}
- content-type: ${missing.headers['content-type']}
- SVG "?" placeholder: **${placeholderOk ? 'verified' : 'FAILED'}**

## Latency

| Phase | n | p50 (ms) | p95 (ms) | mean (ms) |
|---|---:|---:|---:|---:|
| Cold cache | ${cold.n} | ${fmtMs(cold.p50)} | ${fmtMs(cold.p95)} | ${fmtMs(cold.mean)} |
| Warm cache | ${warm.n} | ${fmtMs(warm.p50)} | ${fmtMs(warm.p95)} | ${fmtMs(warm.mean)} |

## Throughput

- Generation: **${ok}** images in **${fmtMs(rateMs)} ms** → **${perSec.toFixed(2)} img/s**
- Concurrent (${concIds.length} parallel injects): **${concOk}** ok in **${fmtMs(concMs)} ms**
- Sharp pipeline: not rewritten (no measured breakage)

## Residual

- Disk cache only; no CDN.
- Queue caps concurrency (default 2) — intentional for CPU/IO.
`;

  fs.writeFileSync(path.join(benchDocDir, 'FRV38_THUMBS.md'), md, 'utf8');
  writeCsv(path.join(benchDocDir, 'frv38-thumbs.csv'), ['phase', 'n', 'p50_ms', 'p95_ms', 'mean_ms', 'extra'], [
    { phase: 'cold', n: cold.n, p50_ms: +cold.p50.toFixed(2), p95_ms: +cold.p95.toFixed(2), mean_ms: +cold.mean.toFixed(2), extra: mode },
    { phase: 'warm', n: warm.n, p50_ms: +warm.p50.toFixed(2), p95_ms: +warm.p95.toFixed(2), mean_ms: +warm.mean.toFixed(2), extra: mode },
    { phase: 'generation_rate', n: ok, p50_ms: '', p95_ms: '', mean_ms: +rateMs.toFixed(2), extra: `${perSec.toFixed(2)} img/s` },
    { phase: 'concurrent', n: concOk, p50_ms: '', p95_ms: '', mean_ms: +concMs.toFixed(2), extra: `${concIds.length} parallel` },
    { phase: 'placeholder', n: 1, p50_ms: '', p95_ms: '', mean_ms: '', extra: placeholderOk ? 'ok' : 'fail' },
  ]);

  // silence unused
  void measureSync;

  await app.close();
  cleanup();
  fs.rmSync(cacheDir, { recursive: true, force: true });
  fs.rmSync(logDir, { recursive: true, force: true });
  console.log(`Wrote ${path.join(benchDocDir, 'FRV38_THUMBS.md')}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
