import type {
  GroupBy,
  MediaFilter,
  ReviewStatus,
  SortDir,
  SortField,
  StatusCounts,
} from '@findseries/review-shared';

/** Default visible statuses when chips follow prototype defaults. */
export const DEFAULT_STATUSES: ReviewStatus[] = ['unreviewed', 'unsure'];

export type ActiveDrilldown = {
  kind: 'group' | 'category' | 'uploader' | 'sourceType' | 'series';
  key: string;
  label: string;
  patch: Partial<MediaFilter>;
} | null;

/**
 * Central typed UI filter/review state (FRV-18).
 * Persistence (URL/session) prepared later in FRV-26 — keep serializable.
 */
export type ReviewUiState = {
  projectId: number;
  /** undefined = backend default unreviewed+unsure; [] = empty result */
  statuses: ReviewStatus[] | undefined;
  q: string;
  sourceTypes: string[] | undefined;
  categoryIds: number[] | undefined;
  uploader: string | null | undefined;
  groupBy: GroupBy;
  sort: SortField;
  dir: SortDir;
  drilldown: ActiveDrilldown;
  /** Focus media id — separate from selection */
  focusMediaId: number | null;
  /** Selection set (click), never auto-set by focus */
  selectedIds: number[];
  lastClickedId: number | null;
};

export type ReviewUiAction =
  | { type: 'set_project'; projectId: number }
  | { type: 'toggle_status'; status: ReviewStatus }
  | { type: 'set_q'; q: string }
  | { type: 'set_group_by'; groupBy: GroupBy }
  | { type: 'set_sort'; sort: SortField; dir?: SortDir }
  | { type: 'set_drilldown'; drilldown: ActiveDrilldown }
  | { type: 'clear_drilldown' }
  | { type: 'remove_filter'; key: 'q' | 'sourceTypes' | 'categoryIds' | 'uploader' | 'drilldown' }
  | { type: 'reset_filters' }
  | { type: 'select_click'; mediaId: number; ctrl?: boolean; shift?: boolean }
  | { type: 'clear_selection' }
  | { type: 'set_focus'; mediaId: number | null };

export function createInitialState(projectId = 7): ReviewUiState {
  return {
    projectId,
    statuses: [...DEFAULT_STATUSES],
    q: '',
    sourceTypes: undefined,
    categoryIds: undefined,
    uploader: undefined,
    groupBy: 'provenance',
    sort: 'media_id',
    dir: 'asc',
    drilldown: null,
    focusMediaId: null,
    selectedIds: [],
    lastClickedId: null,
  };
}

export function reviewUiReducer(state: ReviewUiState, action: ReviewUiAction): ReviewUiState {
  switch (action.type) {
    case 'set_project':
      return { ...createInitialState(action.projectId) };
    case 'toggle_status': {
      const current = state.statuses === undefined ? [...DEFAULT_STATUSES] : [...state.statuses];
      const idx = current.indexOf(action.status);
      if (idx >= 0) current.splice(idx, 1);
      else current.push(action.status);
      // Explicit empty array is allowed (empty result) — do NOT coerce to default.
      return { ...state, statuses: current };
    }
    case 'set_q':
      return { ...state, q: action.q };
    case 'set_group_by':
      return { ...state, groupBy: action.groupBy, drilldown: null };
    case 'set_sort':
      return { ...state, sort: action.sort, dir: action.dir ?? state.dir };
    case 'set_drilldown':
      return { ...state, drilldown: action.drilldown };
    case 'clear_drilldown':
      return { ...state, drilldown: null };
    case 'remove_filter': {
      if (action.key === 'q') return { ...state, q: '' };
      if (action.key === 'sourceTypes') return { ...state, sourceTypes: undefined };
      if (action.key === 'categoryIds') return { ...state, categoryIds: undefined };
      if (action.key === 'uploader') return { ...state, uploader: undefined };
      if (action.key === 'drilldown') return { ...state, drilldown: null };
      return state;
    }
    case 'reset_filters':
      return {
        ...createInitialState(state.projectId),
        focusMediaId: state.focusMediaId,
        selectedIds: state.selectedIds,
        lastClickedId: state.lastClickedId,
      };
    case 'select_click': {
      // Phase 3: simple click = single select; ctrl toggles; shift range deferred FRV-22
      if (action.ctrl) {
        const set = new Set(state.selectedIds);
        if (set.has(action.mediaId)) set.delete(action.mediaId);
        else set.add(action.mediaId);
        return {
          ...state,
          selectedIds: [...set],
          lastClickedId: action.mediaId,
        };
      }
      return {
        ...state,
        selectedIds: [action.mediaId],
        lastClickedId: action.mediaId,
      };
    }
    case 'clear_selection':
      return { ...state, selectedIds: [], lastClickedId: null };
    case 'set_focus':
      return { ...state, focusMediaId: action.mediaId };
    default:
      return state;
  }
}

/** Build API MediaFilter from UI state (respecting statuses [] vs undefined). */
export function toMediaFilter(state: ReviewUiState): MediaFilter {
  const patch = state.drilldown?.patch ?? {};
  return {
    projectId: state.projectId,
    statuses: state.statuses,
    q: state.q.trim() || undefined,
    sourceTypes: patch.sourceTypes ?? state.sourceTypes,
    categoryIds: patch.categoryIds ?? state.categoryIds,
    uploader: patch.uploader !== undefined ? patch.uploader : state.uploader,
    seriesKey: patch.seriesKey,
    seedKey: patch.seedKey,
    parentMediaId: patch.parentMediaId,
    mediaIds: patch.mediaIds,
  };
}

export function emptyCounts(): StatusCounts {
  return { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 };
}

export function statusChipActive(state: ReviewUiState, status: ReviewStatus): boolean {
  const list = state.statuses === undefined ? DEFAULT_STATUSES : state.statuses;
  return list.includes(status);
}
