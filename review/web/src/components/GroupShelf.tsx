import { useEffect, useRef, useState, type Dispatch } from 'react';
import type { FocusRelation, GroupBy, GroupCard, MediaCard, MediaFilter } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';
import { toGlobalMediaFilter } from '../state/reviewState';
import { MiniStatusBar } from './StatusOverview';
import { ThumbImage } from './ThumbImage';
import { fetchFocus } from '../api/client';

/** Drilldown patch = only the group constraint (AND with globals). */
export function drilldownPatchFromGroup(
  groupBy: GroupBy,
  g: GroupCard,
  opts?: { categoryIncludeDescendants?: boolean },
): Partial<MediaFilter> {
  switch (groupBy) {
    case 'category': {
      const id = Number(g.key);
      return Number.isFinite(id)
        ? {
            categoryIds: [id],
            categoryIncludeDescendants: opts?.categoryIncludeDescendants,
          }
        : {};
    }
    case 'uploader':
      return { uploader: g.key === '(ohne Uploader)' ? null : g.key };
    case 'series':
      return { seriesKey: g.key };
    case 'seed':
      return { seedKey: g.key };
    case 'provenance': {
      const sourceType = g.key.includes(':') ? g.key.slice(g.key.indexOf(':') + 1) : g.key;
      return { sourceTypes: [sourceType] };
    }
    default:
      return {};
  }
}

/** Extract only the relation delta for UI patch (not the full base filter). */
export function relationToPatch(rel: FocusRelation): Partial<MediaFilter> {
  if (!rel.filter) return {};
  const f = rel.filter;
  switch (rel.kind) {
    case 'category':
      if (f.alsoCategoryIds?.length) {
        return {
          categoryIds: f.alsoCategoryIds,
          categoryIncludeDescendants: f.alsoCategoryIncludeDescendants,
        };
      }
      return {
        categoryIds: f.categoryIds,
        categoryIncludeDescendants: f.categoryIncludeDescendants,
      };
    case 'provenance':
      if (f.alsoSourceTypes?.length) {
        return { sourceTypes: f.alsoSourceTypes };
      }
      return { sourceTypes: f.sourceTypes };
    case 'series':
      return f.seriesKey ? { seriesKey: f.seriesKey } : {};
    case 'seed':
      return f.seedKey ? { seedKey: f.seedKey } : {};
    case 'uploader':
      return { uploader: f.uploader };
    case 'similar':
    default:
      return {};
  }
}

