import type {
  BulkRequest,
  BulkResponse,
  FacetsResponse,
  GalleryQuery,
  GalleryResponse,
  GroupQuery,
  GroupsResponse,
  MediaFilter,
  ProjectsResponse,
  UndoRequest,
  UndoResponse,
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

async function getJson<T>(url: string, signal?: AbortSignal): Promise<T> {
  const res = await fetch(url, { signal });
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

export function fetchProjects(signal?: AbortSignal) {
  return getJson<ProjectsResponse>('/api/projects', signal);
}

export function postBulk(body: BulkRequest, signal?: AbortSignal) {
  return postJson<BulkResponse>('/api/review/bulk', body, signal);
}

export function postUndo(body: UndoRequest, signal?: AbortSignal) {
  return postJson<UndoResponse>('/api/review/undo', body, signal);
}

export function thumbUrl(mediaId: number, size = 160): string {
  return `/api/media/${mediaId}/thumb?size=${size}`;
}
