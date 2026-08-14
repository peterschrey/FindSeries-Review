import { z } from 'zod';

export const ReviewStatusSchema = z.enum(['unreviewed', 'keep', 'reject', 'unsure']);
export type ReviewStatus = z.infer<typeof ReviewStatusSchema>;

export const SortFieldSchema = z.enum([
  'media_id',
  'title',
  'uploader',
  'timestamp',
  'score',
]);
export type SortField = z.infer<typeof SortFieldSchema>;

export const SortDirSchema = z.enum(['asc', 'desc']);
export type SortDir = z.infer<typeof SortDirSchema>;

export const GroupBySchema = z.enum([
  'provenance',
  'category',
  'series',
  'uploader',
]);
export type GroupBy = z.infer<typeof GroupBySchema>;

/** Shared filter used by gallery, groups, facets, bulk. */
export const MediaFilterSchema = z.object({
  projectId: z.number().int().positive(),
  statuses: z.array(ReviewStatusSchema).default(['unreviewed', 'unsure']),
  q: z.string().optional(),
  sourceTypes: z.array(z.string()).optional(),
  /** Category roots; subtree + fallback semantics from CATEGORY_GRAPH.md */
  categoryIds: z.array(z.number().int().positive()).optional(),
  uploader: z.string().optional(),
  seriesKey: z.string().optional(),
  seriesStrategy: z.string().optional(),
  seedKey: z.string().optional(),
  parentMediaId: z.number().int().positive().optional(),
  mediaIds: z.array(z.number().int().positive()).optional(),
});
export type MediaFilter = z.infer<typeof MediaFilterSchema>;

export const StatusCountsSchema = z.object({
  unreviewed: z.number().int().nonnegative(),
  keep: z.number().int().nonnegative(),
  reject: z.number().int().nonnegative(),
  unsure: z.number().int().nonnegative(),
  total: z.number().int().nonnegative(),
});
export type StatusCounts = z.infer<typeof StatusCountsSchema>;

export const MediaCardSchema = z.object({
  mediaId: z.number().int(),
  title: z.string().nullable(),
  uploader: z.string().nullable(),
  timestamp: z.string().nullable(),
  score: z.number().nullable(),
  reviewStatus: ReviewStatusSchema,
  localPath: z.string().nullable().optional(),
  thumbKey: z.string().optional(),
});
export type MediaCard = z.infer<typeof MediaCardSchema>;

export const GalleryQuerySchema = MediaFilterSchema.extend({
  limit: z.number().int().min(1).max(500).default(100),
  cursor: z.string().nullable().optional(),
  sort: SortFieldSchema.default('media_id'),
  dir: SortDirSchema.default('asc'),
});
export type GalleryQuery = z.infer<typeof GalleryQuerySchema>;

export const GalleryResponseSchema = z.object({
  items: z.array(MediaCardSchema),
  nextCursor: z.string().nullable(),
  total: z.number().int().nonnegative(),
  statusCounts: StatusCountsSchema,
});
export type GalleryResponse = z.infer<typeof GalleryResponseSchema>;

export const GroupQuerySchema = MediaFilterSchema.extend({
  groupBy: GroupBySchema,
  limit: z.number().int().min(1).max(200).default(50),
  sampleSize: z.number().int().min(0).max(12).default(4),
});
export type GroupQuery = z.infer<typeof GroupQuerySchema>;

export const GroupCardSchema = z.object({
  key: z.string(),
  label: z.string(),
  total: z.number().int().nonnegative(),
  statusCounts: StatusCountsSchema,
  sampleMedia: z.array(MediaCardSchema),
  drilldown: MediaFilterSchema.partial().extend({ projectId: z.number().int().positive() }),
});
export type GroupCard = z.infer<typeof GroupCardSchema>;

export const GroupsResponseSchema = z.object({
  groups: z.array(GroupCardSchema),
  resultTotal: z.number().int().nonnegative(),
  statusCounts: StatusCountsSchema,
});
export type GroupsResponse = z.infer<typeof GroupsResponseSchema>;

export const CategoryNodeQuerySchema = z.object({
  projectId: z.number().int().positive(),
  parentCategoryId: z.number().int().positive().nullable().optional(),
  /** Optional filter context for counts */
  filter: MediaFilterSchema.omit({ projectId: true, categoryIds: true }).partial().optional(),
});
export type CategoryNodeQuery = z.infer<typeof CategoryNodeQuerySchema>;

export const CategoryNodeSchema = z.object({
  categoryId: z.number().int(),
  title: z.string(),
  depth: z.number().int(),
  childCount: z.number().int(),
  memberCountCached: z.number().int().nullable(),
  mediaCount: z.number().int().nonnegative().optional(),
  hasChildren: z.boolean(),
});
export type CategoryNode = z.infer<typeof CategoryNodeSchema>;

