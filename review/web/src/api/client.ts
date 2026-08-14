import type {
  FacetsResponse,
  GalleryQuery,
  GalleryResponse,
  GroupQuery,
  GroupsResponse,
  MediaFilter,
} from '@findseries/review-shared';

async function postJson<T>(url: string, body: unknown, signal?: AbortSignal): Promise<T> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`${res.status}: ${text}`);
  }
  return res.json() as Promise<T>;
}

export function fetchGallery(q: GalleryQuery, signal?: AbortSignal) {
  return postJson<GalleryResponse>('/api/gallery/query', q, signal);
}

export function fetchGroups(q: GroupQuery, signal?: AbortSignal) {
  return postJson<GroupsResponse>('/api/groups/query', q, signal);
}

export function fetchFacets(filter: MediaFilter, signal?: AbortSignal) {
  return postJson<FacetsResponse>('/api/facets/query', filter, signal);
}

export function thumbUrl(mediaId: number, size = 160): string {
  return `/api/media/${mediaId}/thumb?size=${size}`;
}
