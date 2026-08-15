import type {
  CategoryNode,
  CategoryNodeQuery,
  FacetsResponse,
  MediaFilter,
} from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';
import {
  buildFilteredMediaCte,
  categoryMediaSql,
  resolvedCategoryMembershipSql,
} from '../sql/filters.js';

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

/**
 * Set-based media counts for a list of category nodes (no N+1).
 * CATEGORY_GRAPH membership via resolvedCategoryMembershipSql.
 */
export function batchCountMediaForCategoryNodes(
  db: ReviewDb,
  projectId: number,
  nodeIds: number[],
  filter: MediaFilter,
  opts: { includeDescendants: boolean; parentCategoryId?: number | null },
): Map<number, number> {
  const out = new Map<number, number>();
  if (!nodeIds.length) return out;

  // Strip category dimensions — tree counts are against the global filter only.
  const baseFilter: MediaFilter = {
    projectId,
    statuses: filter.statuses,
    q: filter.q,
    sourceTypes: filter.sourceTypes,
    uploader: filter.uploader,
    seriesKey: filter.seriesKey,
    seedKey: filter.seedKey,
    parentMediaId: filter.parentMediaId,
    mediaIds: filter.mediaIds,
  };
  const fm = buildFilteredMediaCte(baseFilter, 'count');
  const resolved = resolvedCategoryMembershipSql(projectId);
  const includeDescendants = opts.includeDescendants;

  if (!includeDescendants) {
    const placeholders = nodeIds.map(() => '?').join(',');
    const rows = db
      .prepare(
        `WITH fm AS (${fm.sql}),
              resolved AS (${resolved.sql})
         SELECT r.category_id AS category_id, COUNT(DISTINCT fm.media_id) AS c
         FROM fm
         JOIN resolved r ON r.media_id = fm.media_id
         WHERE r.category_id IN (${placeholders})
         GROUP BY r.category_id`,
      )
      .all(...fm.params, ...resolved.params, ...nodeIds) as Array<{ category_id: number; c: number }>;
    for (const id of nodeIds) out.set(id, 0);
    for (const r of rows) out.set(Number(r.category_id), Number(r.c));
    return out;
  }

  // Descendants: map membership categories onto the listed nodes via ancestor climb.
  // Root listing (parent null): climb from every project category to its forest root.
  // Child listing: expand subtrees under each listed child of parentCategoryId.
  if (opts.parentCategoryId == null) {
    const rows = db
      .prepare(
        `WITH fm AS (${fm.sql}),
              resolved AS (${resolved.sql}),
              root_of AS (
                WITH RECURSIVE climb(id, root_id) AS (
                  SELECT pc.category_id, pc.category_id
                  FROM project_categories pc
                  WHERE pc.project_id = ? AND pc.parent_category_id IS NULL
                  UNION ALL
                  SELECT pc.category_id, climb.root_id
                  FROM project_categories pc
                  JOIN climb ON pc.parent_category_id = climb.id
                  WHERE pc.project_id = ?
                )
                SELECT id AS category_id, root_id FROM climb
              )
         SELECT root_of.root_id AS category_id, COUNT(DISTINCT fm.media_id) AS c
         FROM fm
         JOIN resolved r ON r.media_id = fm.media_id
         JOIN root_of ON root_of.category_id = r.category_id
         GROUP BY root_of.root_id`,
      )
      .all(...fm.params, ...resolved.params, projectId, projectId) as Array<{
        category_id: number;
        c: number;
      }>;
    for (const id of nodeIds) out.set(id, 0);
    const wanted = new Set(nodeIds);
    for (const r of rows) {
      const id = Number(r.category_id);
      if (wanted.has(id)) out.set(id, Number(r.c));
    }
    return out;
  }

  const parentId = opts.parentCategoryId;
  const rows = db
    .prepare(
      `WITH fm AS (${fm.sql}),
            resolved AS (${resolved.sql}),
            sub(node_id, id) AS (
              SELECT pc.category_id, pc.category_id
              FROM project_categories pc
              WHERE pc.project_id = ? AND pc.parent_category_id = ?
              UNION ALL
              SELECT sub.node_id, pc.category_id
              FROM project_categories pc
              JOIN sub ON pc.parent_category_id = sub.id
              WHERE pc.project_id = ?
            )
       SELECT sub.node_id AS category_id, COUNT(DISTINCT fm.media_id) AS c
       FROM fm
       JOIN resolved r ON r.media_id = fm.media_id
       JOIN sub ON sub.id = r.category_id
       GROUP BY sub.node_id`,
    )
    .all(...fm.params, ...resolved.params, projectId, parentId, projectId) as Array<{
      category_id: number;
      c: number;
    }>;
  for (const id of nodeIds) out.set(id, 0);
  const wanted = new Set(nodeIds);
  for (const r of rows) {
    const id = Number(r.category_id);
    if (wanted.has(id)) out.set(id, Number(r.c));
  }
  return out;
}

export function listCategoryNodes(db: ReviewDb, q: CategoryNodeQuery): CategoryNode[] {
  let nodes: CatRow[];
  const listingRoots = q.parentCategoryId == null;
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

  let counts: Map<number, number> | null = null;
  if (q.filter) {
    const includeDescendants = q.filter.categoryIncludeDescendants !== false;
    const nodeIds = nodes.map((n) => n.category_id);
    counts = batchCountMediaForCategoryNodes(
      db,
      q.projectId,
      nodeIds,
      {
        projectId: q.projectId,
        statuses: q.filter.statuses ?? ['unreviewed', 'unsure'],
        q: q.filter.q,
        sourceTypes: q.filter.sourceTypes,
        uploader: q.filter.uploader,
        seriesKey: q.filter.seriesKey,
        seedKey: q.filter.seedKey,
        parentMediaId: q.filter.parentMediaId,
        mediaIds: q.filter.mediaIds,
      },
      {
        includeDescendants,
        parentCategoryId: listingRoots ? null : q.parentCategoryId,
      },
    );
  }

  return nodes.map((r) => {
    const mediaCount = counts ? (counts.get(r.category_id) ?? 0) : undefined;
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
