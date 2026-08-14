import type { MediaFilter, ReviewStatus, SortDir, SortField } from '@findseries/review-shared';

export type BoundSql = { sql: string; params: unknown[] };

/** Category membership with origin_category_id + validated source_value fallback. */
export function categoryMediaSql(projectId: number, categoryIds: number[]): BoundSql {
  if (!categoryIds.length) {
    return { sql: 'SELECT CAST(NULL AS INTEGER) AS media_id WHERE 0', params: [] };
  }
  const placeholders = categoryIds.map(() => '?').join(',');
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

function buildWhere(filter: MediaFilter): { where: string[]; params: unknown[]; joinExtra: string } {
  const params: unknown[] = [];
  const where: string[] = ['pm.project_id = ?'];
  params.push(filter.projectId);

  const statuses = filter.statuses?.length
    ? filter.statuses
    : (['unreviewed', 'unsure'] as ReviewStatus[]);
  where.push(`COALESCE(mrs.status, 'unreviewed') IN (${statuses.map(() => '?').join(',')})`);
  params.push(...statuses);

  if (filter.q && filter.q.trim()) {
    where.push(`(m.title LIKE ? OR IFNULL(m.current_uploader,'') LIKE ?)`);
    const like = `%${filter.q.trim()}%`;
    params.push(like, like);
  }
  if (filter.uploader) {
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
  if (filter.parentMediaId) {
    where.push(`EXISTS (
      SELECT 1 FROM discoveries dn
      WHERE dn.project_id = pm.project_id AND dn.media_id = pm.media_id
        AND dn.parent_media_id = ?
    )`);
    params.push(filter.parentMediaId);
  }
  if (filter.seedKey) {
    where.push(`EXISTS (
      SELECT 1 FROM discoveries ds
      WHERE ds.project_id = pm.project_id AND ds.media_id = pm.media_id
        AND (
          (ds.parent_media_id IS NOT NULL AND ('media:' || ds.parent_media_id) = ?)
          OR (ds.query_text IS NOT NULL AND lower(trim(ds.query_text)) = lower(?))
        )
    )`);
    params.push(filter.seedKey, filter.seedKey);
  }
  if (filter.seriesKey) {
    where.push(`EXISTS (
      SELECT 1 FROM discoveries dser
      WHERE dser.project_id = pm.project_id AND dser.media_id = pm.media_id
        AND dser.source_type IN ('filename-series','time-series','filename')
        AND COALESCE(dser.source_value, dser.query_text) = ?
    )`);
    params.push(filter.seriesKey);
  }

  let joinExtra = '';
  if (filter.categoryIds?.length) {
    const cat = categoryMediaSql(filter.projectId, filter.categoryIds);
    params.unshift(...cat.params);
    joinExtra = `JOIN (${cat.sql}) catf ON catf.media_id = pm.media_id`;
  }
  return { where, params, joinExtra };
}

/** Light projection for counts / id seeks (no downloads lookup). */
export function buildFilteredMediaCte(
  filter: MediaFilter,
  mode: FilterSelectMode = 'page',
): BoundSql {
  const { where, params, joinExtra } = buildWhere(filter);
  const needsMediaJoin =
    mode === 'page' ||
    Boolean(filter.q?.trim()) ||
    Boolean(filter.uploader);

  const mediaJoin = needsMediaJoin ? `JOIN media m ON m.id = pm.media_id` : `JOIN media m ON m.id = pm.media_id`;
  // Always join media — uploader/title filters and page fields need it; SQLite planner is fine.

  const select =
    mode === 'count'
      ? `pm.media_id AS media_id,
  COALESCE(mrs.status, 'unreviewed') AS review_status`
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
${mediaJoin}
LEFT JOIN media_review_status mrs
  ON mrs.project_id = pm.project_id AND mrs.media_id = pm.media_id
${joinExtra}
WHERE ${where.join('\n  AND ')}
`;
  return { sql, params };
}

export function sortClause(sort: SortField, dir: SortDir): string {
  const d = dir === 'desc' ? 'DESC' : 'ASC';
  switch (sort) {
    case 'title':
      return `title COLLATE NOCASE ${d}, media_id ${d}`;
    case 'uploader':
      return `uploader COLLATE NOCASE ${d}, media_id ${d}`;
    case 'timestamp':
      return `timestamp ${d}, media_id ${d}`;
    case 'score':
      return `score ${d}, media_id ${d}`;
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

export function decodeCursor(raw: string): SeekCursor {
  return JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')) as SeekCursor;
}

export function seekPredicate(cursor: SeekCursor): BoundSql {
  const eqDir = cursor.dir === 'desc' ? '<' : '>';
  switch (cursor.sort) {
    case 'title':
      return {
        sql: `(title COLLATE NOCASE ${eqDir} ? OR (title COLLATE NOCASE = ? AND media_id ${eqDir} ?))`,
        params: [cursor.title ?? '', cursor.title ?? '', cursor.mediaId],
      };
    case 'uploader':
      return {
        sql: `(uploader COLLATE NOCASE ${eqDir} ? OR (uploader COLLATE NOCASE = ? AND media_id ${eqDir} ?))`,
        params: [cursor.uploader ?? '', cursor.uploader ?? '', cursor.mediaId],
      };
    case 'timestamp':
      return {
        sql: `(IFNULL(timestamp,'') ${eqDir} ? OR (IFNULL(timestamp,'') = ? AND media_id ${eqDir} ?))`,
        params: [cursor.timestamp ?? '', cursor.timestamp ?? '', cursor.mediaId],
      };
    case 'score':
      return {
        sql: `(IFNULL(score,-1) ${eqDir} ? OR (IFNULL(score,-1) = ? AND media_id ${eqDir} ?))`,
        params: [cursor.score ?? -1, cursor.score ?? -1, cursor.mediaId],
      };
    case 'media_id':
    default:
      return { sql: `media_id ${eqDir} ?`, params: [cursor.mediaId] };
  }
}
