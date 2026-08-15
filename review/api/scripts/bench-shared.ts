/**
 * Shared helpers for Review MVP performance benches (FRV-38/39/40).
 *
 * Defaults:
 * - Development / unit / e2e → review-dev-mini.db
 * - Explicit perf / migration / real-DB acceptance → full gate copy via REVIEW_PERF_DB_PATH
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const repoRoot = path.resolve(__dirname, '../../..');
export const benchDocDir = path.join(repoRoot, 'docs/review-mvp/bench');

/** Small representative DB — default for local API/dev when REVIEW_DB_PATH unset. */
export const DEFAULT_DEV_DB =
  process.env.REVIEW_DB_PATH ??
  'C:/Temp/FindSeries-Review-Test/review-dev-mini.db';

/**
 * Full ~100k+/gate test copy — only for explicit performance benches.
 * Does **not** follow REVIEW_DB_PATH (that defaults to mini for daily work).
 */
export const DEFAULT_PERF_DB =
  process.env.REVIEW_PERF_DB_PATH ??
  'C:/Temp/FindSeries-Review-Test/findseries-v5-phase1-gate.db';

/** @deprecated Alias for DEFAULT_PERF_DB (FRV-38/39/40 benches). */
export const DEFAULT_GATE_DB = DEFAULT_PERF_DB;

/** Prefer C:/Temp write copy only — never fall back to E: for SQLite writes. */
export const DEFAULT_WRITE_DB =
  process.env.REVIEW_WRITE_DB_PATH ?? 'C:/Temp/FindSeries-Review-Test/bench-write-copy.db';

export const PRODUCTION_DB = 'C:/FindSeriesV5-Workspace/findseries-v5.db';

/** Only writable bench DBs under this directory (normalized). */
export const BENCH_WRITE_ROOT = path.resolve('C:/Temp/FindSeries-Review-Test');

/** Refuse productive DB and any E: path for FRV-40 read/perf DBs. */
export function assertSafeBenchDb(dbPath: string): string {
  const resolved = path.resolve(dbPath);
  const lower = resolved.toLowerCase();
  if (lower === path.resolve(PRODUCTION_DB).toLowerCase()) {
    throw new Error(`REFUSING productive DB: ${resolved}`);
  }
  if (/^[eE]:[\\/]/.test(resolved)) {
    throw new Error(`REFUSING E: path for FRV-40 bench DB: ${resolved}`);
  }
  return resolved;
}

/**
 * Writable FRV-40 bulk/bench DB must live under C:\\Temp\\FindSeries-Review-Test\\.
 * Prefer DEFAULT_WRITE_DB (`bench-write-copy.db`). Never unlink/rebuild without this guard.
 * Refuses: productive DB, E:, any path outside the Temp review-test root, and the gate read DB.
 */
export function assertSafeBenchWriteDb(dbPath: string): string {
  const resolved = assertSafeBenchDb(dbPath);
  const root = BENCH_WRITE_ROOT;
  const rootPrefix = root.toLowerCase() + path.sep;
  const resolvedLower = resolved.toLowerCase();
  const rel = path.relative(root, resolved);
  const underRoot =
    rel !== '' &&
    !rel.startsWith('..') &&
    !path.isAbsolute(rel) &&
    resolvedLower.startsWith(rootPrefix);
  if (!underRoot) {
    throw new Error(
      `REFUSING write DB outside ${root}: ${resolved} (allowed: files under C:\\Temp\\FindSeries-Review-Test\\)`,
    );
  }
  const base = path.basename(resolved).toLowerCase();
  const gateBase = path.basename(path.resolve(DEFAULT_PERF_DB)).toLowerCase();
  if (base === gateBase || resolvedLower === path.resolve(DEFAULT_PERF_DB).toLowerCase()) {
    throw new Error(
      `REFUSING gate/read DB as write target: ${resolved} (use ${DEFAULT_WRITE_DB})`,
    );
  }
  return resolved;
}

export const DEFAULT_PROJECT_ID = Number(process.env.REVIEW_BENCH_PROJECT_ID ?? 7);

export const DEFAULT_MEDIA_ROOTS = (
  process.env.REVIEW_MEDIA_ROOTS ?? 'E:/Temp/FindSeriesV5-Workspace/Media'
)
  .split(path.delimiter)
  .map((s) => s.trim())
  .filter(Boolean);

export function ensureBenchDir(): void {
  fs.mkdirSync(benchDocDir, { recursive: true });
}

