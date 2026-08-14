import { useCallback, useEffect, useMemo, useRef, useState, type Dispatch } from 'react';
import type { CategoryNode, FacetsResponse } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';
import { fetchCategoryNodes } from '../api/client';
import { categoryTreeCacheKey, toggleExpandedId } from './categoryTreeState';

export function LeftNav({
  state,
  dispatch,
  facets,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  facets: FacetsResponse | null;
}) {
  const [roots, setRoots] = useState<CategoryNode[]>([]);
  const [expandedIds, setExpandedIds] = useState<Set<number>>(() => new Set());
  /** Children for the current cache generation only (keyed by categoryId). */
  const [childrenCache, setChildrenCache] = useState<Record<number, CategoryNode[]>>({});

  const cacheKey = useMemo(
    () =>
      categoryTreeCacheKey({
        projectId: state.projectId,
        statuses: state.statuses,
        q: state.q,
        sourceTypes: state.sourceTypes,
        uploader: state.uploader,
        categoryIncludeDescendants: state.categoryIncludeDescendants,
      }),
    [
      state.projectId,
      state.statuses,
      state.q,
      state.sourceTypes,
      state.uploader,
      state.categoryIncludeDescendants,
    ],
  );

  const prevProjectRef = useRef(state.projectId);
  const prevKeyRef = useRef(cacheKey);

  useEffect(() => {
    if (prevProjectRef.current !== state.projectId) {
      setExpandedIds(new Set());
      setChildrenCache({});
      prevProjectRef.current = state.projectId;
    } else if (prevKeyRef.current !== cacheKey) {
      setChildrenCache({});
    }
    prevKeyRef.current = cacheKey;
  }, [state.projectId, cacheKey]);

  const countFilter = useMemo(
    () => ({
      statuses: state.statuses,
      q: state.q.trim() || undefined,
      sourceTypes: state.sourceTypes,
      uploader: state.uploader,
      categoryIncludeDescendants: state.categoryIncludeDescendants,
    }),
    [
      state.statuses,
      state.q,
      state.sourceTypes,
      state.uploader,
      state.categoryIncludeDescendants,
    ],
  );

  const loadRoots = useCallback(
    async (signal?: AbortSignal) => {
      const res = await fetchCategoryNodes(
        {
          projectId: state.projectId,
          parentCategoryId: null,
          filter: countFilter,
        },
        signal,
      );
      setRoots(res.nodes);
    },
    [state.projectId, countFilter],
  );

  useEffect(() => {
    const ac = new AbortController();
    loadRoots(ac.signal).catch(() => {
      /* ignore */
    });
    return () => ac.abort();
  }, [loadRoots, cacheKey]);

  const toggleExpand = async (node: CategoryNode) => {
    if (expandedIds.has(node.categoryId)) {
      setExpandedIds((prev) => toggleExpandedId(prev, node.categoryId));
      return;
    }
    setExpandedIds((prev) => toggleExpandedId(prev, node.categoryId));
    if (childrenCache[node.categoryId]) return;
    const res = await fetchCategoryNodes({
      projectId: state.projectId,
      parentCategoryId: node.categoryId,
      filter: countFilter,
    });
    setChildrenCache((c) => ({ ...c, [node.categoryId]: res.nodes }));
  };

  const toggleCategory = (id: number, ctrl: boolean) => {
    const current = state.categoryIds ?? [];
    let next: number[];
    if (ctrl) {
      next = current.includes(id) ? current.filter((x) => x !== id) : [...current, id];
    } else {
      next = current.length === 1 && current[0] === id ? [] : [id];
    }
    dispatch({
      type: 'set_category_ids',
      categoryIds: next.length ? next : undefined,
    });
  };

  const toggleSourceType = (sourceType: string, ctrl: boolean) => {
    const current = state.sourceTypes ?? [];
    let next: string[];
    if (ctrl) {
      next = current.includes(sourceType)
        ? current.filter((x) => x !== sourceType)
        : [...current, sourceType];
    } else {
      next = current.length === 1 && current[0] === sourceType ? [] : [sourceType];
    }
    dispatch({
      type: 'set_source_types',
      sourceTypes: next.length ? next : undefined,
    });
  };

  const renderNode = (node: CategoryNode, depth: number) => {
    const selected = state.categoryIds?.includes(node.categoryId);
    const expanded = expandedIds.has(node.categoryId);
    const children = childrenCache[node.categoryId] ?? [];
    return (
      <div key={node.categoryId} style={{ marginLeft: depth * 8 }}>
        <div className="catRow">
          {node.hasChildren ? (
            <button type="button" className="catExp" onClick={() => void toggleExpand(node)}>
              {expanded ? '▾' : '▸'}
            </button>
          ) : (
            <span className="catExp spacer" />
          )}
          <button
            type="button"
            className={`facet ${selected ? 'active' : ''}`}
            onClick={(e) => toggleCategory(node.categoryId, e.ctrlKey || e.metaKey)}
          >
            <span>{node.title}</span>
            <span className="count">{node.mediaCount ?? node.memberCountCached ?? node.childCount}</span>
          </button>
        </div>
        {expanded && children.map((ch) => renderNode(ch, depth + 1))}
      </div>
    );
  };

  return (
    <aside className="left">
      <div className="section">
        <h3>Herkunft</h3>
        <div className="helper">Ctrl+Klick = Mehrfach (OR)</div>
        {(facets?.provenance ?? []).slice(0, 30).map((p) => {
          const active = state.sourceTypes?.includes(p.sourceType);
          return (
            <button
              key={p.sourceType}
              type="button"
              className={`facet ${active ? 'active' : ''}`}
              onClick={(e) => toggleSourceType(p.sourceType, e.ctrlKey || e.metaKey)}
            >
              <span>{p.sourceType}</span>
              <span className="count">{p.count}</span>
            </button>
          );
        })}
      </div>
      <div className="section">
        <h3>Uploader</h3>
        {(facets?.uploaders ?? []).slice(0, 20).map((u, i) => {
          const label = u.uploader ?? '(ohne Uploader)';
          const key = u.uploader ?? '__empty__';
          const active =
            state.uploader === u.uploader ||
            (u.uploader == null && state.uploader === null);
          return (
            <button
              key={key + i}
              type="button"
              className={`facet ${active ? 'active' : ''}`}
              onClick={() =>
                dispatch({
                  type: 'set_uploader',
                  uploader: active ? undefined : u.uploader,
                })
              }
            >
              <span>{label}</span>
              <span className="count">{u.count}</span>
            </button>
          );
        })}
      </div>
      <div className="section">
        <h3>Kategorien</h3>
        <label className="helper" style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
          <input
            type="checkbox"
            checked={state.categoryIncludeDescendants}
            onChange={() => dispatch({ type: 'toggle_category_include_descendants' })}
          />
          Unterkategorien einschließen
        </label>
        <div className="helper">Ctrl+Klick = Mehrfach (Union)</div>
        {roots.map((n) => renderNode(n, 0))}
        {!roots.length && <div className="helper">Keine Kategorie-Roots.</div>}
        <div className="helper" style={{ marginTop: 8 }}>
          Hinweis: `project_categories` speichert einen Parent je Kategorie; Medienunion bei
          Multi-Select ist die relevante Überlappungs-Semantik (kein erfundener Multi-Parent-Tree).
        </div>
      </div>
    </aside>
  );
}
