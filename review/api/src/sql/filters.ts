import type { MediaFilter, ReviewStatus, SortDir, SortField } from '@findseries/review-shared';

export type BoundSql = { sql: string; params: unknown[] };

/** Category membership with origin_category_id + validated source_value fallback. */
export function categoryMediaSql(
  projectId: number,
  categoryIds: number[],
  opts?: { includeDescendants?: boolean },
): BoundSql {
  if (!categoryIds.length) {
    return { sql: 'SELECT CAST(NULL AS INTEGER) AS media_id WHERE 0', params: [] };
  }
  const placeholders = categoryIds.map(() => '?').join(',');
  const includeDescendants = opts?.includeDescendants !== false;

  if (!includeDescendants) {
    // Exact category only — no subtree expansion.
    return {
      sql: `
SELECT DISTINCT d.media_id AS media_id
FROM discoveries d
WHERE d.project_id = ? AND d.source_type = 'category'
  AND d.origin_category_id IN (${placeholders})
UNION
SELECT DISTINCT d.media_id AS media_id
FROM discoveries d
JOIN categories c ON c.normalized_title = lower(d.source_value)
JOIN project_categories pc ON pc.project_id = ? AND pc.category_id = c.id
WHERE d.project_id = ?
  AND d.source_type = 'category'
  AND d.origin_category_id IS NULL
  AND c.id IN (${placeholders})
  AND d.source_value IS NOT NULL AND trim(d.source_value) <> ''
  AND (
    SELECT COUNT(*) FROM categories c2
    WHERE c2.normalized_title = lower(d.source_value)
  ) = 1`,
      params: [projectId, ...categoryIds, projectId, projectId, ...categoryIds],
    };
  }

  return {
    sql: `
WITH RECURSIVE sub AS (
  SELECT category_id AS id
  FROM project_categories
  WHERE project_id = ? AND category_id IN (${placeholders})
  UNION
  SELECT pc.category_id
  FROM project_categories pc
  JOIN sub ON pc.parent_category_id = sub.id
  WHERE pc.project_id = ?
),
resolved AS (
  SELECT DISTINCT d.media_id AS media_id
  FROM discoveries d
  JOIN sub ON d.origin_category_id = sub.id
  WHERE d.project_id = ? AND d.source_type = 'category'
  UNION
  SELECT DISTINCT d.media_id AS media_id
  FROM discoveries d
  JOIN categories c ON c.normalized_title = lower(d.source_value)
  JOIN sub ON sub.id = c.id
  JOIN project_categories pc ON pc.project_id = ? AND pc.category_id = c.id
  WHERE d.project_id = ?
    AND d.source_type = 'category'
    AND d.origin_category_id IS NULL
    AND d.source_value IS NOT NULL AND trim(d.source_value) <> ''
    AND (
      SELECT COUNT(*) FROM categories c2
      WHERE c2.normalized_title = lower(d.source_value)
    ) = 1
)
SELECT media_id FROM resolved`,
    params: [projectId, ...categoryIds, projectId, projectId, projectId, projectId],
  };
}

export type FilterSelectMode = 'page' | 'count';

/** Resolve statuses: undefined → default; [] → empty sentinel. */
export function resolveStatuses(filter: Pick<MediaFilter, 'statuses'>): ReviewStatus[] | 'empty' {
  if (filter.statuses === undefined) return ['unreviewed', 'unsure'];
  if (filter.statuses.length === 0) return 'empty';
  return filter.statuses;
}

