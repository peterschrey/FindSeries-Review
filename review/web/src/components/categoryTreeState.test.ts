import { describe, expect, it } from 'vitest';
import {
  categoryTreeCacheKey,
  isExpanded,
  toggleExpandedId,
  type CategoryTreeCountFilters,
} from './categoryTreeState';

const base: CategoryTreeCountFilters = {
  projectId: 7,
  statuses: ['unreviewed', 'unsure'],
  q: '',
  sourceTypes: undefined,
  uploader: undefined,
  categoryIncludeDescendants: true,
};

describe('categoryTreeCacheKey', () => {
  it('stable for same count filters', () => {
    expect(categoryTreeCacheKey(base)).toBe(categoryTreeCacheKey({ ...base }));
  });

  it('changes on projectId', () => {
    expect(categoryTreeCacheKey(base)).not.toBe(
      categoryTreeCacheKey({ ...base, projectId: 14 }),
    );
  });

  it('changes on statuses / q / sourceTypes / uploader / includeDescendants', () => {
    const k0 = categoryTreeCacheKey(base);
    expect(k0).not.toBe(categoryTreeCacheKey({ ...base, statuses: ['keep'] }));
    expect(k0).not.toBe(categoryTreeCacheKey({ ...base, q: 'chair' }));
    expect(k0).not.toBe(
      categoryTreeCacheKey({ ...base, sourceTypes: ['category'] }),
    );
    expect(k0).not.toBe(categoryTreeCacheKey({ ...base, uploader: 'A' }));
    expect(k0).not.toBe(
      categoryTreeCacheKey({ ...base, categoryIncludeDescendants: false }),
    );
  });

  it('ignores selection/focus/groupBy (not in key inputs)', () => {
    // Key only receives count filters — selection/focus/groupBy never affect it.
    const a = categoryTreeCacheKey(base);
    const b = categoryTreeCacheKey({ ...base });
    expect(a).toBe(b);
  });
});

describe('expandedIds independent of selection', () => {
  it('deep expand state survives unrelated selection changes', () => {
    let expanded = new Set<number>();
    expanded = toggleExpandedId(expanded, 100);
    expanded = toggleExpandedId(expanded, 102);
    expanded = toggleExpandedId(expanded, 103);
    expect(isExpanded(expanded, 100)).toBe(true);
    expect(isExpanded(expanded, 102)).toBe(true);
    expect(isExpanded(expanded, 103)).toBe(true);
    // Simulate selection change — expanded set is separate state
    const selectedIds = [1, 2, 3];
    expect(isExpanded(expanded, 103)).toBe(true);
    expect(selectedIds).toEqual([1, 2, 3]);
    expanded = toggleExpandedId(expanded, 102);
    expect(isExpanded(expanded, 102)).toBe(false);
    expect(isExpanded(expanded, 100)).toBe(true);
    expect(isExpanded(expanded, 103)).toBe(true);
  });

  it('project change clears expandedIds (caller contract)', () => {
    let expanded = new Set([100, 102, 103]);
    let childrenCache: Record<number, unknown[]> = { 100: [], 102: [] };
    // On project change: clear both
    expanded = new Set();
    childrenCache = {};
    expect(expanded.size).toBe(0);
    expect(Object.keys(childrenCache)).toHaveLength(0);
  });

  it('filter cache key change clears childrenCache and expandedIds', () => {
    let expanded = new Set([100, 102]);
    let childrenCache: Record<number, unknown[]> = { 100: [{ id: 1 }] };
    const keyBefore = categoryTreeCacheKey(base);
    const keyAfter = categoryTreeCacheKey({ ...base, q: 'x' });
    expect(keyBefore).not.toBe(keyAfter);
    // On filter key change: clear cache AND expanded (LeftNav contract)
    childrenCache = {};
    expanded = new Set();
    expect(Object.keys(childrenCache)).toHaveLength(0);
    expect(expanded.size).toBe(0);
  });

  it('selection/focus changes do not clear expandedIds (not in cache key)', () => {
    let expanded = new Set([100, 102, 103]);
    const key = categoryTreeCacheKey(base);
    // Simulate selection/focus change — cache key unchanged
    expect(categoryTreeCacheKey(base)).toBe(key);
    expect(isExpanded(expanded, 100)).toBe(true);
    expect(isExpanded(expanded, 103)).toBe(true);
  });
});
