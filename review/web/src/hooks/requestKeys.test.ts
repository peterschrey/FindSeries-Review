import { describe, expect, it } from 'vitest';
import { createInitialState, reviewUiReducer } from '../state/reviewState';
import { __requestKeys } from '../hooks/useReviewData';

describe('request dependency keys', () => {
  it('groupBy change does not change gallery key', () => {
    let s = createInitialState(7);
    const g1 = __requestKeys.galleryKey(s);
    s = reviewUiReducer(s, { type: 'set_group_by', groupBy: 'uploader' });
    const g2 = __requestKeys.galleryKey(s);
    expect(g1).toBe(g2);
  });

  it('drilldown changes gallery key but not groups key base filter (except when groupBy same)', () => {
    let s = createInitialState(7);
    const groupsBefore = __requestKeys.groupsKey(s);
    const galleryBefore = __requestKeys.galleryKey(s);
    s = reviewUiReducer(s, {
      type: 'set_drilldown',
      drilldown: {
        kind: 'uploader',
        key: 'A',
        label: 'A',
        patch: { uploader: 'A' },
      },
    });
    expect(__requestKeys.galleryKey(s)).not.toBe(galleryBefore);
    // groups use global filter without drilldown
    expect(__requestKeys.groupsKey(s)).toBe(groupsBefore);
  });

  it('sort changes gallery not groups; groupBy changes groups not gallery', () => {
    let s = createInitialState(7);
    const gGallery = __requestKeys.galleryKey(s);
    const gGroups = __requestKeys.groupsKey(s);
    s = reviewUiReducer(s, { type: 'set_sort', sort: 'title' });
    expect(__requestKeys.galleryKey(s)).not.toBe(gGallery);
    expect(__requestKeys.groupsKey(s)).toBe(gGroups);
    s = reviewUiReducer(s, { type: 'set_group_by', groupBy: 'category' });
    expect(__requestKeys.galleryKey(s)).toBe(__requestKeys.galleryKey({ ...s, groupBy: 'uploader' }));
    expect(__requestKeys.groupsKey(s)).not.toBe(gGroups);
  });

  it('facets ignore sort/dir/groupBy', () => {
    let s = createInitialState(7);
    const f1 = __requestKeys.facetsKey(s);
    s = reviewUiReducer(s, { type: 'set_sort', sort: 'score' });
    s = reviewUiReducer(s, { type: 'set_group_by', groupBy: 'series' });
    expect(__requestKeys.facetsKey(s)).toBe(f1);
  });
});
