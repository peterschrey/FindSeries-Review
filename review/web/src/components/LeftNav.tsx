import { useCallback, useEffect, useState, type Dispatch } from 'react';
import type { CategoryNode, FacetsResponse } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';
import { toGlobalMediaFilter } from '../state/reviewState';
import { fetchCategoryNodes } from '../api/client';

type TreeNode = CategoryNode & { expanded?: boolean; children?: TreeNode[] };

export function LeftNav({
  state,
  dispatch,
  facets,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  facets: FacetsResponse | null;
}) {
  const [roots, setRoots] = useState<TreeNode[]>([]);
  const [childCache, setChildCache] = useState<Record<number, CategoryNode[]>>({});

  const loadRoots = useCallback(async (signal?: AbortSignal) => {
    const base = toGlobalMediaFilter(state);
    const res = await fetchCategoryNodes(
      {
        projectId: state.projectId,
        parentCategoryId: null,
        filter: {
          statuses: base.statuses,
          q: base.q,
          sourceTypes: base.sourceTypes,
          uploader: base.uploader,
        },
      },
      signal,
    );
    setRoots(res.nodes.map((n) => ({ ...n, expanded: false })));
  }, [state]);

  useEffect(() => {
    const ac = new AbortController();
    loadRoots(ac.signal).catch(() => {
      /* ignore */
    });
    return () => ac.abort();
  }, [loadRoots]);

  const toggleExpand = async (node: TreeNode) => {
    if (node.expanded) {
      setRoots((prev) =>
        prev.map((r) => (r.categoryId === node.categoryId ? { ...r, expanded: false } : r)),
      );
      return;
    }
    let children = childCache[node.categoryId];
    if (!children) {
      const res = await fetchCategoryNodes({
        projectId: state.projectId,
        parentCategoryId: node.categoryId,
        filter: {
          statuses: state.statuses,
          q: state.q.trim() || undefined,
          sourceTypes: state.sourceTypes,
          uploader: state.uploader,
        },
      });
      children = res.nodes;
      setChildCache((c) => ({ ...c, [node.categoryId]: children! }));
    }
    setRoots((prev) =>
      prev.map((r) =>
        r.categoryId === node.categoryId ? { ...r, expanded: true, children } : r,
      ),
    );
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
      // Multi within facet = OR
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

  const renderNode = (node: TreeNode, depth: number) => {
    const selected = state.categoryIds?.includes(node.categoryId);
    return (
      <div key={node.categoryId} style={{ marginLeft: depth * 8 }}>
        <div className="catRow">
          {node.hasChildren ? (
            <button type="button" className="catExp" onClick={() => void toggleExpand(node)}>
              {node.expanded ? '▾' : '▸'}
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
        {node.expanded &&
          (node.children ?? []).map((ch) => renderNode({ ...ch, expanded: false }, depth + 1))}
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
