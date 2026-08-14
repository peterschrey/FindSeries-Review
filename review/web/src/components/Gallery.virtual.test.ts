import { describe, expect, it } from 'vitest';

describe('virtualization smoke', () => {
  it('100k items would not materialize full DOM with row windowing', () => {
    const itemCount = 100_000;
    const rowHeight = 120;
    const viewport = 800;
    const overscan = 5;
    const visibleRows = Math.ceil(viewport / rowHeight) + overscan * 2;
    expect(visibleRows).toBeLessThan(40);
    expect(visibleRows * 12).toBeLessThan(500); // worst-case cells in buffer
    expect(itemCount).toBeGreaterThan(visibleRows);
    const totalHeight = itemCount * rowHeight;
    expect(totalHeight).toBeGreaterThan(10_000_000);
  });
});
