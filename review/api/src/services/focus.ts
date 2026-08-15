import type {
  FocusQuery,
  FocusRelation,
  FocusResponse,
  MediaFilter,
  StatusCounts,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import { computeStatusCounts } from './gallery.js';

const EMPTY_COUNTS: StatusCounts = {
  unreviewed: 0,
  keep: 0,
  reject: 0,
  unsure: 0,
  total: 0,
};

function baseFrom(q: FocusQuery): MediaFilter {
  return {
    projectId: q.projectId,
    statuses: q.baseFilter?.statuses,
    q: q.baseFilter?.q,
    sourceTypes: q.baseFilter?.sourceTypes,
    alsoSourceTypes: q.baseFilter?.alsoSourceTypes,
    categoryIds: q.baseFilter?.categoryIds,
    alsoCategoryIds: q.baseFilter?.alsoCategoryIds,
    categoryIncludeDescendants: q.baseFilter?.categoryIncludeDescendants,
    alsoCategoryIncludeDescendants: q.baseFilter?.alsoCategoryIncludeDescendants,
    uploader: q.baseFilter?.uploader,
    seriesKey: q.baseFilter?.seriesKey,
    seedKey: q.baseFilter?.seedKey,
    parentMediaId: q.baseFilter?.parentMediaId,
    mediaIds: q.baseFilter?.mediaIds,
  };
}

function unavailable(
  kind: FocusRelation['kind'],
  label: string,
  note: string,
): FocusRelation {
  return {
    kind,
    label,
    total: 0,
    statusCounts: EMPTY_COUNTS,
    available: false,
    filter: null,
    note,
  };
}

function available(
  kind: FocusRelation['kind'],
  label: string,
  filter: MediaFilter,
  statusCounts: StatusCounts,
  note?: string,
): FocusRelation {
  return {
    kind,
    label,
    total: statusCounts.total,
    statusCounts,
    available: true,
    filter,
    note,
  };
}

/** Seed keys for focus media per PROVENANCE_MODEL.md */
function seedKeysForFocus(
  db: ReviewDb,
  projectId: number,
  focusMediaId: number,
): string[] {
  const rows = db
    .prepare(
      `SELECT DISTINCT
         CASE
           WHEN COALESCE(rpm.family, '') = 'neighbor' AND d.parent_media_id IS NOT NULL
             THEN 'media:' || d.parent_media_id
           WHEN COALESCE(rpm.family, '') = 'keyword'
             AND d.query_text IS NOT NULL AND trim(d.query_text) <> ''
             THEN lower(trim(d.query_text))
           ELSE NULL
         END AS seed_key
       FROM discoveries d
       LEFT JOIN review_provenance_type_map rpm ON rpm.source_type = d.source_type
       WHERE d.project_id = ? AND d.media_id = ?
       ORDER BY seed_key COLLATE NOCASE`,
    )
    .all(projectId, focusMediaId) as Array<{ seed_key: string | null }>;
  return [...new Set(rows.map((r) => r.seed_key).filter((k): k is string => Boolean(k)))];
}

/** Focus is seed for neighbors if other media have parent_media_id = focus. */
function focusIsNeighborSeed(db: ReviewDb, projectId: number, focusMediaId: number): boolean {
  const row = db
    .prepare(
      `SELECT 1 AS x FROM discoveries d
       LEFT JOIN review_provenance_type_map rpm ON rpm.source_type = d.source_type
       WHERE d.project_id = ? AND d.parent_media_id = ?
         AND COALESCE(rpm.family, '') = 'neighbor'
       LIMIT 1`,
    )
    .get(projectId, focusMediaId);
  return Boolean(row);
}

function categoryRelationFilter(base: MediaFilter, ids: number[]): MediaFilter {
  if (base.categoryIds?.length) {
    return {
      ...base,
      alsoCategoryIds: ids,
      alsoCategoryIncludeDescendants: base.categoryIncludeDescendants !== false,
    };
  }
  return {
    ...base,
    categoryIds: ids,
    categoryIncludeDescendants: base.categoryIncludeDescendants,
  };
}

function provenanceRelationFilter(base: MediaFilter, types: string[]): MediaFilter {
  if (base.sourceTypes?.length) {
    return { ...base, alsoSourceTypes: types };
  }
  return { ...base, sourceTypes: types };
}

/** Primary media_series_keys first; discovery fallback only if no primary. */
function seriesKeyForFocus(
  db: ReviewDb,
  projectId: number,
  focusMediaId: number,
): string | null {
  const primary = db
    .prepare(
      `SELECT series_key AS sk
       FROM media_series_keys
       WHERE project_id = ? AND media_id = ? AND is_primary = 1
       ORDER BY series_key COLLATE NOCASE
       LIMIT 1`,
    )
    .get(projectId, focusMediaId) as { sk: string } | undefined;
  if (primary?.sk) return primary.sk;

  const disc = db
    .prepare(
      `SELECT COALESCE(source_value, query_text) AS sk
       FROM discoveries
       WHERE project_id = ? AND media_id = ?
         AND source_type IN ('filename-series','time-series','filename')
         AND COALESCE(source_value, query_text) IS NOT NULL
         AND trim(COALESCE(source_value, query_text)) <> ''
       ORDER BY sk COLLATE NOCASE
       LIMIT 1`,
    )
    .get(projectId, focusMediaId) as { sk: string } | undefined;
  return disc?.sk ?? null;
}

export function queryFocus(db: ReviewDb, q: FocusQuery): FocusResponse {
  const base = baseFrom(q);
  const relations: FocusRelation[] = [];

  // similar — P1 placeholder: unavailable, no drilldown filter
  relations.push(unavailable('similar', 'Ähnlich', 'P1: Similarity noch nicht aktiv'));

  // series — primary keys preferred
  const seriesKey = seriesKeyForFocus(db, q.projectId, q.focusMediaId);
  if (seriesKey) {
    const filter: MediaFilter = { ...base, seriesKey };
    relations.push(available('series', 'Serie', filter, computeStatusCounts(db, filter)));
  } else {
    relations.push(unavailable('series', 'Serie', 'Keine Serien-Beziehung gefunden'));
  }

  // category
  const cats = db
    .prepare(
      `SELECT DISTINCT category_id FROM (
         SELECT origin_category_id AS category_id
         FROM discoveries
         WHERE project_id = ? AND media_id = ? AND source_type = 'category'
           AND origin_category_id IS NOT NULL
         UNION
         SELECT c.id AS category_id
         FROM discoveries d
         JOIN categories c ON c.normalized_title = lower(d.source_value)
         JOIN project_categories pc ON pc.project_id = ? AND pc.category_id = c.id
         WHERE d.project_id = ? AND d.media_id = ? AND d.source_type = 'category'
           AND d.origin_category_id IS NULL
           AND d.source_value IS NOT NULL AND trim(d.source_value) <> ''
           AND (
             SELECT COUNT(*) FROM categories c2
             WHERE c2.normalized_title = lower(d.source_value)
           ) = 1
       )
       ORDER BY category_id`,
    )
    .all(q.projectId, q.focusMediaId, q.projectId, q.projectId, q.focusMediaId) as Array<{
    category_id: number;
  }>;
  if (cats.length) {
    const ids = cats.map((c) => c.category_id);
    const filter = categoryRelationFilter(base, ids);
    const title =
      ids.length === 1
        ? ((
            db.prepare(`SELECT title FROM categories WHERE id = ?`).get(ids[0]) as
              | { title: string }
              | undefined
          )?.title ?? 'Kategorie')
        : `Kategorien (${ids.length})`;
    relations.push(available('category', title, filter, computeStatusCounts(db, filter)));
  } else {
    relations.push(unavailable('category', 'Kategorie', 'Keine Kategorie-Beziehung'));
  }

  // seed — PROVENANCE_MODEL only; optionally focus-as-neighbor-seed
  const seeds = seedKeysForFocus(db, q.projectId, q.focusMediaId);
  if (seeds.length) {
    const filter: MediaFilter = { ...base, seedKey: seeds[0] };
    relations.push(
      available('seed', 'Seed', filter, computeStatusCounts(db, filter), seeds.join(', ')),
    );
  } else if (focusIsNeighborSeed(db, q.projectId, q.focusMediaId)) {
    const filter: MediaFilter = { ...base, seedKey: `media:${q.focusMediaId}` };
    relations.push(
      available(
        'seed',
        'Seed (dieses Medium)',
        filter,
        computeStatusCounts(db, filter),
        'Focus ist parent_media_id für Neighbor-Discoveries',
      ),
    );
  } else {
    relations.push(unavailable('seed', 'Seed', 'Kein belastbarer Seed (PROVENANCE_MODEL)'));
  }

  // uploader — AND with global filter (same conflict pattern as reviewState applyPatch)
  const media = db
    .prepare(`SELECT current_uploader AS uploader FROM media WHERE id = ?`)
    .get(q.focusMediaId) as { uploader: string | null } | undefined;
  if (!media) {
    relations.push(unavailable('uploader', 'Uploader', 'Medium nicht gefunden'));
  } else {
    const focusUploader: string | null =
      media.uploader == null || media.uploader === '' ? null : media.uploader;
    const label =
      focusUploader == null ? 'Uploader (leer)' : `Uploader: ${focusUploader}`;
    const baseNorm =
      base.uploader === undefined
        ? undefined
        : base.uploader === null || base.uploader === ''
          ? null
          : base.uploader;

    if (baseNorm !== undefined && baseNorm !== focusUploader) {
      // AND conflict: relation total 0. Filter carries focus uploader for relationToPatch
      // (applyPatch sets mediaIds=[]) AND mediaIds=[] so gallery with this filter alone is also 0.
      const filter: MediaFilter = { ...base, uploader: focusUploader, mediaIds: [] };
      relations.push(
        available(
          'uploader',
          label,
          filter,
          EMPTY_COUNTS,
          'Uploader-Konflikt mit globalem Filter (leere Menge)',
        ),
      );
    } else {
      const filter: MediaFilter = { ...base, uploader: focusUploader };
      relations.push(available('uploader', label, filter, computeStatusCounts(db, filter)));
    }
  }

  // provenance
  const types = db
    .prepare(
      `SELECT DISTINCT source_type FROM discoveries
       WHERE project_id = ? AND media_id = ?
       ORDER BY source_type COLLATE NOCASE`,
    )
    .all(q.projectId, q.focusMediaId) as Array<{ source_type: string }>;
  if (types.length) {
    const typeList = types.map((t) => t.source_type);
    const filter = provenanceRelationFilter(base, typeList);
    relations.push(
      available(
        'provenance',
        'Herkunft',
        filter,
        computeStatusCounts(db, filter),
        typeList.join(', '),
      ),
    );
  } else {
    relations.push(unavailable('provenance', 'Herkunft', 'Keine Discovery-Herkunft'));
  }

  return { focusMediaId: q.focusMediaId, relations };
}
