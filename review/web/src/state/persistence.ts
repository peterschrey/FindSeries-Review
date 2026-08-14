import type { GroupBy, ReviewStatus, SortDir, SortField } from '@findseries/review-shared';
import {
  createInitialState,
  type ReviewUiState,
} from './reviewState';

const STORAGE_KEY = 'findseries.review.ui.v1';
const SESSION_KEY = 'findseries.review.sessionId';

export type PersistedUiV1 = {
  v: 1;
  projectId: number;
  statuses: ReviewStatus[] | undefined;
  q: string;
  sourceTypes: string[] | undefined;
  categoryIds: number[] | undefined;
  uploader: string | null | undefined;
  groupBy: GroupBy;
  sort: SortField;
  dir: SortDir;
};

export function getOrCreateSessionId(): string {
  try {
    const existing = localStorage.getItem(SESSION_KEY);
    if (existing) return existing;
    const id =
      typeof crypto !== 'undefined' && 'randomUUID' in crypto
        ? crypto.randomUUID()
        : `sess-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    localStorage.setItem(SESSION_KEY, id);
    return id;
  } catch {
    return `sess-${Date.now()}`;
  }
}

export function loadPersistedState(fallbackProjectId: number): ReviewUiState {
  const base = createInitialState(fallbackProjectId);
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return base;
    const parsed = JSON.parse(raw) as PersistedUiV1;
    if (!parsed || parsed.v !== 1 || typeof parsed.projectId !== 'number') {
      return base;
    }
    return {
      ...base,
      projectId: parsed.projectId,
      statuses: parsed.statuses,
      q: typeof parsed.q === 'string' ? parsed.q : '',
      sourceTypes: parsed.sourceTypes,
      categoryIds: parsed.categoryIds,
      uploader: parsed.uploader,
      groupBy: parsed.groupBy ?? base.groupBy,
      sort: parsed.sort ?? base.sort,
      dir: parsed.dir ?? base.dir,
      // focus intentionally not restored
      focusMediaId: null,
      selectedIds: [],
      selectionAnchorId: null,
      drilldown: null,
      filterEpoch: 0,
    };
  } catch {
    return base;
  }
}

export function persistState(state: ReviewUiState): void {
  const payload: PersistedUiV1 = {
    v: 1,
    projectId: state.projectId,
    statuses: state.statuses,
    q: state.q,
    sourceTypes: state.sourceTypes,
    categoryIds: state.categoryIds,
    uploader: state.uploader,
    groupBy: state.groupBy,
    sort: state.sort,
    dir: state.dir,
  };
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
  } catch {
    /* ignore quota */
  }
}

export function clearPersistedState(): void {
  try {
    localStorage.removeItem(STORAGE_KEY);
  } catch {
    /* ignore */
  }
}
