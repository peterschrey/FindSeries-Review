import { describe, expect, it, beforeEach } from 'vitest';
import {
  clearPersistedState,
  loadPersistedState,
  persistState,
  getOrCreateSessionId,
} from './persistence';
import { createInitialState } from './reviewState';

describe('persistence FRV-26', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('roundtrips filter fields and drops focus/selection', () => {
    const s = {
      ...createInitialState(14),
      q: 'chair',
      statuses: ['keep', 'reject'] as const,
      groupBy: 'uploader' as const,
      focusMediaId: 99,
      selectedIds: [1, 2],
      selectionAnchorId: 1,
    };
    persistState({ ...s, statuses: [...s.statuses] });
    const loaded = loadPersistedState(7);
    expect(loaded.projectId).toBe(14);
    expect(loaded.q).toBe('chair');
    expect(loaded.statuses).toEqual(['keep', 'reject']);
    expect(loaded.groupBy).toBe('uploader');
    expect(loaded.focusMediaId).toBeNull();
    expect(loaded.selectedIds).toEqual([]);
  });

  it('clear removes storage; session id stable', () => {
    const a = getOrCreateSessionId();
    const b = getOrCreateSessionId();
    expect(a).toBe(b);
    persistState(createInitialState(7));
    clearPersistedState();
    expect(loadPersistedState(7).q).toBe('');
  });
});
