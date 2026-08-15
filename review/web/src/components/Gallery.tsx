import { useEffect, useMemo, useRef, useState, type Dispatch, type MouseEvent } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import type { MediaCard } from '@findseries/review-shared';
import type { ReviewUiAction, ReviewUiState } from '../state/reviewState';
import type { GalleryModel } from '../hooks/useReviewData';
import { ThumbImage } from './ThumbImage';

const CELL = 118;
const GAP = 7;
const CLICK_DELAY_MS = 220;

export function Gallery({
  state,
  dispatch,
  gallery,
  scrollToMediaId = null,
  onScrolled,
}: {
  state: ReviewUiState;
  dispatch: Dispatch<ReviewUiAction>;
  gallery: GalleryModel;
  scrollToMediaId?: number | null;
  onScrolled?: () => void;
}) {
  const parentRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(800);
  const clickTimerRef = useRef<number | null>(null);
  const selectedSet = useMemo(() => new Set(state.selectedIds), [state.selectedIds]);
  const orderedIds = useMemo(() => gallery.items.map((i) => i.mediaId), [gallery.items]);

  useEffect(() => {
    const el = parentRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth || 800));
    ro.observe(el);
    setWidth(el.clientWidth || 800);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    return () => {
      if (clickTimerRef.current) window.clearTimeout(clickTimerRef.current);
    };
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
    if (scrollToMediaId == null) return;
    const idx = gallery.items.findIndex((i) => i.mediaId === scrollToMediaId);
    if (idx < 0) return;
    const row = Math.floor(idx / cols);
    virtualizer.scrollToIndex(row, { align: 'center' });
    onScrolled?.();
  }, [scrollToMediaId, gallery.items, cols, virtualizer, onScrolled]);

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

  // Reset scroll only when gallery result identity changes (not groupBy)
  useEffect(() => {
    parentRef.current?.scrollTo({ top: 0 });
  }, [gallery.resetKey]);

  const onThumbClick = (e: MouseEvent, mediaId: number) => {
    e.preventDefault();
    if (e.detail > 1) return;
    const ctrl = e.ctrlKey || e.metaKey;
    const shift = e.shiftKey;
    if (clickTimerRef.current) window.clearTimeout(clickTimerRef.current);
    clickTimerRef.current = window.setTimeout(() => {
      clickTimerRef.current = null;
      dispatch({
        type: 'select_click',
        mediaId,
        ctrl,
        shift,
        orderedIds,
      });
    }, CLICK_DELAY_MS);
  };

  const onThumbDblClick = (mediaId: number) => {
    if (clickTimerRef.current) {
      window.clearTimeout(clickTimerRef.current);
      clickTimerRef.current = null;
    }
    dispatch({ type: 'set_focus', mediaId });
  };

  return (
    <div className="center">
      <div className="breadcrumbs">
        <span className="crumb" data-testid="result-total">
          Ergebnis: {gallery.total.toLocaleString('de-DE')}
        </span>
        {state.q.trim() && (
          <span className="crumb">
            Suche: {state.q}
            <button type="button" className="x" onClick={() => dispatch({ type: 'remove_filter', key: 'q' })}>
              ×
            </button>
          </span>
        )}
        {state.categoryIds?.length ? (
          <span className="crumb">
            Kategorien: {state.categoryIds.join(',')}
            <button
              type="button"
              className="x"
              onClick={() => dispatch({ type: 'remove_filter', key: 'categoryIds' })}
            >
              ×
            </button>
          </span>
        ) : null}
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
      <div className="gallerywrap" ref={parentRef} data-testid="gallery-scroll">
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
                  const sel = selectedSet.has(item.mediaId);
                  const focused = state.focusMediaId === item.mediaId;
                  return (
                    <button
                      key={item.mediaId}
                      type="button"
                      className={`thumb ${item.reviewStatus} ${sel ? 'sel' : ''}`}
                      style={{ position: 'relative', width: CELL, height: CELL - 8 }}
                      data-testid={`thumb-${item.mediaId}`}
                      data-media-id={item.mediaId}
                      aria-label={`Medium ${item.mediaId}`}
                      aria-pressed={sel}
                      onClick={(e) => onThumbClick(e, item.mediaId)}
                      onDoubleClick={() => onThumbDblClick(item.mediaId)}
                    >
                      <ThumbImage mediaId={item.mediaId} alt={item.title ?? ''} />
                      <span className="statusbadge">{item.reviewStatus}</span>
                      {item.provenance && item.provenance.length > 0 && (
                        <div className="provChips">
                          {item.provenance.slice(0, 3).map((p) => (
                            <span key={p.sourceType} className={`provChip fam-${p.family}`} title={p.sourceType}>
                              {p.chipLabel}
                            </span>
                          ))}
                        </div>
                      )}
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