function buildWhere(filter: MediaFilter): { where: string[]; params: unknown[]; joinExtra: string; empty: boolean } {
  const params: unknown[] = [];
  const where: string[] = ['pm.project_id = ?'];
  params.push(filter.projectId);

  const statuses = resolveStatuses(filter);
  if (statuses === 'empty') {
    return { where: ['0'], params: [], joinExtra: '', empty: true };
  }
  where.push(`COALESCE(mrs.status, 'unreviewed') IN (${statuses.map(() => '?').join(',')})`);
  params.push(...statuses);

  // Explicit empty arrays → empty result
  if (filter.sourceTypes !== undefined && filter.sourceTypes.length === 0) {
    return { where: ['0'], params: [], joinExtra: '', empty: true };
  }
  if (filter.alsoSourceTypes !== undefined && filter.alsoSourceTypes.length === 0) {
    return { where: ['0'], params: [], joinExtra: '', empty: true };
  }
  if (filter.categoryIds !== undefined && filter.categoryIds.length === 0) {
    return { where: ['0'], params: [], joinExtra: '', empty: true };
  }
  if (filter.alsoCategoryIds !== undefined && filter.alsoCategoryIds.length === 0) {
    return { where: ['0'], params: [], joinExtra: '', empty: true };
  }
  if (filter.mediaIds !== undefined && filter.mediaIds.length === 0) {
    return { where: ['0'], params: [], joinExtra: '', empty: true };
  }

  if (filter.q && filter.q.trim()) {
    where.push(`(m.title LIKE ? OR COALESCE(m.current_uploader,'') LIKE ?)`);
    const like = `%${filter.q.trim()}%`;
    params.push(like, like);
  }
  if (filter.uploader === null) {
    where.push(`(m.current_uploader IS NULL OR m.current_uploader = '')`);
  } else if (filter.uploader !== undefined) {
    where.push(`m.current_uploader = ?`);
    params.push(filter.uploader);
  }
  if (filter.mediaIds?.length) {
    where.push(`pm.media_id IN (${filter.mediaIds.map(() => '?').join(',')})`);
    params.push(...filter.mediaIds);
  }
  if (filter.sourceTypes?.length) {
    where.push(`EXISTS (
      SELECT 1 FROM discoveries dsrc
      WHERE dsrc.project_id = pm.project_id AND dsrc.media_id = pm.media_id
        AND dsrc.source_type IN (${filter.sourceTypes.map(() => '?').join(',')})
    )`);
    params.push(...filter.sourceTypes);
  }
  if (filter.alsoSourceTypes?.length) {
    where.push(`EXISTS (
      SELECT 1 FROM discoveries dsrc2
      WHERE dsrc2.project_id = pm.project_id AND dsrc2.media_id = pm.media_id
        AND dsrc2.source_type IN (${filter.alsoSourceTypes.map(() => '?').join(',')})
    )`);
    params.push(...filter.alsoSourceTypes);
  }
  if (filter.parentMediaId) {
    where.push(`EXISTS (
      SELECT 1 FROM discoveries dn
      WHERE dn.project_id = pm.project_id AND dn.media_id = pm.media_id
        AND dn.parent_media_id = ?
    )`);
    params.push(filter.parentMediaId);
  }
  if (filter.seedKey) {
    // PROVENANCE_MODEL: neighbor→media:parent OR keyword→lower(trim(query_text))
    where.push(`EXISTS (
      SELECT 1 FROM discoveries ds
      LEFT JOIN review_provenance_type_map rpm ON rpm.source_type = ds.source_type
      WHERE ds.project_id = pm.project_id AND ds.media_id = pm.media_id
        AND (
          (COALESCE(rpm.family, '') = 'neighbor' AND ds.parent_media_id IS NOT NULL
            AND ('media:' || ds.parent_media_id) = ?)
          OR (COALESCE(rpm.family, '') = 'keyword' AND ds.query_text IS NOT NULL
            AND trim(ds.query_text) <> '' AND lower(trim(ds.query_text)) = ?)
        )
    )`);
    params.push(filter.seedKey, filter.seedKey);
  }
  if (filter.seriesKey) {
    where.push(`(
      EXISTS (
        SELECT 1 FROM media_series_keys msk
        WHERE msk.project_id = pm.project_id AND msk.media_id = pm.media_id
          AND msk.is_primary = 1 AND msk.series_key = ?
      )
      OR EXISTS (
        SELECT 1 FROM discoveries dser
        WHERE dser.project_id = pm.project_id AND dser.media_id = pm.media_id
          AND dser.source_type IN ('filename-series','time-series','filename')
          AND COALESCE(dser.source_value, dser.query_text) = ?
      )
    )`);
    params.push(filter.seriesKey, filter.seriesKey);
  }

  let joinExtra = '';
  const catJoins: string[] = [];
  const catParams: unknown[] = [];
  if (filter.categoryIds?.length) {
    const cat = categoryMediaSql(filter.projectId, filter.categoryIds, {
      includeDescendants: filter.categoryIncludeDescendants !== false,
    });
    catParams.push(...cat.params);
    catJoins.push(`JOIN (${cat.sql}) catf ON catf.media_id = pm.media_id`);
  }
  if (filter.alsoCategoryIds?.length) {
    const cat2 = categoryMediaSql(filter.projectId, filter.alsoCategoryIds, {
      includeDescendants: filter.alsoCategoryIncludeDescendants !== false,
    });
    catParams.push(...cat2.params);
    catJoins.push(`JOIN (${cat2.sql}) catf2 ON catf2.media_id = pm.media_id`);
  }
  if (catJoins.length) {
    params.unshift(...catParams);
    joinExtra = catJoins.join('\n');
  }
  return { where, params, joinExtra, empty: false };
}

