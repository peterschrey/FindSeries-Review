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
  /** Only the drill constraint — never replaces global filters wholesale. */
  patch: Partial<MediaFilter>;
} | null;

/**
 * Central typed UI filter/review state (FRV-18 / FRV-22–26).
 * Persistence: see persistence.ts (FRV-26).
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
  /** Explicit selection anchor for Shift-range (FRV-22) */
  selectionAnchorId: number | null;
  /** Bumps on reset/project so controlled search can cancel stale drafts */
  filterEpoch: number;
};

export type ReviewUiAction =
  | { type: 'set_project'; projectId: number }
  | { type: 'hydrate'; state: ReviewUiState }
  | { type: 'toggle_status'; status: ReviewStatus }
  | { type: 'set_q'; q: string }
  | { type: 'set_source_types'; sourceTypes: string[] | undefined }
  | { type: 'set_category_ids'; categoryIds: number[] | undefined }
  | { type: 'set_uploader'; uploader: string | null | undefined }
  | { type: 'set_group_by'; groupBy: GroupBy }
  | { type: 'set_sort'; sort: SortField; dir?: SortDir }
  | { type: 'set_drilldown'; drilldown: ActiveDrilldown }
  | { type: 'clear_drilldown' }
  | { type: 'remove_filter'; key: 'q' | 'sourceTypes' | 'categoryIds' | 'uploader' | 'drilldown' }
  | { type: 'reset_filters' }
  | {
      type: 'select_click';
      mediaId: number;
      ctrl?: boolean;
      shift?: boolean;
      /** Ordered media ids currently loaded (stable sort sequence) */
      orderedIds: number[];
    }
  | { type: 'set_selection'; selectedIds: number[]; selectionAnchorId?: number | null }
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
    selectionAnchorId: null,
    filterEpoch: 0,
  };
}

function clearSelection(): Pick<ReviewUiState, 'selectedIds' | 'selectionAnchorId'> {
  return { selectedIds: [], selectionAnchorId: null };
}

/** Keys that change the gallery result set (not groupBy). */
export function resultIdentity(state: ReviewUiState): string {
  return JSON.stringify({
    projectId: state.projectId,
    statuses: state.statuses,
    q: state.q,
    sourceTypes: state.sourceTypes,
    categoryIds: state.categoryIds,
    uploader: state.uploader,
    sort: state.sort,
    dir: state.dir,
    drilldown: state.drilldown
      ? { kind: state.drilldown.kind, key: state.drilldown.key, patch: state.drilldown.patch }
      : null,
  });
}

export function reviewUiReducer(state: ReviewUiState, action: ReviewUiAction): ReviewUiState {
  switch (action.type) {
    case 'set_project':
      return { ...createInitialState(action.projectId), filterEpoch: state.filterEpoch + 1 };
    case 'hydrate':
      return action.state;
    case 'toggle_status': {
      const current = state.statuses === undefined ? [...DEFAULT_STATUSES] : [...state.statuses];
      const idx = current.indexOf(action.status);
      if (idx >= 0) current.splice(idx, 1);
      else current.push(action.status);
      return { ...state, statuses: current, ...clearSelection() };
    }
    case 'set_q':
      return { ...state, q: action.q, ...clearSelection() };
    case 'set_source_types':
      return { ...state, sourceTypes: action.sourceTypes, ...clearSelection() };
    case 'set_category_ids':
      return { ...state, categoryIds: action.categoryIds, ...clearSelection() };
    case 'set_uploader':
      return { ...state, uploader: action.uploader, ...clearSelection() };
    case 'set_group_by':
      // groupBy does not change gallery result — keep selection
      return { ...state, groupBy: action.groupBy, drilldown: null };
    case 'set_sort':
      return {
        ...state,
        sort: action.sort,
        dir: action.dir ?? state.dir,
        ...clearSelection(),
      };
    case 'set_drilldown':
      return { ...state, drilldown: action.drilldown, ...clearSelection() };
    case 'clear_drilldown':
      return { ...state, drilldown: null, ...clearSelection() };
    case 'remove_filter': {
      if (action.key === 'q') return { ...state, q: '', ...clearSelection() };
      if (action.key === 'sourceTypes')
        return { ...state, sourceTypes: undefined, ...clearSelection() };
      if (action.key === 'categoryIds')
        return { ...state, categoryIds: undefined, ...clearSelection() };
      if (action.key === 'uploader')
        return { ...state, uploader: undefined, ...clearSelection() };
      if (action.key === 'drilldown')
        return { ...state, drilldown: null, ...clearSelection() };
      return state;
    }
    case 'reset_filters':
      return {
        ...createInitialState(state.projectId),
        focusMediaId: state.focusMediaId,
        filterEpoch: state.filterEpoch + 1,
      };
    case 'select_click': {
      const { mediaId, orderedIds } = action;
      const ctrl = Boolean(action.ctrl);
      const shift = Boolean(action.shift);

      if (shift) {
        const anchor = state.selectionAnchorId;
        const aIdx = anchor == null ? -1 : orderedIds.indexOf(anchor);
        const tIdx = orderedIds.indexOf(mediaId);
        if (aIdx < 0 || tIdx < 0) {
          // Anchor not resolvable in loaded sequence — do not guess
          return {
            ...state,
            selectedIds: [mediaId],
            selectionAnchorId: mediaId,
          };
        }
        const lo = Math.min(aIdx, tIdx);
        const hi = Math.max(aIdx, tIdx);
        const range = orderedIds.slice(lo, hi + 1);
        if (ctrl) {
          const set = new Set(state.selectedIds);
          for (const id of range) set.add(id);
          return {
            ...state,
            selectedIds: [...set],
            selectionAnchorId: state.selectionAnchorId ?? mediaId,
          };
        }
        return {
          ...state,
          selectedIds: range,
          selectionAnchorId: state.selectionAnchorId ?? orderedIds[aIdx]!,
        };
      }

      if (ctrl) {
        const set = new Set(state.selectedIds);
        if (set.has(mediaId)) set.delete(mediaId);
        else set.add(mediaId);
        return {
          ...state,
          selectedIds: [...set],
          selectionAnchorId: mediaId,
        };
      }

      return {
        ...state,
        selectedIds: [mediaId],
        selectionAnchorId: mediaId,
      };
    }
    case 'set_selection':
      return {
        ...state,
        selectedIds: action.selectedIds,
        selectionAnchorId:
          action.selectionAnchorId !== undefined
            ? action.selectionAnchorId
            : state.selectionAnchorId,
      };
    case 'clear_selection':
      return { ...state, selectedIds: [], selectionAnchorId: null };
    case 'set_focus':
      return { ...state, focusMediaId: action.mediaId };
    default:
      return state;
  }
}

