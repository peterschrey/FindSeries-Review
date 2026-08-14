import type {
  CategoryNode,
  CategoryNodeQuery,
  FacetsResponse,
  MediaFilter,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import { buildFilteredMediaCte, categoryMediaSql } from '../sql/filters.js';

type CatRow = {
  category_id: number;
  title: string;
  depth: number;
  member_count: number | null;
  child_count: number;
};

const NODE_SELECT = `
SELECT pc.category_id, c.title, pc.depth, pc.member_count,
       (SELECT COUNT(*) FROM project_categories ch
        WHERE ch.project_id = pc.project_id AND ch.parent_category_id = pc.category_id) AS child_count
FROM project_categories pc
JOIN categories c ON c.id = pc.category_id`;

export function listCategoryNodes(db: ReviewDb, q: CategoryNodeQuery): CategoryNode[] {
  let nodes: CatRow[];
  if (q.parentCategoryId != null) {
    nodes = db
      .prepare(
        `${NODE_SELECT}
         WHERE pc.project_id = ? AND pc.parent_category_id = ?
         ORDER BY c.title COLLATE NOCASE`,
      )
      .all(q.projectId, q.parentCategoryId) as CatRow[];
  } else {
    const roots = db
      .prepare(
        `${NODE_SELECT}
         WHERE pc.project_id = ? AND pc.parent_category_id IS NULL
         ORDER BY c.title COLLATE NOCASE`,
      )
      .all(q.projectId) as CatRow[];
    nodes =
      roots.length > 0
        ? roots
        : (db
            .prepare(
              `${NODE_SELECT}
               WHERE pc.project_id = ? AND pc.depth = 0
               ORDER BY c.title COLLATE NOCASE`,
            )
            .all(q.projectId) as CatRow[]);
  }

  return nodes.map((r) => {
    let mediaCount: number | undefined;
    if (q.filter) {
      const filter: MediaFilter = {
        projectId: q.projectId,
        statuses: q.filter.statuses ?? ['unreviewed', 'unsure'],
        q: q.filter.q,
        sourceTypes: q.filter.sourceTypes,
        categoryIds: [r.category_id],
        categoryIncludeDescendants: q.filter.categoryIncludeDescendants,
        uploader: q.filter.uploader,
        seriesKey: q.filter.seriesKey,
        seedKey: q.filter.seedKey,
        parentMediaId: q.filter.parentMediaId,
        mediaIds: q.filter.mediaIds,
      };
      const base = buildFilteredMediaCte(filter);
      const cnt = db
        .prepare(`WITH fm AS (${base.sql}) SELECT COUNT(*) AS c FROM fm`)
        .get(...base.params) as { c: number };
      mediaCount = Number(cnt.c);
    }
    return {
      categoryId: r.category_id,
      title: r.title,
      depth: r.depth,
      childCount: Number(r.child_count),
      memberCountCached: r.member_count == null ? null : Number(r.member_count),
      mediaCount,
      hasChildren: Number(r.child_count) > 0,
    };
  });
}

/** Exact distinct media count for a category subtree (CATEGORY_GRAPH semantics). */
export function countCategorySubtree(db: ReviewDb, projectId: number, categoryId: number): number {
  const cat = categoryMediaSql(projectId, [categoryId]);
  const row = db.prepare(`SELECT COUNT(*) AS c FROM (${cat.sql})`).get(...cat.params) as {
    c: number;
  };
  return Number(row.c);
}

export function queryFacets(db: ReviewDb, filter: MediaFilter): FacetsResponse {
  // Provenance facet: exclude own dimension (sourceTypes); keep alsoSourceTypes (drilldown AND).
  const provenanceFilter: MediaFilter = {
    ...filter,
    sourceTypes: undefined,
  };
  const provenanceBase = buildFilteredMediaCte(provenanceFilter);
  const provenance = db
    .prepare(
      `WITH fm AS (${provenanceBase.sql})
       SELECT d.source_type AS sourceType,
              COALESCE(rpm.family, 'unknown') AS family,
              COUNT(DISTINCT fm.media_id) AS count
       FROM fm
       JOIN discoveries d ON d.project_id = ? AND d.media_id = fm.media_id
       LEFT JOIN review_provenance_type_map rpm ON rpm.source_type = d.source_type
       GROUP BY d.source_type, family
       ORDER BY count DESC
       LIMIT 100`,
    )
    .all(...provenanceBase.params, filter.projectId) as Array<{
    sourceType: string;
    family: string;
    count: number;
  }>;

  // Uploader facet: exclude uploader filter (own dimension).
  const uploaderFilter: MediaFilter = {
    ...filter,
    uploader: undefined,
  };
  const uploaderBase = buildFilteredMediaCte(uploaderFilter);
  const uploaders = db
    .prepare(
      `WITH fm AS (${uploaderBase.sql})
       SELECT CASE
                WHEN uploader IS NULL OR uploader = '' THEN NULL
                ELSE uploader
              END AS uploader,
              COUNT(*) AS count
       FROM fm
       GROUP BY CASE
                  WHEN uploader IS NULL OR uploader = '' THEN NULL
                  ELSE uploader
                END
       ORDER BY count DESC
       LIMIT 100`,
    )
    .all(...uploaderBase.params) as Array<{ uploader: string | null; count: number }>;

  return {
    provenance: provenance.map((p) => ({
      sourceType: p.sourceType,
      family: p.family,
      count: Number(p.count),
    })),
    uploaders: uploaders.map((u) => ({
      uploader: u.uploader,
      count: Number(u.count),
    })),
  };
}