export function percentile(sortedAsc: number[], p: number): number {
  if (!sortedAsc.length) return NaN;
  if (sortedAsc.length === 1) return sortedAsc[0]!;
  const rank = (p / 100) * (sortedAsc.length - 1);
  const lo = Math.floor(rank);
  const hi = Math.ceil(rank);
  if (lo === hi) return sortedAsc[lo]!;
  const w = rank - lo;
  return sortedAsc[lo]! * (1 - w) + sortedAsc[hi]! * w;
}

export function stats(samplesMs: number[]): { n: number; p50: number; p95: number; mean: number; min: number; max: number } {
  const s = [...samplesMs].sort((a, b) => a - b);
  const mean = s.reduce((a, b) => a + b, 0) / (s.length || 1);
  return {
    n: s.length,
    p50: percentile(s, 50),
    p95: percentile(s, 95),
    mean,
    min: s[0] ?? NaN,
    max: s[s.length - 1] ?? NaN,
  };
}

export function timedMs<T>(fn: () => T): { ms: number; value: T } {
  const t0 = performance.now();
  const value = fn();
  return { ms: performance.now() - t0, value };
}

export async function timedMsAsync<T>(fn: () => Promise<T>): Promise<{ ms: number; value: T }> {
  const t0 = performance.now();
  const value = await fn();
  return { ms: performance.now() - t0, value };
}

/** Run fn `iterations` times; optionally discard first as warm-up when cold=false for subsequent. */
export function measureSync(
  label: string,
  iterations: number,
  fn: () => void,
  opts?: { warmup?: boolean },
): ReturnType<typeof stats> & { label: string; samples: number[] } {
  if (opts?.warmup) {
    fn();
  }
  const samples: number[] = [];
  for (let i = 0; i < iterations; i++) {
    samples.push(timedMs(fn).ms);
  }
  const s = stats(samples);
  console.log(
    `${label}: n=${s.n} p50=${s.p50.toFixed(1)}ms p95=${s.p95.toFixed(1)}ms mean=${s.mean.toFixed(1)}ms`,
  );
  return { label, samples, ...s };
}

export function rssMb(): number {
  return process.memoryUsage().rss / (1024 * 1024);
}

export function fmtMs(n: number): string {
  return Number.isFinite(n) ? n.toFixed(1) : 'n/a';
}

export function writeCsv(filePath: string, headers: string[], rows: Array<Record<string, string | number | boolean | null | undefined>>): void {
  ensureBenchDir();
  const escape = (v: unknown) => {
    const s = v == null ? '' : String(v);
    if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
    return s;
  };
  const lines = [headers.join(',')];
  for (const row of rows) {
    lines.push(headers.map((h) => escape(row[h])).join(','));
  }
  fs.writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');
}

export function regressionFlags(
  baselinePath: string,
  current: Array<{ metric: string; p50: number; p95: number }>,
  threshold = 0.2,
): string[] {
  if (!fs.existsSync(baselinePath)) return [`no baseline at ${baselinePath}`];
  const text = fs.readFileSync(baselinePath, 'utf8').trim().split(/\r?\n/);
  if (text.length < 2) return ['baseline empty'];
  const headers = text[0]!.split(',');
  const mi = headers.indexOf('metric');
  const p50i = headers.indexOf('p50_ms');
  const p95i = headers.indexOf('p95_ms');
  if (mi < 0 || p50i < 0 || p95i < 0) return ['baseline missing columns'];
  const base = new Map<string, { p50: number; p95: number }>();
  for (const line of text.slice(1)) {
    const cols = line.split(',');
    const m = cols[mi];
    if (!m) continue;
    base.set(m, { p50: Number(cols[p50i]), p95: Number(cols[p95i]) });
  }
  const flags: string[] = [];
  for (const c of current) {
    const b = base.get(c.metric);
    if (!b || !Number.isFinite(b.p50) || b.p50 <= 0) continue;
    if (c.p50 > b.p50 * (1 + threshold)) {
      flags.push(`REGRESSION ${c.metric} p50 ${b.p50.toFixed(1)}→${c.p50.toFixed(1)}ms (>${threshold * 100}%)`);
    }
    if (Number.isFinite(b.p95) && b.p95 > 0 && c.p95 > b.p95 * (1 + threshold)) {
      flags.push(`REGRESSION ${c.metric} p95 ${b.p95.toFixed(1)}→${c.p95.toFixed(1)}ms (>${threshold * 100}%)`);
    }
  }
  return flags;
}
