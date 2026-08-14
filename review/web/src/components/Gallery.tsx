import { useEffect, useMemo, useRef, useState } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import type { Dispatch } from 'react';
import type { MediaCard } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';
import type { GalleryModel } from '../hooks/useReviewData';
import { ThumbImage } from './ThumbImage';

const CELL = 118;
const GAP = 7;

export function Gallery({
  state,
  dispatch,
  gallery,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  gallery: GalleryModel;
}) {
  const parentRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(800);

  useEffect(() => {
    const el = parentRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth || 800));
    ro.observe(el);
    setWidth(el.clientWidth || 800);
    return () => ro.disconnect();
  }, []);

  const cols = Math.max(1, Math.floor((width + GAP) / (CELL + GAP)));

  const rows = useMemo(() => {
    const out: MediaCard[][] = [];
    for (let i = 0; i < gallery.items.length; i += cols) {
      out.push(gallery.items.slice(i, i + cols));
    }
    return out;
  }, [gallery.items, cols]);

  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => CELL + GAP,
    overscan: 6,
  });

  useEffect(() => {
    const el = parentRef.current;
    if (!el) return;
    const onScroll = () => {
      const remaining = el.scrollHeight - el.scrollTop - el.clientHeight;
      if (remaining < 600) gallery.loadMore();
    };
    el.addEventListener('scroll', onScroll);
    return () => el.removeEventListener('scroll', onScroll);
  }, [gallery]);

  // Reset scroll on filter change
  useEffect(() => {
    parentRef.current?.scrollTo({ top: 0 });
  }, [gallery.resetKey]);

  return (
    <div className="center">
      <div className="breadcrumbs">
        <span className="crumb">Ergebnis: {gallery.total.toLocaleString('de-DE')}</span>
        {state.q.trim() && (
          <span className="crumb">
            Suche: {state.q}
            <button type="button" className="x" onClick={() => dispatch({ type: 'remove_filter', key: 'q' })}>
              ×
            </button>
          </span>
        )}
        {state.drilldown && (
          <span className="crumb">
            {state.drilldown.label}
            <button
              type="button"
              className="x"
              onClick={() => dispatch({ type: 'clear_drilldown' })}
            >
              ×
            </button>
          </span>
        )}
        {gallery.loading && <span className="crumb">lädt…</span>}
        {gallery.error && <span className="crumb">Fehler: {gallery.error}</span>}
      </div>
      <div className="gallerywrap" ref={parentRef}>
        {(gallery.loading || gallery.loadingMore) && (
          <div className="loadingBanner">{gallery.loading ? 'Galerie…' : 'Nachladen…'}</div>
        )}
        <div className="galleryInner" style={{ height: virtualizer.getTotalSize() }}>
          {virtualizer.getVirtualItems().map((vr) => {
            const row = rows[vr.index] ?? [];
            return (
              <div
                key={vr.key}
                style={{
                  position: 'absolute',
                  top: 0,
                  left: 0,
                  width: '100%',
                  height: vr.size,
                  transform: `translateY(${vr.start}px)`,
                  display: 'grid',
                  gridTemplateColumns: `repeat(${cols}, ${CELL}px)`,
                  gap: GAP,
                }}
              >
                {row.map((item) => {
                  const sel = state.selectedIds.includes(item.mediaId);
                  const focused = state.focusMediaId === item.mediaId;
                  return (
                    <button
                      key={item.mediaId}
                      type="button"
                      className={`thumb ${item.reviewStatus} ${sel ? 'sel' : ''}`}
                      style={{ position: 'relative', width: CELL, height: CELL - 8 }}
                      onClick={(e) =>
                        dispatch({
                          type: 'select_click',
                          mediaId: item.mediaId,
                          ctrl: e.ctrlKey || e.metaKey,
                        })
                      }
                      onDoubleClick={() =>
                        dispatch({ type: 'set_focus', mediaId: item.mediaId })
                      }
                    >
                      <ThumbImage mediaId={item.mediaId} alt={item.title ?? ''} />
                      <span className="statusbadge">{item.reviewStatus}</span>
                      {focused && <span className="focusMarker">FOKUS</span>}
                      <div className="thumbfoot">{item.title ?? `#${item.mediaId}`}</div>
                    </button>
                  );
                })}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
