import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, it, before, after } from 'node:test';
import sharp from 'sharp';
import { buildServer } from '../src/server.js';
import { createSyntheticReviewDb } from './helpers.js';

describe('thumb endpoint', () => {
  let db: ReturnType<typeof createSyntheticReviewDb>['db'];
  let filesDir: string;
  let cleanup: () => void;
  let logDir: string;
  let cacheDir: string;

  before(async () => {
    const created = createSyntheticReviewDb();
    db = created.db;
    filesDir = created.filesDir;
    cleanup = created.cleanup;
    logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'finalize-log-'));
    cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), 'thumb-cache-'));
    // Ensure present-1 is a real tiny jpeg for sharp
    const jpg = await sharp({
      create: { width: 32, height: 32, channels: 3, background: { r: 40, g: 80, b: 120 } },
    })
      .jpeg()
      .toBuffer();
    fs.writeFileSync(path.join(filesDir, 'present-1.jpg'), jpg);
  });

  after(() => {
    cleanup();
    fs.rmSync(logDir, { recursive: true, force: true });
    fs.rmSync(cacheDir, { recursive: true, force: true });
  });

  it('cold then warm cache', async () => {
    const app = await buildServer({
      db,
      finalizeLogDir: logDir,
      deleteRoots: [filesDir],
      mediaRoots: [filesDir],
      thumbCacheDir: cacheDir,
    });
    const cold = await app.inject({ method: 'GET', url: '/api/media/1/thumb?size=80' });
    assert.equal(cold.statusCode, 200);
    assert.equal(cold.headers['content-type'], 'image/jpeg');
    assert.equal(cold.headers['x-thumb-cache'], 'MISS');
    const warm = await app.inject({ method: 'GET', url: '/api/media/1/thumb?size=80' });
    assert.equal(warm.statusCode, 200);
    assert.equal(warm.headers['x-thumb-cache'], 'HIT');
    const missing = await app.inject({ method: 'GET', url: '/api/media/2/thumb' });
    assert.ok([403, 404].includes(missing.statusCode));
    await app.close();
  });
});
