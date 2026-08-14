import type { Dispatch } from 'react';
import type { FacetsResponse } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';

export function LeftNav({
  state,
  dispatch,
  facets,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  facets: FacetsResponse | null;
}) {
  return (
    <aside className="left">
      <div className="section">
        <h3>Herkunft</h3>
        {(facets?.provenance ?? []).slice(0, 20).map((p) => {
          const active = state.sourceTypes?.includes(p.sourceType);
          return (
            <button
              key={p.sourceType}
              type="button"
              className={`facet ${active ? 'active' : ''}`}
              onClick={() =>
                dispatch({
                  type: 'set_source_types',
                  sourceTypes: active ? undefined : [p.sourceType],
                })
              }
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
        <div className="helper">
          Lazy Category-Navigator folgt FRV-28; Drilldown über Gruppenkarte „Kategorie“.
        </div>
      </div>
    </aside>
  );
}
