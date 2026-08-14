import { describe, expect, it } from 'vitest';
import {
  createInitialState,
  reviewUiReducer,
  toMediaFilter,
  statusChipActive,
} from '../state/reviewState';

describe('reviewUiState', () => {
  it('toggles statuses and allows empty array (not default)', () => {
    let s = createInitialState(7);
    expect(statusChipActive(s, 'unreviewed')).toBe(true);
    s = reviewUiReducer(s, { type: 'toggle_status', status: 'unreviewed' });
    s = reviewUiReducer(s, { type: 'toggle_status', status: 'unsure' });
    expect(s.statuses).toEqual([]);
    expect(toMediaFilter(s).statuses).toEqual([]);
  });

  it('keeps focus separate from selection', () => {
    let s = createInitialState(7);
    s = reviewUiReducer(s, { type: 'select_click', mediaId: 10 });
    expect(s.selectedIds).toEqual([10]);
    expect(s.focusMediaId).toBeNull();
    s = reviewUiReducer(s, { type: 'set_focus', mediaId: 99 });
    expect(s.focusMediaId).toBe(99);
    expect(s.selectedIds).toEqual([10]);
    s = reviewUiReducer(s, { type: 'select_click', mediaId: 11 });
    expect(s.selectedIds).toEqual([11]);
    expect(s.focusMediaId).toBe(99);
  });

  it('drilldown patch merges into filter', () => {
    let s = createInitialState(7);
    s = reviewUiReducer(s, {
      type: 'set_drilldown',
      drilldown: {
        kind: 'uploader',
        key: 'A',
        label: 'A',
        patch: { uploader: 'A' },
      },
    });
    expect(toMediaFilter(s).uploader).toBe('A');
  });
});
