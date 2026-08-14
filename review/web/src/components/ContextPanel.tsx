import type { Dispatch } from 'react';
import type { MediaCard } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';
import { ThumbImage } from './ThumbImage';

export function ContextPanel({
  state,
  dispatch,
  items,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  items: MediaCard[];
}) {
  const selected = items.filter((i) => state.selectedIds.includes(i.mediaId));
  const primary =
    selected[0] ??
    items.find((i) => i.mediaId === state.focusMediaId) ??
    null;

  let mode = 'Keine Auswahl';
  if (state.focusMediaId && selected.length === 0) mode = 'Fokus aktiv';
  else if (selected.length === 1) mode = 'Einzelbild';
  else if (selected.length > 1) mode = `Mehrfachauswahl (${selected.length})`;

  return (
    <aside className="right">
      <div className="section">
        <h3>Kontext</h3>
        <div className="helper">{mode}</div>
        {state.focusMediaId != null && (
          <div style={{ marginTop: 8 }}>
            <button
              type="button"
              className="btn"
              onClick={() => dispatch({ type: 'set_focus', mediaId: null })}
            >
              Fokus aufheben (vorläufig)
            </button>
          </div>
        )}
      </div>

      <div className="section">
        <h3>Aktionen</h3>
        <div className="actionrow">
          <button type="button" className="action keep" disabled title="FRV-22/23">
            K Behalten
          </button>
          <button type="button" className="action reject" disabled title="FRV-22/23">
            R Löschen
          </button>
          <button type="button" className="action unsure" disabled title="FRV-22/23">
            U Unsicher
          </button>
          <button type="button" className="action" disabled title="FRV-22/23">
            N Unbewertet
          </button>
        </div>
        <div className="helper" style={{ marginTop: 8 }}>
          Hotkeys und Bulk folgen in FRV-22/23. Click = Auswahl, Doppelklick = Fokus.
        </div>
      </div>

      {primary && (
        <div className="section">
          <h3>Metadaten</h3>
          <div style={{ position: 'relative', height: 140, marginBottom: 8 }}>
            <ThumbImage mediaId={primary.mediaId} size={240} />
          </div>
          <div className="kv">
            <div>ID</div>
            <div>{primary.mediaId}</div>
            <div>Titel</div>
            <div>{primary.title ?? '—'}</div>
            <div>Uploader</div>
            <div>{primary.uploader ?? '—'}</div>
            <div>Zeit</div>
            <div>{primary.timestamp ?? '—'}</div>
            <div>Score</div>
            <div>{primary.score ?? '—'}</div>
            <div>Status</div>
            <div>{primary.reviewStatus}</div>
          </div>
        </div>
      )}

      {!primary && (
        <div className="section">
          <div className="helper">
            Wähle ein Bild per Einfachklick oder setze Fokus per Doppelklick.
          </div>
        </div>
      )}
    </aside>
  );
}
