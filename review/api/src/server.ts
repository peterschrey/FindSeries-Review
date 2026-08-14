import path from 'node:path';
import Fastify from 'fastify';
import type { ZodTypeAny } from 'zod';
import {
  BulkRequestSchema,
  CategoryNodeQuerySchema,
  FinalizeCommitRequestSchema,
  FinalizePreviewRequestSchema,
  FocusQuerySchema,
  GalleryQuerySchema,
  GroupQuerySchema,
  MediaFilterSchema,
  UndoRequestSchema,
} from '@findseries/review-shared';
import type { ReviewDb } from './db.js';
import { queryGallery } from './services/gallery.js';
import { queryGroups } from './services/groups.js';
import { listCategoryNodes, queryFacets } from './services/categories.js';
import { queryFocus } from './services/focus.js';
import { applyBulk, undoBatch } from './services/bulk.js';
import { commitFinalize, previewFinalize } from './services/finalize.js';
import { getOrCreateThumb } from './services/thumbs.js';
import { CursorError } from './sql/filters.js';

function parseBody<T>(schema: ZodTypeAny, body: unknown): T {
  const r = schema.safeParse(body);
  if (!r.success) {
    const err = new Error(r.error.message) as Error & { statusCode: number };
    err.statusCode = 400;
    throw err;
  }
  return r.data as T;
}

function errMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export type BuildServerOpts = {
  db: ReviewDb;
  finalizeLogDir: string;
  deleteRoots: string[];
  mediaRoots?: string[];
  thumbCacheDir?: string;
};

export async function buildServer(opts: BuildServerOpts) {
  const app = Fastify({ logger: false });
  const { db, finalizeLogDir, deleteRoots } = opts;
  const mediaRoots = opts.mediaRoots?.length ? opts.mediaRoots : deleteRoots;
  const thumbCacheDir =
    opts.thumbCacheDir ?? path.resolve(finalizeLogDir, '..', 'thumb-cache');
  const finalizeOpts = { logDir: finalizeLogDir, deleteRoots };

  app.setErrorHandler((err, _req, reply) => {
    const status =
      err instanceof CursorError
        ? 400
        : ((err as { statusCode?: number }).statusCode ?? 500);
    reply.status(status).send({
      error: errMessage(err),
      statusCode: status,
    });
  });

  app.get('/health', async () => ({ ok: true }));

  app.get<{ Params: { mediaId: string }; Querystring: { size?: string } }>(
    '/api/media/:mediaId/thumb',
    async (req, reply) => {
      const mediaId = Number(req.params.mediaId);
      if (!Number.isFinite(mediaId) || mediaId <= 0) {
        return reply.status(400).send({ error: 'invalid mediaId' });
      }
      const sizeRaw = Number(req.query.size ?? 160);
      const size = Number.isFinite(sizeRaw) ? Math.min(320, Math.max(64, sizeRaw)) : 160;
      const result = await getOrCreateThumb(db, mediaId, {
        cacheDir: thumbCacheDir,
        deleteRoots: mediaRoots,
        size,
      });
      if ('error' in result) {
        return reply
          .status(result.error === 'missing' || result.error === 'no_path' ? 404 : 403)
          .type('image/svg+xml')
          .send(
            `<svg xmlns="http://www.w3.org/2000/svg" width="160" height="160"><rect width="100%" height="100%" fill="#18222d"/><text x="50%" y="50%" fill="#92a3b8" text-anchor="middle" dy=".3em" font-size="12">?</text></svg>`,
          );
      }
      reply.header('X-Thumb-Cache', result.cacheHit ? 'HIT' : 'MISS');
      reply.header('Cache-Control', 'public, max-age=86400');
      return reply.type('image/jpeg').send(result.buffer);
    },
  );

  app.post('/api/gallery/query', async (req) => {
    const q = parseBody<ReturnType<typeof GalleryQuerySchema.parse>>(GalleryQuerySchema, req.body);
    return queryGallery(db, q);
  });

  app.post('/api/groups/query', async (req) => {
    const q = parseBody<ReturnType<typeof GroupQuerySchema.parse>>(GroupQuerySchema, req.body);
    return queryGroups(db, q);
  });

  app.post('/api/categories/nodes', async (req) => {
    const q = parseBody<ReturnType<typeof CategoryNodeQuerySchema.parse>>(
      CategoryNodeQuerySchema,
      req.body,
    );
    return { nodes: listCategoryNodes(db, q) };
  });

  app.post('/api/facets/query', async (req) => {
    const q = parseBody<ReturnType<typeof MediaFilterSchema.parse>>(MediaFilterSchema, req.body);
    return queryFacets(db, q);
  });

  app.post('/api/focus/query', async (req) => {
    const q = parseBody<ReturnType<typeof FocusQuerySchema.parse>>(FocusQuerySchema, req.body);
    return queryFocus(db, q);
  });

  app.post('/api/review/bulk', async (req) => {
    const q = parseBody<ReturnType<typeof BulkRequestSchema.parse>>(BulkRequestSchema, req.body);
    return applyBulk(db, q);
  });

  app.post('/api/review/undo', async (req) => {
    const q = parseBody<ReturnType<typeof UndoRequestSchema.parse>>(UndoRequestSchema, req.body);
    return undoBatch(db, q);
  });

  app.post('/api/finalize/preview', async (req) => {
    const q = parseBody<ReturnType<typeof FinalizePreviewRequestSchema.parse>>(
      FinalizePreviewRequestSchema,
      req.body,
    );
    return previewFinalize(db, q, finalizeOpts);
  });

  app.post('/api/finalize/commit', async (req) => {
    const q = parseBody<ReturnType<typeof FinalizeCommitRequestSchema.parse>>(
      FinalizeCommitRequestSchema,
      req.body,
    );
    return commitFinalize(db, q, finalizeOpts);
  });

  return app;
}
