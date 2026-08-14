import type { Dispatch } from 'react';
import type { GroupBy, GroupCard, MediaFilter } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';
import { MiniStatusBar } from './StatusOverview';
import { ThumbImage } from './ThumbImage';

/** Drilldown patch = only the group constraint (AND with globals). */
export function drilldownPatchFromGroup(
  groupBy: GroupBy,
  g: GroupCard,
): Partial<MediaFilter> {
  switch (groupBy) {
    case 'category': {
      const id = Number(g.key);
      return Number.isFinite(id) ? { categoryIds: [id] } : {};
    }
    case 'uploader':
      return { uploader: g.key === '(ohne Uploader)' ? null : g.key };
    case 'series':
      return { seriesKey: g.key };
    case 'provenance': {
      const sourceType = g.key.includes(':') ? g.key.slice(g.key.indexOf(':') + 1) : g.key;
      return { sourceTypes: [sourceType] };
    }
    default:
      return {};
  }
}

export function GroupShelf({
  state,
  dispatch,
  groups,
  loading,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  groups: GroupCard[];
  loading: boolean;
}) {
  return (
    <div className="shelfWrap">
      <div className="shelfTitle">
        <strong>Gruppen</strong>
        <span className="muted">
          {loading ? 'laden…' : `${groups.length} Karten`} · Klick setzt Drilldown (AND)
        </span>
      </div>
      <div className="shelf">
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
                        patch: drilldownPatchFromGroup(state.groupBy, g),
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
        {!loading && groups.length === 0 && (
          <div className="helper">Keine Gruppen für die aktuelle Filtermenge.</div>
        )}
      </div>
    </div>
  );
}
