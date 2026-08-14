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
      // Prefer primary media_series_keys; fall back to discovery series types.
      return {
        selectKey: `COALESCE(msk.series_key, COALESCE(d.source_value, d.query_text), '(ohne Serie)')`,
        join: `
LEFT JOIN media_series_keys msk
  ON msk.project_id = ? AND msk.media_id = fm.media_id AND msk.is_primary = 1
LEFT JOIN discoveries d ON d.project_id = ? AND d.media_id = fm.media_id
  AND d.source_type IN ('filename-series','time-series','filename')
  AND msk.media_id IS NULL`,
        joinParams: (projectId) => [projectId, projectId],
      };
    case 'seed':
      // PROVENANCE_MODEL: neighbor→media:parent OR keyword→lower(trim(query_text))
      return {
        selectKey: `CASE
          WHEN COALESCE(rpm.family,'') = 'neighbor' AND d.parent_media_id IS NOT NULL
            THEN 'media:' || d.parent_media_id
          WHEN COALESCE(rpm.family,'') = 'keyword' AND d.query_text IS NOT NULL AND trim(d.query_text) <> ''
            THEN lower(trim(d.query_text))
          ELSE NULL
        END`,
        join: `
JOIN discoveries d ON d.project_id = ? AND d.media_id = fm.media_id
LEFT JOIN review_provenance_type_map rpm ON rpm.source_type = d.source_type`,
        joinParams: (projectId) => [projectId],
      };
    case 'category':
      // Group keys use indexed origin_category_id only (fast path).
      // Title/source_value fallback remains in filter SQL (categoryMediaSql), not here.
      return {
        selectKey: `CAST(d.origin_category_id AS TEXT)`,
        join: `
JOIN discoveries d
  ON d.project_id = ? AND d.media_id = fm.media_id
 AND d.source_type = 'category'
 AND d.origin_category_id IS NOT NULL`,
        joinParams: (projectId) => [projectId],
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
    alsoSourceTypes: base.alsoSourceTypes,
    categoryIds: base.categoryIds,
    alsoCategoryIds: base.alsoCategoryIds,
    categoryIncludeDescendants: base.categoryIncludeDescendants,
    alsoCategoryIncludeDescendants: base.alsoCategoryIncludeDescendants,
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
    case 'seed':
      return { ...common, seedKey: key };
    case 'provenance': {
      const sourceType = key.includes(':') ? key.slice(key.indexOf(':') + 1) : key;
      if (base.sourceTypes?.length) {
        return { ...common, alsoSourceTypes: [sourceType] };
      }
      return { ...common, sourceTypes: [sourceType] };
    }
    case 'category': {
      const id = Number(key);
      if (!Number.isFinite(id)) return common;
      if (base.categoryIds?.length) {
        return {
          ...common,
          alsoCategoryIds: [id],
          alsoCategoryIncludeDescendants: base.categoryIncludeDescendants !== false,
        };
      }
      return {
        ...common,
        categoryIds: [id],
        categoryIncludeDescendants: base.categoryIncludeDescendants,
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
  const { selectKey, join, joinParams } = groupKeyExpr(q.groupBy);
  const jp = joinParams(q.projectId);

  // Key discovery respects UI status chips (same as before).
  const uiBase = buildFilteredMediaCte(filter, 'count');
  const keyOnly = db
    .prepare(
      `WITH fm AS (${uiBase.sql})
       SELECT ${selectKey} AS gkey, COUNT(DISTINCT fm.media_id) AS approx_total
       FROM fm
       ${join}
       WHERE ${selectKey} IS NOT NULL
       GROUP BY gkey
       ORDER BY approx_total DESC
       LIMIT ?`,
    )
    .all(...uiBase.params, ...jp, q.limit) as Array<{ gkey: string; approx_total: number }>;

  if (!keyOnly.length) {
    const statusCounts = computeStatusCounts(db, filter, { breakdownAllStatuses: true });
    return { groups: [], resultTotal: statusCounts.total, statusCounts };
  }

  const keys = keyOnly.map((r) => String(r.gkey));
  const keyPlaceholders = keys.map(() => '?').join(',');

  // One status-breakdown pass for the selected keys (all 4 statuses — matches prior DoD).
  const allStatusFilter: MediaFilter = {
    ...filter,
    statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
  };
  const allBase = buildFilteredMediaCte(allStatusFilter, 'count');
  const statRows = db
    .prepare(
      `WITH fm AS (${allBase.sql}),
       tagged AS (
         SELECT DISTINCT fm.media_id AS media_id,
                fm.review_status AS review_status,
                ${selectKey} AS gkey
         FROM fm
         ${join}
         WHERE ${selectKey} IS NOT NULL
           AND ${selectKey} IN (${keyPlaceholders})
       )
       SELECT gkey,
              COUNT(*) AS total,
              SUM(CASE WHEN review_status='unreviewed' THEN 1 ELSE 0 END) AS unreviewed,
              SUM(CASE WHEN review_status='keep' THEN 1 ELSE 0 END) AS keep,
              SUM(CASE WHEN review_status='reject' THEN 1 ELSE 0 END) AS reject,
              SUM(CASE WHEN review_status='unsure' THEN 1 ELSE 0 END) AS unsure
       FROM tagged
       GROUP BY gkey`,
    )
    .all(...allBase.params, ...jp, ...keys) as Array<{
    gkey: string;
    total: number;
    unreviewed: number;
    keep: number;
    reject: number;
    unsure: number;
  }>;
  const statsByKey = new Map(statRows.map((r) => [String(r.gkey), r]));

  const sampleByKey = new Map<string, MediaCard[]>();
  if (q.sampleSize > 0) {
    const sampleRows = db
      .prepare(
        `WITH fm AS (${allBase.sql}),
         tagged AS (
           SELECT DISTINCT fm.media_id AS media_id,
                  fm.title AS title,
                  fm.uploader AS uploader,
                  fm.timestamp AS timestamp,
                  fm.score AS score,
                  fm.review_status AS review_status,
                  ${selectKey} AS gkey
           FROM fm
           ${join}
           WHERE ${selectKey} IS NOT NULL
             AND ${selectKey} IN (${keyPlaceholders})
         ),
         ranked AS (
           SELECT *,
                  ROW_NUMBER() OVER (PARTITION BY gkey ORDER BY media_id ASC) AS rn
           FROM tagged
         )
         SELECT * FROM ranked WHERE rn <= ?
         ORDER BY gkey, media_id`,
      )
      .all(...allBase.params, ...jp, ...keys, q.sampleSize) as Record<string, unknown>[];
    for (const row of sampleRows) {
      const k = String(row.gkey);
      const list = sampleByKey.get(k) ?? [];
      list.push(mapSample(row));
      sampleByKey.set(k, list);
    }
  }

  const groups: GroupCard[] = keyOnly.map((r) => {
    const key = String(r.gkey ?? '');
    const drill = drilldownFor(q.groupBy, key, q.projectId, filter);
    const st = statsByKey.get(key);
    const accurate = {
      unreviewed: Number(st?.unreviewed ?? 0),
      keep: Number(st?.keep ?? 0),
      reject: Number(st?.reject ?? 0),
      unsure: Number(st?.unsure ?? 0),
      total: Number(st?.total ?? r.approx_total ?? 0),
    };
    return {
      key,
      label: labelFor(db, q.groupBy, key),
      total: accurate.total,
      statusCounts: accurate,
      sampleMedia: sampleByKey.get(key) ?? [],
      drilldown: drill,
    };
  });

  const statusCounts = computeStatusCounts(db, filter, { breakdownAllStatuses: true });
  return {
    groups,
    resultTotal: statusCounts.total,
    statusCounts,
  };
}