export function GroupShelf({
  state,
  dispatch,
  groups,
  loading,
  galleryItems,
  mutationEpoch = 0,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  groups: GroupCard[];
  loading: boolean;
  galleryItems: MediaCard[];
  /** Bumps after bulk/undo so focus relation counts refresh (FRV-37 prep). */
  mutationEpoch?: number;
}) {
  const [relations, setRelations] = useState<FocusRelation[]>([]);
  const [focusLoading, setFocusLoading] = useState(false);
  const focusReq = useRef(0);

  useEffect(() => {
    if (state.focusMediaId == null) {
      setRelations([]);
      return;
    }
    const ac = new AbortController();
    const id = ++focusReq.current;
    setFocusLoading(true);
    fetchFocus(
      {
        projectId: state.projectId,
        focusMediaId: state.focusMediaId,
        baseFilter: toGlobalMediaFilter(state),
      },
      ac.signal,
    )
      .then((res) => {
        if (!ac.signal.aborted && id === focusReq.current) setRelations(res.relations);
      })
      .catch(() => {
        /* ignore */
      })
      .finally(() => {
        if (!ac.signal.aborted && id === focusReq.current) setFocusLoading(false);
      });
    return () => ac.abort();
  }, [
    state.focusMediaId,
    state.projectId,
    state.statuses,
    state.q,
    state.sourceTypes,
    state.categoryIds,
    state.categoryIncludeDescendants,
    state.uploader,
    mutationEpoch,
  ]);

  const focusItem =
    galleryItems.find((i) => i.mediaId === state.focusMediaId) ??
    (state.focusMediaId
      ? ({
          mediaId: state.focusMediaId,
          title: `#${state.focusMediaId}`,
          uploader: null,
          timestamp: null,
          score: null,
          reviewStatus: 'unreviewed' as const,
        } satisfies MediaCard)
      : null);

  const clearFocus = () => {
    dispatch({ type: 'set_focus', mediaId: null });
    dispatch({ type: 'clear_focus_relation' });
  };

  return (
    <div className="shelfWrap">
      <div className="shelfTitle">
        <strong>Gruppen</strong>
        <span className="muted">
          {loading || focusLoading ? 'laden…' : `${groups.length} Karten`}
          {state.focusMediaId != null ? ' · Fokus aktiv' : ''} · Klick setzt Drilldown (AND)
        </span>
      </div>
      <div className="shelf">
        {focusItem && (
          <div className="shelfCard focusCard active" data-testid="focus-card">
            <button type="button" className="focusX" aria-label="Fokus aufheben" onClick={clearFocus}>
              ×
            </button>
            <div className="relTop">
              <div>
                <div className="relTitle">Fokus</div>
                <div className="relSub">#{focusItem.mediaId}</div>
              </div>
            </div>
            <div className="thumbsRow">
              <ThumbImage mediaId={focusItem.mediaId} className="miniThumb" size={80} />
            </div>
            <div className="helper">{focusItem.title ?? ''}</div>
          </div>
        )}

        {state.focusMediaId != null &&
          relations.map((rel) => {
            const active = state.focusRelation?.key === `${rel.kind}:${rel.label}`;
            const clickable = rel.available && rel.filter != null;
            return (
              <button
                key={`${rel.kind}-${rel.label}`}
                type="button"
                className={`shelfCard relationCard ${active ? 'active' : ''} ${!clickable ? 'disabled' : ''}`}
                disabled={!clickable}
                title={rel.note ?? rel.kind}
                onClick={() => {
                  if (!clickable) return;
                  dispatch({
                    type: 'set_focus_relation',
                    relation: active
                      ? null
                      : {
                          kind: 'focus-relation',
                          key: `${rel.kind}:${rel.label}`,
                          label: `Fokus · ${rel.label}`,
                          patch: relationToPatch(rel),
                        },
                  });
                }}
              >
                <div className="relTop">
                  <div>
                    <div className="relTitle">{rel.label}</div>
                    <div className="relSub">{rel.available ? rel.kind : `${rel.kind} · P1`}</div>
                  </div>
                  <div className="relCount">{rel.total}</div>
                </div>
                <MiniStatusBar counts={rel.statusCounts} />
              </button>
            );
          })}

        {groups.map((g) => {
          const active = state.drilldown?.key === g.key;
          return (
            <button
              key={g.key}
              type="button"
              className={`shelfCard ${active ? 'active' : ''}`}
              onClick={() =>
                dispatch({
                  type: 'set_drilldown',
                  drilldown: active
                    ? null
                    : {
                        kind: 'group',
                        key: g.key,
                        label: g.label,
                        patch: drilldownPatchFromGroup(state.groupBy, g, {
                          categoryIncludeDescendants: state.categoryIncludeDescendants,
                        }),
                      },
                })
              }
            >
              <div className="relTop">
                <div>
                  <div className="relTitle">{g.label}</div>
                  <div className="relSub">{g.key}</div>
                </div>
                <div className="relCount">{g.total}</div>
              </div>
              <MiniStatusBar counts={g.statusCounts} />
              <div className="thumbsRow">
                {g.sampleMedia.slice(0, 4).map((m) => (
                  <ThumbImage key={m.mediaId} mediaId={m.mediaId} className="miniThumb" size={80} />
                ))}
              </div>
            </button>
          );
        })}
        {!loading && groups.length === 0 && state.focusMediaId == null && (
          <div className="helper">Keine Gruppen für die aktuelle Filtermenge.</div>
        )}
      </div>
    </div>
  );
}
