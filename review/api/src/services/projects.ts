import type { ProjectsResponse } from '@findseries/review-shared';
import type { ReviewDb } from '../db.js';

export function listProjects(db: ReviewDb): ProjectsResponse {
  const rows = db
    .prepare(
      `SELECT id, name, slug
       FROM projects
       ORDER BY name COLLATE NOCASE ASC, id ASC`,
    )
    .all() as Array<{ id: number; name: string; slug: string | null }>;
  return {
    projects: rows.map((r) => ({
      id: Number(r.id),
      name: String(r.name ?? ''),
      slug: r.slug == null || r.slug === '' ? null : String(r.slug),
    })),
  };
}
