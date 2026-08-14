import type { Dispatch } from 'react';
import type { GroupCard } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';
import { MiniStatusBar } from './StatusOverview';
import { ThumbImage } from './ThumbImage';

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
          {loading ? 'laden…' : `${groups.length} Karten`} · Klick setzt Drilldown
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
                        patch: g.drilldown,
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
