import type { StatusCounts } from '@findseries/review-shared';

function Bar({ counts }: { counts: StatusCounts }) {
  const t = Math.max(1, counts.total);
  const segs = [
    { n: counts.unreviewed, c: 'var(--unrated)' },
    { n: counts.unsure, c: 'var(--unsure)' },
    { n: counts.keep, c: 'var(--keep)' },
    { n: counts.reject, c: 'var(--reject)' },
  ];
  return (
    <div className="statusBar">
      {segs.map((s, i) => (
        <div
          key={i}
          className="seg"
          style={{ width: `${(100 * s.n) / t}%`, background: s.c }}
        />
      ))}
    </div>
  );
}

function Card({
  title,
  total,
  counts,
}: {
  title: string;
  total: number;
  counts: StatusCounts;
}) {
  return (
    <div className="summaryCard">
      <h3>{title}</h3>
      <div className="summaryTop">
        <strong>{total.toLocaleString('de-DE')} Medien</strong>
      </div>
      <Bar counts={counts} />
      <div className="legend">
        <div className="legendItem">
          <b>{counts.unreviewed}</b>
          <span>Unbewertet</span>
        </div>
        <div className="legendItem">
          <b>{counts.unsure}</b>
          <span>Unsicher</span>
        </div>
        <div className="legendItem">
          <b>{counts.keep}</b>
          <span>Behalten</span>
        </div>
        <div className="legendItem">
          <b>{counts.reject}</b>
          <span>Löschen</span>
        </div>
      </div>
    </div>
  );
}

export function StatusOverview({
  inventory,
  result,
  selection,
}: {
  inventory: StatusCounts;
  result: StatusCounts;
  selection: StatusCounts;
}) {
  return (
    <div className="overview">
      <Card title="Gesamtbestand" total={inventory.total} counts={inventory} />
      <Card title="Ergebnismenge" total={result.total} counts={result} />
      <Card title="Auswahl" total={selection.total} counts={selection} />
    </div>
  );
}

export function MiniStatusBar({ counts }: { counts: StatusCounts }) {
  const t = Math.max(1, counts.total);
  return (
    <div className="smallbar">
      <div className="seg" style={{ width: `${(100 * counts.unreviewed) / t}%`, background: 'var(--unrated)' }} />
      <div className="seg" style={{ width: `${(100 * counts.unsure) / t}%`, background: 'var(--unsure)' }} />
      <div className="seg" style={{ width: `${(100 * counts.keep) / t}%`, background: 'var(--keep)' }} />
      <div className="seg" style={{ width: `${(100 * counts.reject) / t}%`, background: 'var(--reject)' }} />
    </div>
  );
}