/**
 * Build API MediaFilter: global filters AND drilldown constraints.
 * Drilldown never silently widens the result set.
 */
export function toMediaFilter(state: ReviewUiState): MediaFilter {
  const d = state.drilldown?.patch ?? {};
  const filter: MediaFilter = {
    projectId: state.projectId,
    statuses: state.statuses,
    q: state.q.trim() || undefined,
    sourceTypes: state.sourceTypes,
    categoryIds: state.categoryIds,
    uploader: state.uploader,
  };

  // Category AND
  if (d.categoryIds?.length) {
    if (filter.categoryIds?.length) {
      filter.alsoCategoryIds = d.categoryIds;
    } else {
      filter.categoryIds = d.categoryIds;
    }
  }

  // SourceType AND
  if (d.sourceTypes?.length) {
    if (filter.sourceTypes?.length) {
      filter.alsoSourceTypes = d.sourceTypes;
    } else {
      filter.sourceTypes = d.sourceTypes;
    }
  }

  // Uploader AND (conflicting equality → empty)
  if (d.uploader !== undefined) {
    if (filter.uploader !== undefined) {
      if (filter.uploader !== d.uploader) {
        filter.mediaIds = [];
      }
    } else {
      filter.uploader = d.uploader;
    }
  }

  if (d.seriesKey) filter.seriesKey = d.seriesKey;
  if (d.seedKey) filter.seedKey = d.seedKey;
  if (d.parentMediaId) filter.parentMediaId = d.parentMediaId;
  if (d.mediaIds) {
    filter.mediaIds = filter.mediaIds?.length === 0 ? [] : d.mediaIds;
  }

  return filter;
}

/** Global filter only — no drilldown (groups / facets base). */
export function toGlobalMediaFilter(state: ReviewUiState): MediaFilter {
  return {
    projectId: state.projectId,
    statuses: state.statuses,
    q: state.q.trim() || undefined,
    sourceTypes: state.sourceTypes,
    categoryIds: state.categoryIds,
    uploader: state.uploader,
  };
}

export function emptyCounts(): StatusCounts {
  return { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 };
}

export function statusChipActive(state: ReviewUiState, status: ReviewStatus): boolean {
  const list = state.statuses === undefined ? DEFAULT_STATUSES : state.statuses;
  return list.includes(status);
}

export function countsFromSelected(
  selectedIds: number[],
  items: Array<{ mediaId: number; reviewStatus: ReviewStatus }>,
): StatusCounts {
  const byId = new Map(items.map((i) => [i.mediaId, i.reviewStatus]));
  const counts = emptyCounts();
  for (const id of selectedIds) {
    const st = byId.get(id);
    if (!st) continue;
    counts[st] += 1;
    counts.total += 1;
  }
  return counts;
}
