import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { act, render, screen, fireEvent } from '@testing-library/react';
import {
  createInitialState,
  reviewUiReducer,
  toMediaFilter,
  statusChipActive,
  countsFromSelected,
} from './reviewState';
import { Toolbar } from '../components/Toolbar';
import { useState, useReducer, useEffect } from 'react';

describe('reviewUiState FRV-18/22/D', () => {
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
    s = reviewUiReducer(s, {
      type: 'select_click',
      mediaId: 10,
      orderedIds: [10, 11, 12],
    });
    expect(s.selectedIds).toEqual([10]);
    expect(s.selectionAnchorId).toBe(10);
    expect(s.focusMediaId).toBeNull();
    s = reviewUiReducer(s, { type: 'set_focus', mediaId: 99 });
    expect(s.focusMediaId).toBe(99);
    expect(s.selectedIds).toEqual([10]);
  });

  it('AND category drilldown does not replace global category', () => {
    let s = createInitialState(7);
    s = reviewUiReducer(s, { type: 'set_category_ids', categoryIds: [101] });
    s = reviewUiReducer(s, {
      type: 'set_drilldown',
      drilldown: {
        kind: 'category',
        key: '103',
        label: 'Instruments',
        patch: { categoryIds: [103] },
      },
    });
    const f = toMediaFilter(s);
    expect(f.categoryIds).toEqual([101]);
    expect(f.alsoCategoryIds).toEqual([103]);
  });

  it('AND provenance drilldown with global sourceType', () => {
    let s = createInitialState(7);
    s = reviewUiReducer(s, { type: 'set_source_types', sourceTypes: ['category'] });
    s = reviewUiReducer(s, {
      type: 'set_drilldown',
      drilldown: {
        kind: 'sourceType',
        key: 'neighbor',
        label: 'neighbor',
        patch: { sourceTypes: ['neighbor'] },
      },
    });
    const f = toMediaFilter(s);
    expect(f.sourceTypes).toEqual(['category']);
    expect(f.alsoSourceTypes).toEqual(['neighbor']);
  });

  it('conflicting uploader drilldown yields empty mediaIds', () => {
    let s = createInitialState(7);
    s = reviewUiReducer(s, { type: 'set_uploader', uploader: 'A' });
    s = reviewUiReducer(s, {
      type: 'set_drilldown',
      drilldown: {
        kind: 'uploader',
        key: 'B',
        label: 'B',
        patch: { uploader: 'B' },
      },
    });
    expect(toMediaFilter(s).mediaIds).toEqual([]);
  });

  it('clearing drilldown restores global-only filter', () => {
    let s = createInitialState(7);
    s = reviewUiReducer(s, { type: 'set_category_ids', categoryIds: [101] });
    s = reviewUiReducer(s, {
      type: 'set_drilldown',
      drilldown: {
        kind: 'category',
        key: '103',
        label: 'X',
        patch: { categoryIds: [103] },
      },
    });
    s = reviewUiReducer(s, { type: 'clear_drilldown' });
    const f = toMediaFilter(s);
    expect(f.categoryIds).toEqual([101]);
    expect(f.alsoCategoryIds).toBeUndefined();
  });

  it('Shift range uses ordered ids; Ctrl+Shift adds', () => {
    let s = createInitialState(7);
    const ordered = [1, 2, 3, 4, 5];
    s = reviewUiReducer(s, { type: 'select_click', mediaId: 2, orderedIds: ordered });
    s = reviewUiReducer(s, {
      type: 'select_click',
      mediaId: 4,
      shift: true,
      orderedIds: ordered,
    });
    expect(s.selectedIds).toEqual([2, 3, 4]);
    s = reviewUiReducer(s, {
      type: 'select_click',
      mediaId: 1,
      ctrl: true,
      orderedIds: ordered,
    });
    s = reviewUiReducer(s, {
      type: 'select_click',
      mediaId: 5,
      ctrl: true,
      shift: true,
      orderedIds: ordered,
    });
    expect(s.selectedIds.sort((a, b) => a - b)).toEqual([1, 2, 3, 4, 5]);
  });

  it('unresolvable anchor becomes single select', () => {
    let s = createInitialState(7);
    s = {
      ...s,
      selectedIds: [99],
      selectionAnchorId: 99,
    };
    s = reviewUiReducer(s, {
      type: 'select_click',
      mediaId: 3,
      shift: true,
      orderedIds: [1, 2, 3],
    });
    expect(s.selectedIds).toEqual([3]);
    expect(s.selectionAnchorId).toBe(3);
  });

  it('filter change clears selection; groupBy does not', () => {
    let s = createInitialState(7);
    s = reviewUiReducer(s, {
      type: 'select_click',
      mediaId: 1,
      orderedIds: [1, 2],
    });
    s = reviewUiReducer(s, { type: 'set_group_by', groupBy: 'uploader' });
    expect(s.selectedIds).toEqual([1]);
    s = reviewUiReducer(s, { type: 'set_sort', sort: 'title' });
    expect(s.selectedIds).toEqual([]);
  });

  it('selection status counts sum equals selected count', () => {
    const counts = countsFromSelected(
      [1, 2, 3],
      [
        { mediaId: 1, reviewStatus: 'keep' },
        { mediaId: 2, reviewStatus: 'reject' },
        { mediaId: 3, reviewStatus: 'unsure' },
      ],
    );
    expect(counts.total).toBe(3);
    expect(counts.keep + counts.reject + counts.unsure + counts.unreviewed).toBe(3);
  });
});

