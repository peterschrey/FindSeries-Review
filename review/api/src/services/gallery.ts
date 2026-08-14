import type {
  GalleryQuery,
  GalleryResponse,
  MediaCard,
  MediaFilter,
  StatusCounts,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import {
  buildFilteredMediaCte,
  decodeCursor,
  encodeCursor,
  resolveStatuses,
  seekPredicate,
  sortClause,
} from '../sql/filters.js';

function emptyCounts(): StatusCounts {
  return { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 };
}

export function computeStatusCounts(
  db: ReviewDb,
  filter: MediaFilter,
  opts?: { breakdownAllStatuses?: boolean },
): StatusCounts {
  const resolved = resolveStatuses(filter);
  if (resolved === 'empty') return emptyCounts();

  const countFilter: MediaFilter = opts?.breakdownAllStatuses
    ? {
        ...filter,
        statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
      }
    : filter;

  const hasExtra =
    Boolean(countFilter.q?.trim()) ||
    countFilter.uploader !== undefined ||
    countFilter.mediaIds !== undefined ||
    countFilter.sourceTypes !== undefined ||
    countFilter.alsoSourceTypes !== undefined ||
    countFilter.categoryIds !== undefined ||
    countFilter.alsoCategoryIds !== undefined ||
    Boolean(countFilter.seriesKey) ||
    Boolean(countFilter.seedKey) ||
    Boolean(countFilter.parentMediaId);

  // Fast path: project-scoped sparse counts via index on media_review_status.
  // Only when counting all statuses without other filters.
  const countStatuses = resolveStatuses(countFilter);
  if (!hasExtra && countStatuses !== 'empty' && countStatuses.length === 4) {
    const totalPm = (
      db
        .prepare(`SELECT COUNT(*) AS c FROM project_media WHERE project_id = ?`)
        .get(countFilter.projectId) as { c: number }
    ).c;
    const rows = db
      .prepare(
        `SELECT status, COUNT(*) AS c
         FROM media_review_status
         WHERE project_id = ?
         GROUP BY status`,
      )
      .all(countFilter.projectId) as Array<{ status: string; c: number }>;
    const keep = Number(rows.find((r) => r.status === 'keep')?.c ?? 0);
    const reject = Number(rows.find((r) => r.status === 'reject')?.c ?? 0);
    const unsure = Number(rows.find((r) => r.status === 'unsure')?.c ?? 0);
    const unreviewed = Math.max(0, Number(totalPm) - keep - reject - unsure);
    return {
      unreviewed,
      keep,
      reject,
      unsure,
      total: Number(totalPm),
    };
  }

  const base = buildFilteredMediaCte(countFilter, 'count');
  const row = db
    .prepare(
      `WITH fm AS (${base.sql})
       SELECT
         SUM(CASE WHEN review_status='unreviewed' THEN 1 ELSE 0 END) AS unreviewed,
         SUM(CASE WHEN review_status='keep' THEN 1 ELSE 0 END) AS keep,
         SUM(CASE WHEN review_status='reject' THEN 1 ELSE 0 END) AS reject,
         SUM(CASE WHEN review_status='unsure' THEN 1 ELSE 0 END) AS unsure,
         COUNT(*) AS total
       FROM fm`,
    )
    .get(...base.params) as Record<string, number> | undefined;
  if (!row) return emptyCounts();
  return {
    unreviewed: Number(row.unreviewed ?? 0),
    keep: Number(row.keep ?? 0),
    reject: Number(row.reject ?? 0),
    unsure: Number(row.unsure ?? 0),
    total: Number(row.total ?? 0),
  };
}

function mapCard(r: Record<string, unknown>): MediaCard {
  return {
    mediaId: Number(r.media_id),
    title: (r.title as string) ?? null,
    uploader: (r.uploader as string) ?? null,
    timestamp: (r.timestamp as string) ?? null,
    score: r.score == null ? null : Number(r.score),
    reviewStatus: (r.review_status as MediaCard['reviewStatus']) ?? 'unreviewed',
    localPath: (r.local_path as string) ?? null,
    thumbKey: `media:${r.media_id}`,
  };
}

function attachProvenance(
  db: ReviewDb,
  projectId: number,
  items: MediaCard[],
): MediaCard[] {
  if (!items.length) return items;
  const ids = items.map((i) => i.mediaId);
  const placeholders = ids.map(() => '?').join(',');
  const rows = db
    .prepare(
      `SELECT d.media_id AS media_id, d.source_type AS source_type,
              COALESCE(rpm.family, 'unknown') AS family,
              COALESCE(rpm.chip_label, d.source_type) AS chip_label
       FROM discoveries d
       LEFT JOIN review_provenance_type_map rpm ON rpm.source_type = d.source_type
       WHERE d.project_id = ? AND d.media_id IN (${placeholders})
       ORDER BY d.media_id, d.source_type`,
    )
    .all(projectId, ...ids) as Array<{
    media_id: number;
    source_type: string;
    family: string;
    chip_label: string;
  }>;
  const byMedia = new Map<number, MediaCard['provenance']>();
  for (const r of rows) {
    const list = byMedia.get(r.media_id) ?? [];
    if (!list.some((p) => p.sourceType === r.source_type)) {
      list.push({
        sourceType: r.source_type,
        family: r.family,
        chipLabel: r.chip_label,
      });
    }
    byMedia.set(r.media_id, list);
  }
  return items.map((it) => ({
    ...it,
    provenance: byMedia.get(it.mediaId) ?? [],
  }));
}

export function queryGallery(db: ReviewDb, q: GalleryQuery): GalleryResponse {
  const filter: MediaFilter = {
    projectId: q.projectId,
    statuses: q.statuses,
    q: q.q,
    sourceTypes: q.sourceTypes,
    categoryIds: q.categoryIds,
    alsoCategoryIds: q.alsoCategoryIds,
    alsoSourceTypes: q.alsoSourceTypes,
    categoryIncludeDescendants: q.categoryIncludeDescendants,
    alsoCategoryIncludeDescendants: q.alsoCategoryIncludeDescendants,
    uploader: q.uploader,
    seriesKey: q.seriesKey,
    seedKey: q.seedKey,
    parentMediaId: q.parentMediaId,
    mediaIds: q.mediaIds,
  };

  if (resolveStatuses(filter) === 'empty') {
    return { items: [], nextCursor: null, total: 0, statusCounts: emptyCounts() };
  }

  const pageBase =
    q.sort === 'media_id'
      ? buildFilteredMediaCte(filter, 'count')
      : buildFilteredMediaCte(filter, 'page');
  const params = [...pageBase.params];
  // Natural series order when drilling a series key
  let order = sortClause(q.sort, q.dir);
  let seriesJoin = '';
  if (filter.seriesKey && q.sort === 'media_id') {
    seriesJoin = `LEFT JOIN media_series_keys msk
      ON msk.project_id = ?
     AND msk.media_id = fm.media_id
     AND msk.series_key = ?
     AND msk.is_primary = 1`;
    params.push(filter.projectId, filter.seriesKey);
    order = `COALESCE(msk.sequence_no, fm.media_id) ASC, fm.media_id ASC`;
  }
  let seekSql = '';
  if (q.cursor) {
    const c = decodeCursor(q.cursor, { sort: q.sort, dir: q.dir });
    const pred = seekPredicate(c);
    seekSql = `WHERE ${pred.sql}`;
    params.push(...pred.params);
  }
  const idRows = db
    .prepare(
      `WITH fm AS (${pageBase.sql})
       SELECT fm.media_id AS media_id FROM fm
       ${seriesJoin}
       ${seekSql}
       ORDER BY ${order}
       LIMIT ?`,
    )
    .all(...params, q.limit + 1) as Array<{ media_id: number }>;

  const hasMore = idRows.length > q.limit;
  const pageIds = (hasMore ? idRows.slice(0, q.limit) : idRows).map((r) => r.media_id);

  let items: MediaCard[] = [];
  if (pageIds.length) {
    const placeholders = pageIds.map(() => '?').join(',');
    const hydrated = db
      .prepare(
        `SELECT
           pm.media_id AS media_id,
           m.title AS title,
           m.current_uploader AS uploader,
           m.current_timestamp AS timestamp,
           pm.score AS score,
           COALESCE(mrs.status, 'unreviewed') AS review_status,
           (SELECT d.local_path FROM downloads d WHERE d.media_id = pm.media_id LIMIT 1) AS local_path
         FROM project_media pm
         JOIN media m ON m.id = pm.media_id
         LEFT JOIN media_review_status mrs
           ON mrs.project_id = pm.project_id AND mrs.media_id = pm.media_id
         WHERE pm.project_id = ? AND pm.media_id IN (${placeholders})`,
      )
      .all(filter.projectId, ...pageIds) as Record<string, unknown>[];
    const byId = new Map(hydrated.map((r) => [Number(r.media_id), mapCard(r)]));
    items = attachProvenance(
      db,
      filter.projectId,
      pageIds.map((id) => byId.get(id)!).filter(Boolean),
    );
  }

  let nextCursor: string | null = null;
  if (hasMore && items.length) {
    const last = items[items.length - 1];
    nextCursor = encodeCursor({
      mediaId: last.mediaId,
      title: last.title,
      uploader: last.uploader,
      timestamp: last.timestamp,
      score: last.score,
      sort: q.sort,
      dir: q.dir,
    });
  }

  const statusCounts = computeStatusCounts(db, filter);
  return {
    items,
    nextCursor,
    total: statusCounts.total,
    statusCounts,
  };
}
