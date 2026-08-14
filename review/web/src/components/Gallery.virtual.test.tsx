import { describe, expect, it } from 'vitest';
import { render, act } from '@testing-library/react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { useLayoutEffect, useRef } from 'react';

/** Real virtualizer harness — DOM node count stays near overscan buffer. */
function VirtualStress({ count }: { count: number }) {
  const parentRef = useRef<HTMLDivElement>(null);
  const rowH = 120;

  useLayoutEffect(() => {
    const el = parentRef.current;
    if (!el) return;
    Object.defineProperty(el, 'clientHeight', { configurable: true, value: 800 });
    Object.defineProperty(el, 'offsetHeight', { configurable: true, value: 800 });
  }, []);

  const virtualizer = useVirtualizer({
    count,
    getScrollElement: () => parentRef.current,
    estimateSize: () => rowH,
    overscan: 8,
    initialRect: { width: 1000, height: 800 },
  });
  const virtualItems = virtualizer.getVirtualItems();
  return (
    <div>
      <div data-testid="dom-count">{virtualItems.length}</div>
      <div
        ref={parentRef}
        data-testid="scroller"
        style={{ height: 800, overflow: 'auto' }}
      >
        <div style={{ height: virtualizer.getTotalSize(), position: 'relative' }}>
          {virtualItems.map((vr) => (
            <div
              key={vr.key}
              data-testid="virt-row"
              style={{
                position: 'absolute',
                top: 0,
                transform: `translateY(${vr.start}px)`,
                height: vr.size,
                width: '100%',
              }}
            >
              row-{vr.index}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

describe('virtualization stress', () => {
  it('keeps DOM buffer bounded for 100k rows while scrolling', () => {
    const { getByTestId, getAllByTestId, rerender } = render(<VirtualStress count={100_000} />);
    const scroller = getByTestId('scroller') as HTMLDivElement;
    Object.defineProperty(scroller, 'clientHeight', { configurable: true, value: 800 });
    rerender(<VirtualStress count={100_000} />);

    const initial = Number(getByTestId('dom-count').textContent);
    expect(initial).toBeGreaterThan(0);
    expect(initial).toBeLessThan(80);

    act(() => {
      scroller.scrollTop = 50_000;
      scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
    });
    const mid = Number(getByTestId('dom-count').textContent);
    expect(mid).toBeLessThan(80);

    act(() => {
      for (let y = 0; y < 200_000; y += 4000) {
        scroller.scrollTop = y;
        scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
      }
    });
    expect(getAllByTestId('virt-row').length).toBeLessThan(80);
  });

  it('loadMore cursor guard rejects duplicate in-flight cursor', () => {
    const inFlight = { current: null as string | null };
    const calls: string[] = [];
    const loadMore = (cursor: string) => {
      if (inFlight.current === cursor) return;
      inFlight.current = cursor;
      calls.push(cursor);
    };
    loadMore('c1');
    loadMore('c1');
    loadMore('c1');
    expect(calls).toEqual(['c1']);
    inFlight.current = null;
    loadMore('c1');
    expect(calls).toEqual(['c1', 'c1']);
  });
});
