import { useState } from 'react';
import { thumbUrl } from '../api/client';

export function ThumbImage({
  mediaId,
  alt,
  className,
  size = 160,
}: {
  mediaId: number;
  alt?: string;
  className?: string;
  size?: number;
}) {
  const [failed, setFailed] = useState(false);
  if (failed) {
    return <div className={`thumbPlaceholder ${className ?? ''}`}>kein Vorschaubild</div>;
  }
  return (
    <img
      className={className ?? 'thumbimg'}
      src={thumbUrl(mediaId, size)}
      alt={alt ?? ''}
      loading="lazy"
      decoding="async"
      onError={() => setFailed(true)}
    />
  );
}
