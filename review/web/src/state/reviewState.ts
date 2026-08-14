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
  kind: 'group' | 'category' | 'uploader' | 'sourceType' | 'series' | 'seed' | 'focus-relation';
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
  /** true/undefined = subtree; false = exact only */
  categoryIncludeDescendants: boolean;
  uploader: string | null | undefined;
  groupBy: GroupBy;
  sort: SortField;
  dir: SortDir;
  drilldown: ActiveDrilldown;
  /** Focus-relation drilldown (FRV-32) — cleared by Focus-X, separate from group drilldown */
  focusRelation: ActiveDrilldown;
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
  | { type: 'set_category_ids'; categoryIds: number[] | undefined; includeDescendants?: boolean }
  | { type: 'toggle_category_include_descendants' }
  | { type: 'set_uploader'; uploader: string | null | undefined }
  | { type: 'set_focus_relation'; relation: ActiveDrilldown }
  | { type: 'clear_focus_relation' }
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
    categoryIncludeDescendants: true,
    uploader: undefined,
    groupBy: 'provenance',
    sort: 'media_id',
    dir: 'asc',
    drilldown: null,
    focusRelation: null,
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
    categoryIncludeDescendants: state.categoryIncludeDescendants,
    uploader: state.uploader,
    sort: state.sort,
    dir: state.dir,
    drilldown: state.drilldown
      ? { kind: state.drilldown.kind, key: state.drilldown.key, patch: state.drilldown.patch }
      : null,
    focusRelation: state.focusRelation
      ? { key: state.focusRelation.key, patch: state.focusRelation.patch }
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
      return {
        ...state,
        categoryIds: action.categoryIds,
        categoryIncludeDescendants:
          action.includeDescendants ?? state.categoryIncludeDescendants,
        ...clearSelection(),
      };
    case 'toggle_category_include_descendants':
      return {
        ...state,
        categoryIncludeDescendants: !state.categoryIncludeDescendants,
        ...clearSelection(),
      };
    case 'set_uploader':
      return { ...state, uploader: action.uploader, ...clearSelection() };
    case 'set_focus_relation':
      // Single shelf drilldown: focus relation clears group drilldown
      return {
        ...state,
        focusRelation: action.relation,
        drilldown: null,
        ...clearSelection(),
      };
    case 'clear_focus_relation':
      return { ...state, focusRelation: null, ...clearSelection() };
    case 'set_group_by': {
      // Without drilldown: gallery result unchanged → keep selection.
      // With drilldown: clearing drilldown changes result → clear selection.
      if (state.drilldown || state.focusRelation) {
        return {
          ...state,
          groupBy: action.groupBy,
          drilldown: null,
          focusRelation: null,
          ...clearSelection(),
        };
      }
      return { ...state, groupBy: action.groupBy };
    }
    case 'set_sort':
      return {
        ...state,
        sort: action.sort,
        dir: action.dir ?? state.dir,
        ...clearSelection(),
      };
    case 'set_drilldown':
      // Single shelf drilldown: group drilldown clears focus relation
      return {
        ...state,
        drilldown: action.drilldown,
        focusRelation: null,
        ...clearSelection(),
      };
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
      return {
        ...state,
        focusMediaId: action.mediaId,
        focusRelation: null,
      };
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
  const fr = state.focusRelation?.patch ?? {};
  const filter: MediaFilter = {
    projectId: state.projectId,
    statuses: state.statuses,
    q: state.q.trim() || undefined,
    sourceTypes: state.sourceTypes,
    categoryIds: state.categoryIds,
    categoryIncludeDescendants: state.categoryIncludeDescendants,
    uploader: state.uploader,
  };

  const applyPatch = (patch: Partial<MediaFilter>) => {
    if (patch.categoryIds?.length) {
      if (filter.categoryIds?.length) {
        filter.alsoCategoryIds = patch.categoryIds;
        if (patch.categoryIncludeDescendants !== undefined) {
          filter.alsoCategoryIncludeDescendants = patch.categoryIncludeDescendants;
        }
      } else {
        filter.categoryIds = patch.categoryIds;
        if (patch.categoryIncludeDescendants !== undefined) {
          filter.categoryIncludeDescendants = patch.categoryIncludeDescendants;
        }
      }
    }
    if (patch.sourceTypes?.length) {
      if (filter.sourceTypes?.length) {
        filter.alsoSourceTypes = patch.sourceTypes;
      } else {
        filter.sourceTypes = patch.sourceTypes;
      }
    }
    if (patch.uploader !== undefined) {
      if (filter.uploader !== undefined) {
        if (filter.uploader !== patch.uploader) filter.mediaIds = [];
      } else {
        filter.uploader = patch.uploader;
      }
    }
    if (patch.seriesKey) filter.seriesKey = patch.seriesKey;
    if (patch.seedKey) filter.seedKey = patch.seedKey;
    if (patch.parentMediaId) filter.parentMediaId = patch.parentMediaId;
    if (patch.mediaIds) {
      filter.mediaIds = filter.mediaIds?.length === 0 ? [] : patch.mediaIds;
    }
  };

  applyPatch(d);
  applyPatch(fr);
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
    categoryIncludeDescendants: state.categoryIncludeDescendants,
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
