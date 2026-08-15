import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import type { BulkResponse, ProjectSummary, ReviewStatus } from '@findseries/review-shared';
import { Toolbar } from './Toolbar';
import { StatusOverview } from './StatusOverview';
import { GroupShelf } from './GroupShelf';
import { LeftNav } from './LeftNav';
import { Gallery } from './Gallery';
import { ContextPanel } from './ContextPanel';
import { countsFromSelected, reviewUiReducer, type ReviewUiAction } from '../state/reviewState';
import {
  clearPersistedState,
  getOrCreateSessionId,
  loadPersistedState,
  persistState,
} from '../state/persistence';
import {
  useFacetsData,
  useGalleryData,
  useGroupsData,
  useInventoryCounts,
} from '../hooks/useReviewData';
import { fetchProjects, postBulk, postUndo } from '../api/client';

type Toast = { id: number; text: string };
type UndoEntry = { projectId: number; batchId: string };
type AdvancePlan = { preferIndex: number; minGeneration: number };

function isTypingTarget(el: EventTarget | null): boolean {
  if (!(el instanceof HTMLElement)) return false;
  const tag = el.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (el.isContentEditable) return true;
  return Boolean(el.closest('[contenteditable="true"]'));
}

export function App() {
  const sessionId = useMemo(() => getOrCreateSessionId(), []);
  const [state, dispatch] = useReducer(reviewUiReducer, undefined, () => loadPersistedState(7));
  const [mutationEpoch, setMutationEpoch] = useState(0);
  const gallery = useGalleryData(state, mutationEpoch);
  const inventory = useInventoryCounts(state.projectId, mutationEpoch);
  const { groups, loading: groupsLoading } = useGroupsData(state, mutationEpoch);
  const { facets } = useFacetsData(state, mutationEpoch);
  const [projects, setProjects] = useState<ProjectSummary[]>([]);
  const [busy, setBusy] = useState(false);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [lastBulk, setLastBulk] = useState<BulkResponse | null>(null);
  const [undoLen, setUndoLen] = useState(0);
  const [scrollToMediaId, setScrollToMediaId] = useState<number | null>(null);
  const undoStackRef = useRef<UndoEntry[]>([]);
  const toastIdRef = useRef(0);
  const galleryRef = useRef(gallery);
  galleryRef.current = gallery;
  const stateRef = useRef(state);
  stateRef.current = state;
  const advanceRef = useRef<AdvancePlan | null>(null);
  const busyRef = useRef(false);
  busyRef.current = busy;

  const bumpMutation = useCallback(() => setMutationEpoch((n) => n + 1), []);

  useEffect(() => {
    const ac = new AbortController();
    fetchProjects(ac.signal)
      .then((res) => {
        if (!ac.signal.aborted) setProjects(res.projects);
      })
      .catch(() => {
        /* api down */
      });
    return () => ac.abort();
  }, []);

  useEffect(() => {
    persistState(state);
  }, [state]);

  // Project change: drop undo entries from other projects
  useEffect(() => {
    undoStackRef.current = undoStackRef.current.filter((e) => e.projectId === state.projectId);
    setUndoLen(undoStackRef.current.length);
  }, [state.projectId]);

  const pushToast = useCallback((text: string) => {
    const id = ++toastIdRef.current;
    setToasts((t) => [...t.slice(-4), { id, text }]);
    window.setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 6000);
  }, []);

  const selectionCounts = useMemo(
    () => countsFromSelected(state.selectedIds, gallery.items),
    [state.selectedIds, gallery.items],
  );

  // Auto-advance tied to gallery loadGeneration (no fixed timer)
  useEffect(() => {
    const plan = advanceRef.current;
    if (!plan) return;
    if (gallery.loading) return;
    if (gallery.loadGeneration < plan.minGeneration) return;
    advanceRef.current = null;
    const items = gallery.items;
    if (!items.length) return;
    const idx = Math.min(Math.max(0, plan.preferIndex), items.length - 1);
    const next = items[idx];
    if (!next) return;
    dispatch({
      type: 'select_click',
      mediaId: next.mediaId,
      orderedIds: items.map((i) => i.mediaId),
    });
    setScrollToMediaId(next.mediaId);
  }, [gallery.loading, gallery.loadGeneration, gallery.items]);

  const applyStatus = useCallback(
    async (target: ReviewStatus | 'reset') => {
      const s = stateRef.current;
      if (!s.selectedIds.length || busyRef.current) return;
      setBusy(true);
      busyRef.current = true;
      try {
        const res = await postBulk(
          target === 'reset'
            ? {
                projectId: s.projectId,
                action: 'reset_unreviewed',
                mediaIds: s.selectedIds,
                protectKeep: true,
                source: 'ui',
                sessionId,
              }
            : {
                projectId: s.projectId,
                action: 'set_status',
                targetStatus: target,
                mediaIds: s.selectedIds,
                protectKeep: true,
                source: 'ui',
                sessionId,
              },
        );
        setLastBulk(res);
        undoStackRef.current.push({ projectId: s.projectId, batchId: res.batchId });
        setUndoLen(undoStackRef.current.length);
        pushToast(
          `Ziel ${res.mediaCount} · geändert ${res.changedCount} · Keep geschützt ${res.protectedCount} · übersprungen ${res.skippedCount}`,
        );

        const ordered = galleryRef.current.items.map((i) => i.mediaId);
        const idxs = s.selectedIds
          .map((id) => ordered.indexOf(id))
          .filter((i) => i >= 0)
          .sort((a, b) => a - b);
        const preferIndex = idxs.length ? idxs[idxs.length - 1]! + 1 - idxs.length : 0;
        // After reject/keep disappear, prefer the index of the first selected (items shift up)
        advanceRef.current = {
          preferIndex: Math.max(0, idxs[0] ?? 0),
          minGeneration: galleryRef.current.loadGeneration + 1,
        };
        void preferIndex;

        dispatch({ type: 'clear_selection' });
        bumpMutation();
      } catch (e) {
        pushToast(e instanceof Error ? e.message : String(e));
      } finally {
        setBusy(false);
        busyRef.current = false;
      }
    },
    [bumpMutation, pushToast, sessionId],
  );

  const undoLast = useCallback(async () => {
    if (busyRef.current) return;
    const entry = undoStackRef.current[undoStackRef.current.length - 1];
    if (!entry) return;
    if (entry.projectId !== stateRef.current.projectId) {
      pushToast('Undo gehört zu einem anderen Projekt');
      return;
    }
    // pop only after busy gate
    undoStackRef.current.pop();
    setUndoLen(undoStackRef.current.length);
    setBusy(true);
    busyRef.current = true;
    try {
      const res = await postUndo({
        projectId: entry.projectId,
        batchId: entry.batchId,
        sessionId,
      });
      pushToast(`Undo · ${res.restoredCount} restored`);
      bumpMutation();
    } catch (e) {
      // restore stack on failure
      undoStackRef.current.push(entry);
      setUndoLen(undoStackRef.current.length);
      pushToast(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
      busyRef.current = false;
    }
  }, [bumpMutation, pushToast, sessionId]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e.target)) return;
      const k = e.key.toLowerCase();
      if (k === 'z' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        void undoLast();
        return;
      }
      if (k === 'escape') {
        if (stateRef.current.focusMediaId != null) {
          dispatch({ type: 'set_focus', mediaId: null });
        }
        return;
      }
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (k === 'k') {
        e.preventDefault();
        void applyStatus('keep');
      } else if (k === 'r') {
        e.preventDefault();
        void applyStatus('reject');
      } else if (k === 'u') {
        e.preventDefault();
        void applyStatus('unsure');
      } else if (k === 'n') {
        e.preventDefault();
        void applyStatus('reset');
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [applyStatus, undoLast]);

  const wrappedDispatch = useCallback((a: ReviewUiAction) => {
    if (a.type === 'reset_filters') clearPersistedState();
    if (a.type === 'set_project') {
      undoStackRef.current = [];
      setUndoLen(0);
    }
    dispatch(a);
  }, []);

  return (
    <div className="app">
      <header>
        <h1>FindSeries Review</h1>
        <span className="project">
          {projects.find((p) => p.id === state.projectId)?.name ?? `Projekt ${state.projectId}`}
          {' · '}
          Session {sessionId.slice(0, 8)}…
        </span>
        <div className="topstats">
          <span className="stat" data-testid="header-result">
            <span className="dot" style={{ background: 'var(--accent)' }} />
            Ergebnis {gallery.total.toLocaleString('de-DE')}
          </span>
          <span className="stat" data-testid="header-selection">
            Auswahl {state.selectedIds.length}
            {state.focusMediaId != null ? ` · Fokus #${state.focusMediaId}` : ''}
          </span>
          <button
            type="button"
            className="btn"
            disabled={busy || undoLen === 0}
            onClick={() => void undoLast()}
          >
            Undo
          </button>
        </div>
      </header>

      <Toolbar state={state} dispatch={wrappedDispatch} projects={projects} />

      <StatusOverview inventory={inventory} result={gallery.statusCounts} selection={selectionCounts} />

      {lastBulk && (
        <div className="bulkBanner" data-testid="bulk-banner">
          Letzte Aktion: Ziel {lastBulk.mediaCount} · geändert {lastBulk.changedCount} · Keep geschützt{' '}
          {lastBulk.protectedCount} · übersprungen {lastBulk.skippedCount}
          <span className="muted"> · Redo nicht angeboten (Batch-Semantik unsicher)</span>
        </div>
      )}

      <GroupShelf
        state={state}
        dispatch={wrappedDispatch}
        groups={groups}
        loading={groupsLoading}
        galleryItems={gallery.items}
        mutationEpoch={mutationEpoch}
      />

      <div className="main">
        <LeftNav state={state} dispatch={wrappedDispatch} facets={facets} />
        <Gallery
          state={state}
          dispatch={wrappedDispatch}
          gallery={gallery}
          scrollToMediaId={scrollToMediaId}
          onScrolled={() => setScrollToMediaId(null)}
        />
        <ContextPanel
          state={state}
          dispatch={wrappedDispatch}
          items={gallery.items}
          busy={busy}
          onStatus={applyStatus}
          lastBulk={lastBulk}
        />
      </div>

      <footer>
        <span>
          <kbd>Click</kbd> Auswahl · <kbd>Ctrl</kbd> Toggle · <kbd>Shift</kbd> Range ·{' '}
          <kbd>Doppelklick</kbd> Fokus · <kbd>K/R/U/N</kbd> Status · <kbd>Ctrl+Z</kbd> Undo ·{' '}
          <kbd>Esc</kbd> Fokus weg
        </span>
      </footer>

      <div className="toastStack">
        {toasts.map((t) => (
          <div key={t.id} className="toast">
            {t.text}
          </div>
        ))}
      </div>
    </div>
  );
}
