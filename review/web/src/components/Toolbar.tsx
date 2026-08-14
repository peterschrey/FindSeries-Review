import { useEffect, useState, type Dispatch } from 'react';
import type { GroupBy, ReviewStatus, SortField } from '@findseries/review-shared';
import {
  type ReviewUiAction,
  type ReviewUiState,
  statusChipActive,
} from '../state/reviewState';

const STATUS_CHIPS: { status: ReviewStatus; label: string; color: string }[] = [
  { status: 'unreviewed', label: 'Unbewertet', color: 'var(--unrated)' },
  { status: 'unsure', label: 'Unsicher', color: 'var(--unsure)' },
  { status: 'keep', label: 'Behalten', color: 'var(--keep)' },
  { status: 'reject', label: 'Löschen', color: 'var(--reject)' },
];

const SEARCH_DEBOUNCE_MS = 250;

export function Toolbar({
  state,
  dispatch,
  projects,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  projects: Array<{ id: number; name: string; slug: string | null }>;
}) {
  const [draftQ, setDraftQ] = useState(state.q);

  // Keep visible input in sync with external state (reset, breadcrumb, restore)
  useEffect(() => {
    setDraftQ(state.q);
  }, [state.q, state.filterEpoch]);

  useEffect(() => {
    if (draftQ === state.q) return;
    const t = window.setTimeout(() => {
      dispatch({ type: 'set_q', q: draftQ });
    }, SEARCH_DEBOUNCE_MS);
    return () => window.clearTimeout(t);
  }, [draftQ, state.q, dispatch]);

  return (
    <div className="commandbar">
      <select
        className="select"
        value={state.projectId}
        onChange={(e) =>
          dispatch({ type: 'set_project', projectId: Number(e.target.value) })
        }
        aria-label="Projekt"
      >
        {projects.length === 0 && (
          <option value={state.projectId}>Projekt {state.projectId}</option>
        )}
        {projects.map((p) => (
          <option key={p.id} value={p.id}>
            {p.name}
            {p.slug ? ` (${p.slug})` : ''}
          </option>
        ))}
      </select>
      <input
        className="searchbox"
        value={draftQ}
        placeholder="Suchen: Titel, Uploader …"
        onChange={(e) => setDraftQ(e.target.value)}
        aria-label="Suche"
      />
      {STATUS_CHIPS.map((c) => (
        <button
          key={c.status}
          type="button"
          className={`chip ${statusChipActive(state, c.status) ? 'active' : ''}`}
          onClick={() => dispatch({ type: 'toggle_status', status: c.status })}
        >
          <span className="dot" style={{ background: c.color }} />
          {c.label}
        </button>
      ))}
      <span className="sep" />
      <select
        className="select"
        value={state.groupBy}
        onChange={(e) =>
          dispatch({ type: 'set_group_by', groupBy: e.target.value as GroupBy })
        }
      >
        <option value="provenance">Gruppieren: Herkunft</option>
        <option value="category">Gruppieren: Kategorie</option>
        <option value="series">Gruppieren: Serie</option>
        <option value="uploader">Gruppieren: Uploader</option>
      </select>
      <select
        className="select"
        value={state.sort}
        onChange={(e) =>
          dispatch({ type: 'set_sort', sort: e.target.value as SortField })
        }
      >
        <option value="media_id">Sortieren: media_id</option>
        <option value="title">Sortieren: Titel</option>
        <option value="uploader">Sortieren: Uploader</option>
        <option value="timestamp">Sortieren: Zeitstempel</option>
        <option value="score">Sortieren: Score</option>
      </select>
      <span className="spacer" />
      <button type="button" className="btn" onClick={() => dispatch({ type: 'reset_filters' })}>
        Filter zurücksetzen
      </button>
    </div>
  );
}
