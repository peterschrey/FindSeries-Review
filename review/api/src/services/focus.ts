import type {
  FocusQuery,
  FocusRelation,
  FocusResponse,
  MediaFilter,
  StatusCounts,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import { computeStatusCounts } from './gallery.js';

function baseFrom(q: FocusQuery): Omit<MediaFilter, 'projectId'> & { projectId: number } {
  return {
    projectId: q.projectId,
    statuses: q.baseFilter?.statuses ?? ['unreviewed', 'unsure'],
    q: q.baseFilter?.q,
    sourceTypes: q.baseFilter?.sourceTypes,
    categoryIds: q.baseFilter?.categoryIds,
    uploader: q.baseFilter?.uploader,
    seriesKey: q.baseFilter?.seriesKey,
    seriesStrategy: q.baseFilter?.seriesStrategy,
    seedKey: q.baseFilter?.seedKey,
    parentMediaId: q.baseFilter?.parentMediaId,
    mediaIds: q.baseFilter?.mediaIds,
  };
}

function relation(
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
    filter,
    note,
  };
}

export function queryFocus(db: ReviewDb, q: FocusQuery): FocusResponse {
  const base = baseFrom(q);
  const relations: FocusRelation[] = [];

  // similar — P1 placeholder (no embedding lookup in P0)
  relations.push(
    relation(
      'similar',
      'Ähnlich',
      { ...base, mediaIds: [] },
      { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 },
      'P1: Similarity noch nicht aktiv',
    ),
  );

  // series — discoveries of focus as parent or shared series key
  const seriesKeys = db
    .prepare(
      `SELECT DISTINCT COALESCE(source_value, query_text) AS sk
       FROM discoveries
       WHERE project_id = ? AND media_id = ?
         AND source_type IN ('filename-series','time-series','filename')
         AND COALESCE(source_value, query_text) IS NOT NULL`,
    )
    .all(q.projectId, q.focusMediaId) as Array<{ sk: string }>;
  if (seriesKeys.length) {
    const sk = seriesKeys[0].sk;
    const filter: MediaFilter = { ...base, seriesKey: sk };
    relations.push(relation('series', 'Serie', filter, computeStatusCounts(db, filter)));
  } else {
    const filter: MediaFilter = { ...base, parentMediaId: q.focusMediaId };
    const counts = computeStatusCounts(db, filter);
    if (counts.total > 0) {
      relations.push(relation('series', 'Serie (Nachbarn)', filter, counts));
    } else {
      relations.push(
        relation('series', 'Serie', filter, counts, 'Keine Serien-Beziehung gefunden'),
      );
    }
  }

  // category — categories of focus media
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
       )`,
    )
    .all(q.projectId, q.focusMediaId, q.projectId, q.projectId, q.focusMediaId) as Array<{
    category_id: number;
  }>;
  if (cats.length) {
    const ids = cats.map((c) => c.category_id);
    const filter: MediaFilter = { ...base, categoryIds: ids };
    const title =
      ids.length === 1
        ? ((
            db.prepare(`SELECT title FROM categories WHERE id = ?`).get(ids[0]) as
              | { title: string }
              | undefined
          )?.title ?? 'Kategorie')
        : `Kategorien (${ids.length})`;
    relations.push(relation('category', title, filter, computeStatusCounts(db, filter)));
  } else {
    relations.push(
      relation(
        'category',
        'Kategorie',
        { ...base, categoryIds: [] },
        { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 },
        'Keine Kategorie-Beziehung',
      ),
    );
  }

  // seed — parent_media_id of focus discoveries, or focus as seed
  const seedParents = db
    .prepare(
      `SELECT DISTINCT parent_media_id AS pid
       FROM discoveries
       WHERE project_id = ? AND media_id = ? AND parent_media_id IS NOT NULL`,
    )
    .all(q.projectId, q.focusMediaId) as Array<{ pid: number }>;
  const seedKey =
    seedParents.length > 0 ? `media:${seedParents[0].pid}` : `media:${q.focusMediaId}`;
  {
    const filter: MediaFilter = { ...base, seedKey };
    relations.push(relation('seed', 'Seed', filter, computeStatusCounts(db, filter)));
  }

  // uploader
  const media = db
    .prepare(`SELECT current_uploader AS uploader FROM media WHERE id = ?`)
    .get(q.focusMediaId) as { uploader: string | null } | undefined;
  if (media?.uploader) {
    const filter: MediaFilter = { ...base, uploader: media.uploader };
    relations.push(
      relation('uploader', `Uploader: ${media.uploader}`, filter, computeStatusCounts(db, filter)),
    );
  } else {
    relations.push(
      relation(
        'uploader',
        'Uploader',
        { ...base, uploader: undefined },
        { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 },
        'Kein Uploader',
      ),
    );
  }

  // provenance — source types of focus
  const types = db
    .prepare(
      `SELECT DISTINCT source_type FROM discoveries
       WHERE project_id = ? AND media_id = ?`,
    )
    .all(q.projectId, q.focusMediaId) as Array<{ source_type: string }>;
  if (types.length) {
    const filter: MediaFilter = {
      ...base,
      sourceTypes: types.map((t) => t.source_type),
    };
    relations.push(
      relation(
        'provenance',
        'Herkunft',
        filter,
        computeStatusCounts(db, filter),
        types.map((t) => t.source_type).join(', '),
      ),
    );
  } else {
    relations.push(
      relation(
        'provenance',
        'Herkunft',
        { ...base, sourceTypes: [] },
        { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 },
        'Keine Discovery-Herkunft',
      ),
    );
  }

  return { focusMediaId: q.focusMediaId, relations };
}
