import type { Dispatch } from 'react';
import type { BulkResponse, MediaCard, ReviewStatus } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';
import { ThumbImage } from './ThumbImage';

export function ContextPanel({
  state,
  items,
  busy,
  onStatus,
  lastBulk,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  items: MediaCard[];
  busy: boolean;
  onStatus: (target: ReviewStatus | 'reset') => void;
  lastBulk: BulkResponse | null;
}) {
  const selectedSet = new Set(state.selectedIds);
  const selected = items.filter((i) => selectedSet.has(i.mediaId));
  const primary =
    selected[0] ??
    items.find((i) => i.mediaId === state.focusMediaId) ??
    null;

  let mode = 'Keine Auswahl';
  if (state.focusMediaId && selected.length === 0) mode = 'Fokus aktiv';
  else if (selected.length === 1) mode = 'Einzelbild';
  else if (selected.length > 1) mode = `Mehrfachauswahl (${selected.length})`;

  const canAct = selected.length > 0 && !busy;

  return (
    <aside className="right">
      <div className="section">
        <h3>Kontext</h3>
        <div className="helper">{mode}</div>
        {state.focusMediaId != null && (
          <div className="helper" style={{ marginTop: 8 }}>
            Fokus #{state.focusMediaId} — aufheben über × in der Fokuskarte (Shelf) oder Esc.
          </div>
        )}
      </div>

      <div className="section">
        <h3>Aktionen</h3>
        <div className="actionrow">
          <button
            type="button"
            className="action keep"
            disabled={!canAct}
            onClick={() => onStatus('keep')}
          >
            K Behalten
          </button>
          <button
            type="button"
            className="action reject"
            disabled={!canAct}
            onClick={() => onStatus('reject')}
          >
            R Löschen
          </button>
          <button
            type="button"
            className="action unsure"
            disabled={!canAct}
            onClick={() => onStatus('unsure')}
          >
            U Unsicher
          </button>
          <button
            type="button"
            className="action"
            disabled={!canAct}
            onClick={() => onStatus('reset')}
          >
            N Unbewertet
          </button>
        </div>
        <div className="helper" style={{ marginTop: 8 }}>
          Behalten ist standardmäßig geschützt. Kein UI-Schalter für protectKeep=false.
        </div>
        {lastBulk && (
          <div className="helper" style={{ marginTop: 8 }} data-testid="bulk-summary">
            Ziel {lastBulk.mediaCount} · geändert {lastBulk.changedCount} · geschützt{' '}
            {lastBulk.protectedCount} · übersprungen {lastBulk.skippedCount}
          </div>
        )}
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
