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
};

export async function buildServer(opts: BuildServerOpts) {
  const app = Fastify({ logger: false });
  const { db, finalizeLogDir, deleteRoots } = opts;
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