export const FacetsResponseSchema = z.object({
  provenance: z.array(z.object({
    sourceType: z.string(),
    family: z.string(),
    count: z.number().int().nonnegative(),
  })),
  uploaders: z.array(z.object({
    uploader: z.string(),
    count: z.number().int().nonnegative(),
  })),
});
export type FacetsResponse = z.infer<typeof FacetsResponseSchema>;

export const FocusQuerySchema = z.object({
  projectId: z.number().int().positive(),
  focusMediaId: z.number().int().positive(),
  /** Preserve global filter when deriving focus cards */
  baseFilter: MediaFilterSchema.omit({ projectId: true }).partial().optional(),
});
export type FocusQuery = z.infer<typeof FocusQuerySchema>;

export const FocusRelationSchema = z.object({
  kind: z.enum(['similar', 'series', 'category', 'seed', 'uploader', 'provenance']),
  label: z.string(),
  total: z.number().int().nonnegative(),
  statusCounts: StatusCountsSchema,
  filter: MediaFilterSchema,
  note: z.string().optional(),
});
export type FocusRelation = z.infer<typeof FocusRelationSchema>;

export const FocusResponseSchema = z.object({
  focusMediaId: z.number().int(),
  relations: z.array(FocusRelationSchema),
});
export type FocusResponse = z.infer<typeof FocusResponseSchema>;

export const BulkActionSchema = z.enum([
  'set_status',
  'reset_unreviewed',
]);
export type BulkAction = z.infer<typeof BulkActionSchema>;

export const BulkRequestSchema = z.object({
  projectId: z.number().int().positive(),
  action: BulkActionSchema,
  targetStatus: ReviewStatusSchema.optional(),
  /** Selection modes */
  mediaIds: z.array(z.number().int().positive()).optional(),
  filter: MediaFilterSchema.omit({ projectId: true }).partial().optional(),
  protectKeep: z.boolean().default(true),
  source: z.string().default('api'),
  sessionId: z.string().optional(),
});
export type BulkRequest = z.infer<typeof BulkRequestSchema>;

export const BulkResponseSchema = z.object({
  batchId: z.string(),
  targetStatus: ReviewStatusSchema.nullable(),
  mediaCount: z.number().int().nonnegative(),
  changedCount: z.number().int().nonnegative(),
  protectedCount: z.number().int().nonnegative(),
  skippedCount: z.number().int().nonnegative(),
});
export type BulkResponse = z.infer<typeof BulkResponseSchema>;

export const UndoRequestSchema = z.object({
  projectId: z.number().int().positive(),
  batchId: z.string().optional(),
  sessionId: z.string().optional(),
});
export type UndoRequest = z.infer<typeof UndoRequestSchema>;

export const UndoResponseSchema = z.object({
  batchId: z.string(),
  restoredCount: z.number().int().nonnegative(),
  skippedProtectedCount: z.number().int().nonnegative(),
});
export type UndoResponse = z.infer<typeof UndoResponseSchema>;

export const FinalizePreviewRequestSchema = z.object({
  projectId: z.number().int().positive(),
  limit: z.number().int().min(1).max(1000).default(100),
});
export type FinalizePreviewRequest = z.infer<typeof FinalizePreviewRequestSchema>;

export const FinalizeItemSchema = z.object({
  mediaId: z.number().int(),
  title: z.string().nullable(),
  localPath: z.string().nullable(),
  fileExists: z.boolean().nullable(),
  reviewStatus: ReviewStatusSchema,
});
export type FinalizeItem = z.infer<typeof FinalizeItemSchema>;

export const FinalizePreviewResponseSchema = z.object({
  candidateCount: z.number().int().nonnegative(),
  withPath: z.number().int().nonnegative(),
  missingPath: z.number().int().nonnegative(),
  sample: z.array(FinalizeItemSchema),
});
export type FinalizePreviewResponse = z.infer<typeof FinalizePreviewResponseSchema>;

export const FinalizeCommitRequestSchema = z.object({
  projectId: z.number().int().positive(),
  confirm: z.literal(true),
  dryRun: z.boolean().default(false),
  deleteFiles: z.boolean().default(true),
  maxItems: z.number().int().min(1).max(50000).default(1000),
});
export type FinalizeCommitRequest = z.infer<typeof FinalizeCommitRequestSchema>;

export const FinalizeCommitResponseSchema = z.object({
  dryRun: z.boolean(),
  attempted: z.number().int().nonnegative(),
  deletedFiles: z.number().int().nonnegative(),
  missingFiles: z.number().int().nonnegative(),
  lockedOrError: z.number().int().nonnegative(),
  dbMarked: z.number().int().nonnegative(),
  logPath: z.string().nullable(),
});
export type FinalizeCommitResponse = z.infer<typeof FinalizeCommitResponseSchema>;