/** Light projection for counts / id seeks (no downloads lookup). */
export function buildFilteredMediaCte(
  filter: MediaFilter,
  mode: FilterSelectMode = 'page',
): BoundSql {
  const built = buildWhere(filter);
  if (built.empty) {
    return {
      sql: `SELECT CAST(NULL AS INTEGER) AS media_id,
        CAST(NULL AS TEXT) AS title,
        CAST(NULL AS TEXT) AS uploader,
        CAST(NULL AS TEXT) AS timestamp,
        CAST(NULL AS REAL) AS score,
        CAST('unreviewed' AS TEXT) AS review_status,
        CAST(NULL AS TEXT) AS local_path
        WHERE 0`,
      params: [],
    };
  }
  const { where, params, joinExtra } = built;

  const select =
    mode === 'count'
      ? `pm.media_id AS media_id,
  COALESCE(mrs.status, 'unreviewed') AS review_status,
  COALESCE(m.current_uploader, '') AS uploader,
  COALESCE(m.title, '') AS title,
  COALESCE(m.current_timestamp, '') AS timestamp,
  COALESCE(pm.score, -1) AS score`
      : `pm.media_id AS media_id,
  m.title AS title,
  m.current_uploader AS uploader,
  m.current_timestamp AS timestamp,
  pm.score AS score,
  COALESCE(mrs.status, 'unreviewed') AS review_status,
  (
    SELECT d.local_path FROM downloads d
    WHERE d.media_id = pm.media_id
    LIMIT 1
  ) AS local_path`;

  const sql = `
SELECT
  ${select}
FROM project_media pm
JOIN media m ON m.id = pm.media_id
LEFT JOIN media_review_status mrs
  ON mrs.project_id = pm.project_id AND mrs.media_id = pm.media_id
${joinExtra}
WHERE ${where.join('\n  AND ')}
`;
  return { sql, params };
}

/** ORDER BY expressions — must match seekPredicate normalization exactly. */
export function sortClause(sort: SortField, dir: SortDir): string {
  const d = dir === 'desc' ? 'DESC' : 'ASC';
  switch (sort) {
    case 'title':
      return `COALESCE(title, '') COLLATE NOCASE ${d}, media_id ${d}`;
    case 'uploader':
      return `COALESCE(uploader, '') COLLATE NOCASE ${d}, media_id ${d}`;
    case 'timestamp':
      return `COALESCE(timestamp, '') ${d}, media_id ${d}`;
    case 'score':
      return `COALESCE(score, -1) ${d}, media_id ${d}`;
    case 'media_id':
    default:
      return `media_id ${d}`;
  }
}

export type SeekCursor = {
  mediaId: number;
  title?: string | null;
  uploader?: string | null;
  timestamp?: string | null;
  score?: number | null;
  sort: SortField;
  dir: SortDir;
};

export function encodeCursor(c: SeekCursor): string {
  return Buffer.from(JSON.stringify(c), 'utf8').toString('base64url');
}

export class CursorError extends Error {
  statusCode = 400;
  constructor(message: string) {
    super(message);
    this.name = 'CursorError';
  }
}

export function decodeCursor(raw: string, expected: { sort: SortField; dir: SortDir }): SeekCursor {
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
  } catch {
    throw new CursorError('Malformed cursor');
  }
  if (!parsed || typeof parsed !== 'object') {
    throw new CursorError('Malformed cursor');
  }
  const c = parsed as SeekCursor;
  if (typeof c.mediaId !== 'number' || !Number.isFinite(c.mediaId)) {
    throw new CursorError('Malformed cursor: mediaId');
  }
  if (c.sort !== expected.sort || c.dir !== expected.dir) {
    throw new CursorError('Cursor sort/dir does not match current query');
  }
  return c;
}

export function seekPredicate(cursor: SeekCursor): BoundSql {
  const eqDir = cursor.dir === 'desc' ? '<' : '>';
  switch (cursor.sort) {
    case 'title': {
      const v = cursor.title ?? '';
      return {
        sql: `(COALESCE(title, '') COLLATE NOCASE ${eqDir} ? OR (COALESCE(title, '') COLLATE NOCASE = ? AND media_id ${eqDir} ?))`,
        params: [v, v, cursor.mediaId],
      };
    }
    case 'uploader': {
      const v = cursor.uploader ?? '';
      return {
        sql: `(COALESCE(uploader, '') COLLATE NOCASE ${eqDir} ? OR (COALESCE(uploader, '') COLLATE NOCASE = ? AND media_id ${eqDir} ?))`,
        params: [v, v, cursor.mediaId],
      };
    }
    case 'timestamp': {
      const v = cursor.timestamp ?? '';
      return {
        sql: `(COALESCE(timestamp, '') ${eqDir} ? OR (COALESCE(timestamp, '') = ? AND media_id ${eqDir} ?))`,
        params: [v, v, cursor.mediaId],
      };
    }
    case 'score': {
      const v = cursor.score ?? -1;
      return {
        sql: `(COALESCE(score, -1) ${eqDir} ? OR (COALESCE(score, -1) = ? AND media_id ${eqDir} ?))`,
        params: [v, v, cursor.mediaId],
      };
    }
    case 'media_id':
    default:
      return { sql: `media_id ${eqDir} ?`, params: [cursor.mediaId] };
  }
}
