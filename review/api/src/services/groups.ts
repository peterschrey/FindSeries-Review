import type {
  GroupBy,
  GroupCard,
  GroupQuery,
  GroupsResponse,
  MediaCard,
  MediaFilter,
  ReviewStatus,
  StatusCounts,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import {
  buildFilteredMediaCte,
  resolveStatuses,
  resolvedCategoryMembershipSql,
} from '../sql/filters.js';
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

type GroupExpr = {
  selectKey: string;
  join: string;
  joinParams: unknown[];
  /** Optional CTEs prepended before `fm` (params bind before fm params). */
  leadingCteSql?: string;
  leadingCteParams?: unknown[];
};

function groupKeyExpr(groupBy: GroupBy, projectId: number): GroupExpr {
  switch (groupBy) {
    case 'uploader':
      return {
        selectKey: `COALESCE(NULLIF(fm.uploader,''), '(ohne Uploader)')`,
        join: '',
        joinParams: [],
      };
    case 'provenance':
      return {
        selectKey: `COALESCE(rpm.family, 'unknown') || ':' || d.source_type`,
        join: `
JOIN discoveries d ON d.project_id = ? AND d.media_id = fm.media_id
LEFT JOIN review_provenance_type_map rpm ON rpm.source_type = d.source_type`,
        joinParams: [projectId],
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
        joinParams: [projectId, projectId],
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
        joinParams: [projectId],
      };
    case 'category': {
      // Full CATEGORY_GRAPH: MATERIALIZED CTE (origin ∪ validated fallback), then JOIN.
      // Filters use the same rules via categoryMediaSql.
      const resolved = resolvedCategoryMembershipSql(projectId);
      return {
        selectKey: `CAST(rc.category_id AS TEXT)`,
        join: `JOIN resolved_category rc ON rc.media_id = fm.media_id`,
        joinParams: [],
        leadingCteSql: `resolved_category AS MATERIALIZED (${resolved.sql})`,
        leadingCteParams: resolved.params,
      };
    }
    default:
      return { selectKey: `'all'`, join: '', joinParams: [] };
  }
}

/** Build `WITH [leading,] fm AS (...)` prefix; returns SQL fragment + bind order hint. */
function withFmSql(fmSql: string, leadingCteSql?: string): string {
  if (leadingCteSql) return `WITH ${leadingCteSql}, fm AS (${fmSql})`;
  return `WITH fm AS (${fmSql})`;
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
      // Group keys are exact CATEGORY_GRAPH membership; drilldown must not expand subtree
      // (otherwise parent keys: card total ≠ gallery after click).
      if (base.categoryIds?.length) {
        return {
          ...common,
          alsoCategoryIds: [id],
          alsoCategoryIncludeDescendants: false,
        };
      }
      return {
        ...common,
        categoryIds: [id],
        categoryIncludeDescendants: false,
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

function toStatusCounts(row: {
  unreviewed?: number;
  keep?: number;
  reject?: number;
  unsure?: number;
  total?: number;
} | undefined): StatusCounts {
  const unreviewed = Number(row?.unreviewed ?? 0);
  const keep = Number(row?.keep ?? 0);
  const reject = Number(row?.reject ?? 0);
  const unsure = Number(row?.unsure ?? 0);
  return {
    unreviewed,
    keep,
    reject,
    unsure,
    total: Number(row?.total ?? unreviewed + keep + reject + unsure),
  };
}

function needsProgressBreakdown(statuses: ReviewStatus[] | 'empty'): boolean {
  if (statuses === 'empty') return false;
  return statuses.length < 4;
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
  const {
    selectKey,
    join,
    joinParams: jp,
    leadingCteSql,
    leadingCteParams = [],
  } = groupKeyExpr(q.groupBy, q.projectId);
  const uiStatuses = resolveStatuses(filter);
  const lead = leadingCteParams;

  type StatRow = {
    gkey: string;
    total: number;
    unreviewed: number;
    keep: number;
    reject: number;
    unsure: number;
    visible_total: number;
  };

  /**
   * Single discoveries pass:
   * - fm uses all 4 statuses when a progress breakdown is needed, else UI statuses
   * - visible_total = sum of UI-active status columns (HAVING > 0 keeps UI key semantics)
   * - full status columns feed progressStatusCounts when UI ⊂ {all 4}
   *
   * Avoids the prior keyOnly + visible + progress triple scan (FRV-40 P0).
   */
  const needProgress = needsProgressBreakdown(uiStatuses);
  const scanFilter: MediaFilter = needProgress
    ? { ...filter, statuses: ['unreviewed', 'keep', 'reject', 'unsure'] }
    : filter;
  const scanBase = buildFilteredMediaCte(scanFilter, 'count');

  const uiUnreviewed = uiStatuses !== 'empty' && uiStatuses.includes('unreviewed') ? 1 : 0;
  const uiKeep = uiStatuses !== 'empty' && uiStatuses.includes('keep') ? 1 : 0;
  const uiReject = uiStatuses !== 'empty' && uiStatuses.includes('reject') ? 1 : 0;
  const uiUnsure = uiStatuses !== 'empty' && uiStatuses.includes('unsure') ? 1 : 0;

  const visibleExpr = `(
    CASE WHEN ${uiUnreviewed} THEN SUM(CASE WHEN review_status='unreviewed' THEN 1 ELSE 0 END) ELSE 0 END +
    CASE WHEN ${uiKeep} THEN SUM(CASE WHEN review_status='keep' THEN 1 ELSE 0 END) ELSE 0 END +
    CASE WHEN ${uiReject} THEN SUM(CASE WHEN review_status='reject' THEN 1 ELSE 0 END) ELSE 0 END +
    CASE WHEN ${uiUnsure} THEN SUM(CASE WHEN review_status='unsure' THEN 1 ELSE 0 END) ELSE 0 END
  )`;

  const aggRows = db
    .prepare(
      `${withFmSql(scanBase.sql, leadingCteSql)},
       tagged AS (
         SELECT DISTINCT fm.media_id AS media_id,
                fm.review_status AS review_status,
                ${selectKey} AS gkey
         FROM fm
         ${join}
         WHERE ${selectKey} IS NOT NULL
       )
       SELECT gkey,
              COUNT(*) AS total,
              SUM(CASE WHEN review_status='unreviewed' THEN 1 ELSE 0 END) AS unreviewed,
              SUM(CASE WHEN review_status='keep' THEN 1 ELSE 0 END) AS keep,
              SUM(CASE WHEN review_status='reject' THEN 1 ELSE 0 END) AS reject,
              SUM(CASE WHEN review_status='unsure' THEN 1 ELSE 0 END) AS unsure,
              ${visibleExpr} AS visible_total
       FROM tagged
       GROUP BY gkey
       HAVING visible_total > 0
       ORDER BY visible_total DESC
       LIMIT ?`,
    )
    .all(...lead, ...scanBase.params, ...jp, q.limit) as StatRow[];

  if (!aggRows.length) {
    const statusCounts = computeStatusCounts(db, filter, { breakdownAllStatuses: true });
    return { groups: [], resultTotal: statusCounts.total, statusCounts };
  }

  const keys = aggRows.map((r) => String(r.gkey));
  const keyPlaceholders = keys.map(() => '?').join(',');
  const statsByKey = new Map(aggRows.map((r) => [String(r.gkey), r]));

  const sampleByKey = new Map<string, MediaCard[]>();
  if (q.sampleSize > 0) {
    const uiBase = buildFilteredMediaCte(filter, 'count');
    const sampleRows = db
      .prepare(
        `${withFmSql(uiBase.sql, leadingCteSql)},
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
      .all(...lead, ...uiBase.params, ...jp, ...keys, q.sampleSize) as Record<string, unknown>[];
    for (const row of sampleRows) {
      const k = String(row.gkey);
      const list = sampleByKey.get(k) ?? [];
      list.push(mapSample(row));
      sampleByKey.set(k, list);
    }
  }

  const groups: GroupCard[] = aggRows.map((r) => {
    const key = String(r.gkey ?? '');
    const drill = drilldownFor(q.groupBy, key, q.projectId, filter);
    const st = statsByKey.get(key)!;
    const vis: StatusCounts = {
      unreviewed: uiUnreviewed ? Number(st.unreviewed) : 0,
      keep: uiKeep ? Number(st.keep) : 0,
      reject: uiReject ? Number(st.reject) : 0,
      unsure: uiUnsure ? Number(st.unsure) : 0,
      total: Number(st.visible_total),
    };
    const card: GroupCard = {
      key,
      label: labelFor(db, q.groupBy, key),
      total: vis.total,
      statusCounts: vis,
      sampleMedia: sampleByKey.get(key) ?? [],
      drilldown: drill,
    };
    if (needProgress) {
      card.progressStatusCounts = toStatusCounts(st);
    }
    return card;
  });

  const statusCounts = computeStatusCounts(db, filter, { breakdownAllStatuses: true });
  return {
    groups,
    resultTotal: statusCounts.total,
    statusCounts,
  };
}
