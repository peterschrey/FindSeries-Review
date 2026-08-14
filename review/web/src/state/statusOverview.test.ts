import { describe, expect, it } from 'vitest';
import { emptyCounts, countsFromSelected } from '../state/reviewState';

/** Status-overview semantics (pure) — inventory ≠ result ≠ selection. */
describe('status overview semantics', () => {
  it('inventory independent of result totals', () => {
    const inventory = { unreviewed: 80, keep: 10, reject: 5, unsure: 5, total: 100 };
    const result = { unreviewed: 40, keep: 0, reject: 0, unsure: 5, total: 45 };
    expect(inventory.total).toBeGreaterThan(result.total);
    expect(result.unreviewed + result.keep + result.reject + result.unsure).toBe(result.total);
    expect(inventory.unreviewed + inventory.keep + inventory.reject + inventory.unsure).toBe(
      inventory.total,
    );
  });

  it('selection counts sum equals selected length when all known', () => {
    const counts = countsFromSelected(
      [1, 2, 3, 4],
      [
        { mediaId: 1, reviewStatus: 'unreviewed' },
        { mediaId: 2, reviewStatus: 'keep' },
        { mediaId: 3, reviewStatus: 'reject' },
        { mediaId: 4, reviewStatus: 'unsure' },
      ],
    );
    expect(counts.total).toBe(4);
    expect(counts).toEqual({
      unreviewed: 1,
      keep: 1,
      reject: 1,
      unsure: 1,
      total: 4,
    });
  });

  it('empty counts baseline', () => {
    expect(emptyCounts().total).toBe(0);
  });
});