function SearchHarness({ initialQ = '' }: { initialQ?: string }) {
  const [state, dispatch] = useReducer(reviewUiReducer, createInitialState(7));
  useEffect(() => {
    if (initialQ) dispatch({ type: 'set_q', q: initialQ });
  }, [initialQ]);
  return (
    <>
      <Toolbar state={state} dispatch={dispatch} projects={[{ id: 7, name: 'P', slug: 'p' }]} />
      <div data-testid="q-state">{state.q}</div>
      <button type="button" onClick={() => dispatch({ type: 'remove_filter', key: 'q' })}>
        clear-q
      </button>
      <button type="button" onClick={() => dispatch({ type: 'reset_filters' })}>
        reset
      </button>
    </>
  );
}

describe('controlled search debounce', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('typing debounces into state', () => {
    render(<SearchHarness />);
    const input = screen.getByLabelText('Suche') as HTMLInputElement;
    fireEvent.change(input, { target: { value: 'chair' } });
    expect(screen.getByTestId('q-state').textContent).toBe('');
    act(() => {
      vi.advanceTimersByTime(250);
    });
    expect(screen.getByTestId('q-state').textContent).toBe('chair');
  });

  it('reset before debounce prevents stale search', () => {
    render(<SearchHarness />);
    const input = screen.getByLabelText('Suche') as HTMLInputElement;
    fireEvent.change(input, { target: { value: 'stale' } });
    fireEvent.click(screen.getByText('reset'));
    act(() => {
      vi.advanceTimersByTime(300);
    });
    expect(screen.getByTestId('q-state').textContent).toBe('');
    expect((screen.getByLabelText('Suche') as HTMLInputElement).value).toBe('');
  });

  it('breadcrumb clear empties input', () => {
    render(<SearchHarness />);
    const input = screen.getByLabelText('Suche') as HTMLInputElement;
    fireEvent.change(input, { target: { value: 'x' } });
    act(() => {
      vi.advanceTimersByTime(250);
    });
    fireEvent.click(screen.getByText('clear-q'));
    expect((screen.getByLabelText('Suche') as HTMLInputElement).value).toBe('');
    expect(screen.getByTestId('q-state').textContent).toBe('');
  });

  it('restored q syncs input', () => {
    function Restored() {
      const [state, setState] = useState(createInitialState(7));
      useEffect(() => {
        setState((s) => ({ ...s, q: 'restored' }));
      }, []);
      return (
        <Toolbar
          state={state}
          dispatch={(a) => {
            if (a.type === 'set_q') setState((s) => ({ ...s, q: a.q }));
          }}
          projects={[]}
        />
      );
    }
    render(<Restored />);
    expect((screen.getByLabelText('Suche') as HTMLInputElement).value).toBe('restored');
  });
});
