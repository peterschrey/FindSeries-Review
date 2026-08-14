import type {
  GroupBy,
  GroupCard,
  GroupQuery,
  GroupsResponse,
  MediaCard,
  MediaFilter,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import { buildFilteredMediaCte } from '../sql/filters.js';
import { computeStatusCounts } from './gallery.js';

function mapSample(r: Record<string, unknown>): MediaCard {
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

type GroupExpr = { selectKey: string; join: string; joinParams: (projectId: number) => unknown[] };

function groupKeyExpr(groupBy: GroupBy): GroupExpr {
  switch (groupBy) {
    case 'uploader':
      return {
        selectKey: `COALESCE(NULLIF(fm.uploader,''), '(ohne Uploader)')`,
        join: '',
        joinParams: () => [],
      };
    case 'provenance':
      return {
        selectKey: `COALESCE(rpm.family, 'unknown') || ':' || d.source_type`,
        join: `
JOIN discoveries d ON d.project_id = ? AND d.media_id = fm.media_id
LEFT JOIN review_provenance_type_map rpm ON rpm.source_type = d.source_type`,
        joinParams: (projectId) => [projectId],
      };
    case 'series':
      return {
        selectKey: `COALESCE(d.source_value, d.query_text, '(ohne Serie)')`,
        join: `
JOIN discoveries d ON d.project_id = ? AND d.media_id = fm.media_id
  AND d.source_type IN ('filename-series','time-series','filename')`,
        joinParams: (projectId) => [projectId],
      };
    case 'category':
      return {
        selectKey: `CAST(resolved_cat.category_id AS TEXT)`,
        join: `
JOIN (
  SELECT d.media_id AS media_id, d.origin_category_id AS category_id
  FROM discoveries d
  WHERE d.project_id = ? AND d.source_type = 'category' AND d.origin_category_id IS NOT NULL
  UNION
  SELECT d.media_id, c.id AS category_id
  FROM discoveries d
  JOIN categories c ON c.normalized_title = lower(d.source_value)
  JOIN project_categories pc ON pc.project_id = ? AND pc.category_id = c.id
  WHERE d.project_id = ?
    AND d.source_type = 'category'
    AND d.origin_category_id IS NULL
    AND d.source_value IS NOT NULL AND trim(d.source_value) <> ''
    AND (
      SELECT COUNT(*) FROM categories c2
      WHERE c2.normalized_title = lower(d.source_value)
    ) = 1
) resolved_cat ON resolved_cat.media_id = fm.media_id`,
        joinParams: (projectId) => [projectId, projectId, projectId],
      };
    default:
      return { selectKey: `'all'`, join: '', joinParams: () => [] };
  }
}

function drilldownFor(
  groupBy: GroupBy,
  key: string,
  projectId: number,
  base: MediaFilter,
): MediaFilter {
  const common: MediaFilter = {
    projectId,
    statuses: base.statuses,
    q: base.q,
    sourceTypes: base.sourceTypes,
    categoryIds: base.categoryIds,
    uploader: base.uploader,
    seriesKey: base.seriesKey,
    seedKey: base.seedKey,
    parentMediaId: base.parentMediaId,
    mediaIds: base.mediaIds,
  };
  switch (groupBy) {
    case 'uploader':
      return {
        ...common,
        // null = empty/null uploader filter (not undefined = no filter)
        uploader: key === '(ohne Uploader)' ? null : key,
      };
    case 'series':
      return { ...common, seriesKey: key };
    case 'provenance': {
      const sourceType = key.includes(':') ? key.slice(key.indexOf(':') + 1) : key;
      return { ...common, sourceTypes: [sourceType] };
    }
    case 'category': {
      const id = Number(key);
      return {
        ...common,
        categoryIds: Number.isFinite(id) ? [id] : common.categoryIds,
      };
    }
    default:
      return common;
  }
}

function labelFor(db: ReviewDb, groupBy: GroupBy, key: string): string {
  if (groupBy === 'category') {
    const id = Number(key);
    const row = db.prepare(`SELECT title FROM categories WHERE id = ?`).get(id) as
      | { title: string }
      | undefined;
    return row?.title ?? key;
  }
  if (groupBy === 'provenance') {
    const sourceType = key.includes(':') ? key.slice(key.indexOf(':') + 1) : key;
    const row = db
      .prepare(`SELECT chip_label FROM review_provenance_type_map WHERE source_type = ?`)
      .get(sourceType) as { chip_label: string } | undefined;
    return row?.chip_label ?? sourceType;
  }
  return key;
}

export function queryGroups(db: ReviewDb, q: GroupQuery): GroupsResponse {
  const filter: MediaFilter = {
    projectId: q.projectId,
    statuses: q.statuses,
    q: q.q,
    sourceTypes: q.sourceTypes,
    categoryIds: q.categoryIds,
    uploader: q.uploader,
    seriesKey: q.seriesKey,
    seedKey: q.seedKey,
    parentMediaId: q.parentMediaId,
    mediaIds: q.mediaIds,
  };
  const base = buildFilteredMediaCte(filter, 'count');
  const { selectKey, join, joinParams } = groupKeyExpr(q.groupBy);
  const jp = joinParams(q.projectId);

  const keyBase = base;

  const keyRows = db
    .prepare(
      `WITH fm AS (${keyBase.sql})
       SELECT ${selectKey} AS gkey, COUNT(DISTINCT fm.media_id) AS approx_total
       FROM fm
       ${join}
       GROUP BY gkey
       ORDER BY approx_total DESC
       LIMIT ?`,
    )
    .all(...keyBase.params, ...jp, q.limit) as Array<{ gkey: string; approx_total: number }>;

  const groups: GroupCard[] = keyRows.map((r) => {
    const key = String(r.gkey ?? '');
    const drill = drilldownFor(q.groupBy, key, q.projectId, filter);
    const accurate = computeStatusCounts(db, drill);
    let sampleMedia: MediaCard[] = [];
    if (q.sampleSize > 0) {
      const sampleBase = buildFilteredMediaCte(drill);
      sampleMedia = (
        db
          .prepare(
            `WITH fm AS (${sampleBase.sql})
             SELECT * FROM fm ORDER BY media_id ASC LIMIT ?`,
          )
          .all(...sampleBase.params, q.sampleSize) as Record<string, unknown>[]
      ).map(mapSample);
    }
    return {
      key,
      label: labelFor(db, q.groupBy, key),
      total: accurate.total,
      statusCounts: accurate,
      sampleMedia,
      drilldown: drill,
    };
  });

  const statusCounts = computeStatusCounts(db, filter);
  return {
    groups,
    resultTotal: statusCounts.total,
    statusCounts,
  };
}
