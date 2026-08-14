import { useEffect, useRef, useState } from 'react';
import type {
  FacetsResponse,
  GroupsResponse,
  MediaCard,
  StatusCounts,
} from '@findseries/review-shared';
import { fetchFacets, fetchGallery, fetchGroups } from '../api/client';
import type { ReviewUiState } from '../state/reviewState';
import { toGlobalMediaFilter, toMediaFilter } from '../state/reviewState';

export type GalleryModel = {
  items: MediaCard[];
  total: number;
  statusCounts: StatusCounts;
  nextCursor: string | null;
  loading: boolean;
  loadingMore: boolean;
  error: string | null;
  loadMore: () => void;
  resetKey: string;
};

function galleryKey(state: ReviewUiState): string {
  return JSON.stringify({
    f: toMediaFilter(state),
    sort: state.sort,
    dir: state.dir,
  });
}

function groupsKey(state: ReviewUiState): string {
  return JSON.stringify({
    f: toGlobalMediaFilter(state),
    groupBy: state.groupBy,
  });
}

function facetsKey(state: ReviewUiState): string {
  return JSON.stringify(toGlobalMediaFilter(state));
}

function inventoryKey(projectId: number): string {
  return `inv:${projectId}`;
}

function emptySafe(): StatusCounts {
  return { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 };
}

export function useInventoryCounts(projectId: number): StatusCounts {
  const [counts, setCounts] = useState<StatusCounts>(emptySafe());
  const key = inventoryKey(projectId);

  useEffect(() => {
    const ac = new AbortController();
    fetchGallery(
      {
        projectId,
        statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
        limit: 1,
        sort: 'media_id',
        dir: 'asc',
        cursor: null,
      },
      ac.signal,
    )
      .then((res) => {
        if (!ac.signal.aborted) setCounts(res.statusCounts);
      })
      .catch(() => {
        /* ignore */
      });
    return () => ac.abort();
  }, [key, projectId]);

  return counts;
}

export function useGalleryData(state: ReviewUiState, reloadToken = 0): GalleryModel {
  const [items, setItems] = useState<MediaCard[]>([]);
  const [total, setTotal] = useState(0);
  const [statusCounts, setStatusCounts] = useState(emptySafe());
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const key = galleryKey(state);
  const keyRef = useRef(key);
  const cursorRef = useRef<string | null>(null);
  const loadingMoreRef = useRef(false);
  const inFlightCursorRef = useRef<string | null>(null);
  const stateRef = useRef(state);
  stateRef.current = state;

  useEffect(() => {
    keyRef.current = key;
    cursorRef.current = null;
    inFlightCursorRef.current = null;
    loadingMoreRef.current = false;
    const ac = new AbortController();
    setLoading(true);
    setError(null);
    setItems([]);
    setNextCursor(null);
    const filter = toMediaFilter(stateRef.current);
    fetchGallery(
      {
        ...filter,
        limit: 120,
        sort: stateRef.current.sort,
        dir: stateRef.current.dir,
        cursor: null,
      },
      ac.signal,
    )
      .then((res) => {
        if (keyRef.current !== key) return;
        setItems(res.items);
        setTotal(res.total);
        setStatusCounts(res.statusCounts);
        setNextCursor(res.nextCursor);
        cursorRef.current = res.nextCursor;
      })
      .catch((e: unknown) => {
        if (ac.signal.aborted) return;
        if (keyRef.current !== key) return;
        setError(e instanceof Error ? e.message : String(e));
      })
      .finally(() => {
        if (keyRef.current === key) setLoading(false);
      });
    return () => ac.abort();
  }, [key, reloadToken]);

  const loadMore = () => {
    const cursor = cursorRef.current;
    if (!cursor || loadingMoreRef.current || keyRef.current !== key) return;
    if (inFlightCursorRef.current === cursor) return;
    const acKey = keyRef.current;
    loadingMoreRef.current = true;
    inFlightCursorRef.current = cursor;
    setLoadingMore(true);
    const s = stateRef.current;
    const filter = toMediaFilter(s);
    fetchGallery({
      ...filter,
      limit: 120,
      sort: s.sort,
      dir: s.dir,
      cursor,
    })
      .then((res) => {
        if (keyRef.current !== acKey) return;
        setItems((prev) => {
          const seen = new Set(prev.map((i) => i.mediaId));
          const merged = [...prev];
          for (const it of res.items) {
            if (!seen.has(it.mediaId)) merged.push(it);
          }
          return merged;
        });
        setNextCursor(res.nextCursor);
        cursorRef.current = res.nextCursor;
        setTotal(res.total);
        setStatusCounts(res.statusCounts);
      })
      .catch(() => {
        /* ignore stale */
      })
      .finally(() => {
        if (inFlightCursorRef.current === cursor) inFlightCursorRef.current = null;
        loadingMoreRef.current = false;
        if (keyRef.current === acKey) setLoadingMore(false);
      });
  };

  return {
    items,
    total,
    statusCounts,
    nextCursor,
    loading,
    loadingMore,
    error,
    loadMore,
    resetKey: key,
  };
}

export function useGroupsData(state: ReviewUiState): {
  groups: GroupsResponse['groups'];
  loading: boolean;
  error: string | null;
} {
  const [groups, setGroups] = useState<GroupsResponse['groups']>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const key = groupsKey(state);
  const stateRef = useRef(state);
  stateRef.current = state;

  useEffect(() => {
    const ac = new AbortController();
    setLoading(true);
    setError(null);
    const filter = toGlobalMediaFilter(stateRef.current);
    fetchGroups(
      {
        ...filter,
        groupBy: stateRef.current.groupBy,
        limit: 40,
        sampleSize: 4,
      },
      ac.signal,
    )
      .then((res) => {
        if (!ac.signal.aborted) setGroups(res.groups);
      })
      .catch((e: unknown) => {
        if (!ac.signal.aborted) setError(e instanceof Error ? e.message : String(e));
      })
      .finally(() => {
        if (!ac.signal.aborted) setLoading(false);
      });
    return () => ac.abort();
  }, [key]);

  return { groups, loading, error };
}

export function useFacetsData(state: ReviewUiState): {
  facets: FacetsResponse | null;
  loading: boolean;
} {
  const [facets, setFacets] = useState<FacetsResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const key = facetsKey(state);
  const stateRef = useRef(state);
  stateRef.current = state;

  useEffect(() => {
    const ac = new AbortController();
    setLoading(true);
    fetchFacets(toGlobalMediaFilter(stateRef.current), ac.signal)
      .then((res) => {
        if (!ac.signal.aborted) setFacets(res);
      })
      .catch(() => {
        /* ignore */
      })
      .finally(() => {
        if (!ac.signal.aborted) setLoading(false);
      });
    return () => ac.abort();
  }, [key]);

  return { facets, loading };
}

/** Test helpers exported for dependency-key unit tests. */
export const __requestKeys = { galleryKey, groupsKey, facetsKey };
