import type { ReviewStatus } from '@findseries/review-shared';

/** Count-relevant inputs for category tree cache (not selection/focus/groupBy). */
export type CategoryTreeCountFilters = {
  projectId: number;
  statuses: ReviewStatus[] | undefined;
  q: string;
  sourceTypes: string[] | undefined;
  uploader: string | null | undefined;
  categoryIncludeDescendants: boolean;
};

/** Stable cache key: project + count filters only. */
export function categoryTreeCacheKey(f: CategoryTreeCountFilters): string {
  return JSON.stringify({
    projectId: f.projectId,
    statuses: f.statuses,
    q: f.q.trim() || undefined,
    sourceTypes: f.sourceTypes,
    uploader: f.uploader,
    categoryIncludeDescendants: f.categoryIncludeDescendants,
  });
}

export function toggleExpandedId(expanded: ReadonlySet<number>, id: number): Set<number> {
  const next = new Set(expanded);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  return next;
}

export function isExpanded(expanded: ReadonlySet<number>, id: number): boolean {
  return expanded.has(id);
}
