import { useEffect, useMemo, useReducer, useRef } from 'react';
import { Toolbar } from './Toolbar';
import { StatusOverview } from './StatusOverview';
import { GroupShelf } from './GroupShelf';
import { LeftNav } from './LeftNav';
import { Gallery } from './Gallery';
import { ContextPanel } from './ContextPanel';
import {
  createInitialState,
  emptyCounts,
  reviewUiReducer,
} from '../state/reviewState';
import { useFacetsData, useGalleryData, useGroupsData } from '../hooks/useReviewData';

const PROJECT_ID = 7;

export function App() {
  const [state, dispatch] = useReducer(reviewUiReducer, createInitialState(PROJECT_ID));
  const gallery = useGalleryData(state);
  const { groups, loading: groupsLoading } = useGroupsData(state);
  const { facets } = useFacetsData(state);

  const searchTimer = useRef<number | null>(null);
  const onSearchDebounced = (q: string) => {
    if (searchTimer.current) window.clearTimeout(searchTimer.current);
    searchTimer.current = window.setTimeout(() => {
      dispatch({ type: 'set_q', q });
    }, 250);
  };

  useEffect(() => {
    return () => {
      if (searchTimer.current) window.clearTimeout(searchTimer.current);
    };
  }, []);

  const selectionCounts = useMemo(() => {
    const counts = emptyCounts();
    for (const id of state.selectedIds) {
      const item = gallery.items.find((i) => i.mediaId === id);
      if (!item) continue;
      counts[item.reviewStatus] += 1;
      counts.total += 1;
    }
    return counts;
  }, [state.selectedIds, gallery.items]);

  return (
    <div className="app">
      <header>
        <h1>FindSeries Review</h1>
        <span className="project">
          Projekt {state.projectId} · integrierte Single View · Fokus optional per Doppelklick
        </span>
        <div className="topstats">
          <span className="stat">
            <span className="dot" style={{ background: 'var(--accent)' }} />
            Ergebnis {gallery.total.toLocaleString('de-DE')}
          </span>
          <span className="stat">
            Auswahl {state.selectedIds.length}
            {state.focusMediaId != null ? ` · Fokus #${state.focusMediaId}` : ''}
          </span>
        </div>
      </header>

      <Toolbar state={state} dispatch={dispatch} onSearchDebounced={onSearchDebounced} />

      <StatusOverview
        inventory={gallery.statusCounts}
        result={{
          ...gallery.statusCounts,
          total: gallery.total,
        }}
        selection={selectionCounts}
      />

      <GroupShelf
        state={state}
        dispatch={dispatch}
        groups={groups}
        loading={groupsLoading}
      />

      <div className="main">
        <LeftNav state={state} dispatch={dispatch} facets={facets} />
        <Gallery state={state} dispatch={dispatch} gallery={gallery} />
        <ContextPanel state={state} dispatch={dispatch} items={gallery.items} />
      </div>

      <footer>
        <span>
          <kbd>Click</kbd> Auswahl · <kbd>Doppelklick</kbd> Fokus · Hotkeys K/R/U/N folgen FRV-22/23
        </span>
      </footer>
    </div>
  );
}
