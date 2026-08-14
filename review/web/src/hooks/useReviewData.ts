import { useEffect, useRef, useState } from 'react';
import type { FacetsResponse, GalleryResponse, GroupsResponse, MediaCard } from '@findseries/review-shared';
import { fetchFacets, fetchGallery, fetchGroups } from '../api/client';
import type { ReviewUiState } from '../state/reviewState';
import { toMediaFilter } from '../state/reviewState';

export type GalleryModel = {
  items: MediaCard[];
  total: number;
  statusCounts: GalleryResponse['statusCounts'];
  nextCursor: string | null;
  loading: boolean;
  loadingMore: boolean;
  error: string | null;
  loadMore: () => void;
  resetKey: string;
};

function filterKey(state: ReviewUiState): string {
  return JSON.stringify({
    f: toMediaFilter(state),
    sort: state.sort,
    dir: state.dir,
    groupBy: state.groupBy,
  });
}

export function useGalleryData(state: ReviewUiState): GalleryModel {
  const [items, setItems] = useState<MediaCard[]>([]);
  const [total, setTotal] = useState(0);
  const [statusCounts, setStatusCounts] = useState(emptySafe());
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const key = filterKey(state);
  const keyRef = useRef(key);
  const cursorRef = useRef<string | null>(null);

  useEffect(() => {
    keyRef.current = key;
    cursorRef.current = null;
    const ac = new AbortController();
    setLoading(true);
    setError(null);
    setItems([]);
    setNextCursor(null);
    const filter = toMediaFilter(state);
    fetchGallery(
      {
        ...filter,
        limit: 120,
        sort: state.sort,
        dir: state.dir,
        cursor: null,
      },
      ac.signal,
    )
      .then((res) => {
        if (keyRef.current !== key) return; // stale
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  const loadMore = () => {
    if (!cursorRef.current || loadingMore || loading) return;
    const acKey = keyRef.current;
    const cursor = cursorRef.current;
    setLoadingMore(true);
    const filter = toMediaFilter(state);
    fetchGallery({
      ...filter,
      limit: 120,
      sort: state.sort,
      dir: state.dir,
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

function emptySafe() {
  return { unreviewed: 0, keep: 0, reject: 0, unsure: 0, total: 0 };
}

export function useGroupsData(state: ReviewUiState): {
  groups: GroupsResponse['groups'];
  loading: boolean;
  error: string | null;
} {
  const [groups, setGroups] = useState<GroupsResponse['groups']>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const key = filterKey(state);

  useEffect(() => {
    const ac = new AbortController();
    setLoading(true);
    setError(null);
    const filter = toMediaFilter({ ...state, drilldown: null });
    fetchGroups(
      {
        ...filter,
        groupBy: state.groupBy,
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, state.groupBy]);

  return { groups, loading, error };
}

export function useFacetsData(state: ReviewUiState): {
  facets: FacetsResponse | null;
  loading: boolean;
} {
  const [facets, setFacets] = useState<FacetsResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const key = JSON.stringify(toMediaFilter({ ...state, drilldown: null }));

  useEffect(() => {
    const ac = new AbortController();
    setLoading(true);
    fetchFacets(toMediaFilter({ ...state, drilldown: null }), ac.signal)
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  return { facets, loading };
}
