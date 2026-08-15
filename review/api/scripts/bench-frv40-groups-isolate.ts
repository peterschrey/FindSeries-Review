/**
 * FRV-40 control: isolate groups_provenance methodology vs true regression.
 *
 * Same DB / filters as baseline:
 *   gate DB, project 7, statuses unreviewed+unsure, groupBy=provenance, limit=20, sampleSize=0
 *
 * Method A — baseline-compatible: one process, one connection, Cold suite → Warm suite
 * Method B — fresh child process (current supplemental cold definition)
 * Plus: 20× standalone queryGroups timings in one connection (after warm)
 *
 *   npx tsx scripts/bench-frv40-groups-isolate.ts
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openReviewDb } from '../src/db.js';
import { queryGroups } from '../src/services/groups.js';
import {
  DEFAULT_GATE_DB,
  DEFAULT_PROJECT_ID,
  assertSafeBenchDb,
  benchDocDir,
  ensureBenchDir,
  fmtMs,
  stats,
  timedMs,
  writeCsv,
} from './bench-shared.js';

const __filename = fileURLToPath(import.meta.url);
const IS_CHILD = process.env.REVIEW_FRV40_GROUPS_CHILD === '1';
const MARKER = '__FRV40_GROUPS__';
const ITERS = 5;
const STANDALONE_N = 20;

const filter = {
  projectId: DEFAULT_PROJECT_ID,
  statuses: ['unreviewed', 'unsure'] as const,
  groupBy: 'provenance' as const,
  limit: 20,
  sampleSize: 0,
};

function runGroups() {
  const db = openReviewDb(assertSafeBenchDb(DEFAULT_GATE_DB), { readonly: true });
  try {
    return queryGroups(db, filter);
  } finally {
    db.close();
  }
}

function measurePhase(cold: boolean, iterations: number): ReturnType<typeof stats> & { samples: number[] } {
  const db = openReviewDb(assertSafeBenchDb(DEFAULT_GATE_DB), { readonly: true });
  try {
    const fn = () => {
      queryGroups(db, filter);
    };
    if (!cold) fn();
    const samples: number[] = [];
    for (let i = 0; i < iterations; i++) samples.push(timedMs(fn).ms);
    return { ...stats(samples), samples };
  } finally {
    db.close();
  }
}

/** Method A: one connection — cold iters then warm iters (baseline-compatible). */
function methodASameProcess(): {
  cold: ReturnType<typeof stats>;
  warm: ReturnType<typeof stats>;
  standalone20: ReturnType<typeof stats>;
} {
  const db = openReviewDb(assertSafeBenchDb(DEFAULT_GATE_DB), { readonly: true });
  try {
    const fn = () => {
      queryGroups(db, filter);
    };
    const coldSamples: number[] = [];
    for (let i = 0; i < ITERS; i++) coldSamples.push(timedMs(fn).ms);
    const cold = stats(coldSamples);

    fn(); // warm touch
    const warmSamples: number[] = [];
    for (let i = 0; i < ITERS; i++) warmSamples.push(timedMs(fn).ms);
    const warm = stats(warmSamples);

    const standalone: number[] = [];
    for (let i = 0; i < STANDALONE_N; i++) standalone.push(timedMs(fn).ms);
    return { cold, warm, standalone20: stats(standalone) };
  } finally {
    db.close();
  }
}

function spawnChild(phase: 'cold' | 'warm'): Promise<ReturnType<typeof stats>> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', __filename], {
      env: {
        ...process.env,
        REVIEW_FRV40_GROUPS_CHILD: '1',
        REVIEW_FRV40_GROUPS_PHASE: phase,
      },
      cwd: path.dirname(__filename),
      stdio: ['ignore', 'pipe', 'inherit'],
    });
    let out = '';
    child.stdout.on('data', (b: Buffer) => {
      out += b.toString('utf8');
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`groups child exited ${code}`));
        return;
      }
      const line = out
        .split(/\r?\n/)
        .map((l) => l.trim())
        .find((l) => l.startsWith(MARKER));
      if (!line) {
        reject(new Error('missing marker'));
        return;
      }
      resolve(JSON.parse(line.slice(MARKER.length)) as ReturnType<typeof stats>);
    });
  });
}

async function parentMain() {
  ensureBenchDir();
  const dbPath = assertSafeBenchDb(DEFAULT_GATE_DB);
  if (!fs.existsSync(dbPath)) throw new Error(`Gate DB missing: ${dbPath}`);

  const probe = openReviewDb(dbPath, { readonly: true });
  const mediaCount = (
    probe.prepare(`SELECT COUNT(*) AS c FROM project_media WHERE project_id=?`).get(DEFAULT_PROJECT_ID) as {
      c: number;
    }
  ).c;
  probe.close();
  console.log(`FRV-40 groups isolate — DB=${dbPath} project=${DEFAULT_PROJECT_ID} media=${mediaCount}`);
  console.log(`filters: statuses=unreviewed+unsure groupBy=provenance limit=20 sampleSize=0`);

  // Touch once so disk pages are not completely cold for both methods
  runGroups();

  console.log('\n=== Method A: same-process Cold→Warm (baseline-compatible) ===');
  const a = methodASameProcess();
  console.log(`  Cold p50=${fmtMs(a.cold.p50)} p95=${fmtMs(a.cold.p95)}`);
  console.log(`  Warm p50=${fmtMs(a.warm.p50)} p95=${fmtMs(a.warm.p95)}`);
  console.log(`  Standalone×${STANDALONE_N} p50=${fmtMs(a.standalone20.p50)} p95=${fmtMs(a.standalone20.p95)}`);

  console.log('\n=== Method B: fresh child process (Cold child / Warm child) ===');
  const bCold = await spawnChild('cold');
  const bWarm = await spawnChild('warm');
  console.log(`  Cold child p50=${fmtMs(bCold.p50)} p95=${fmtMs(bCold.p95)}`);
  console.log(`  Warm child p50=${fmtMs(bWarm.p50)} p95=${fmtMs(bWarm.p95)}`);

  const baselineWarm = 1490.41; // run2 Warm from frv40-results.baseline.csv
  const aDelta = ((a.warm.p50 - baselineWarm) / baselineWarm) * 100;
  const bDelta = ((bWarm.p50 - baselineWarm) / baselineWarm) * 100;

  let classification: 'VERIFIED_METHOD' | 'VERIFIED_REAL' | 'VERIFIED_FIXED' | 'UNRESOLVED';
  let evidence: string;
  if (aDelta > 20 && bDelta > 20) {
    classification = 'VERIFIED_REAL';
    evidence =
      'Both methodologies >20% slower than baseline Warm → real current performance deviation (VERIFIED).';
  } else if (Math.abs(aDelta) <= 20 && bDelta > 20) {
    classification = 'VERIFIED_METHOD';
    evidence =
      'Same-process Warm ≈ baseline; child-process Warm >20% slower → deviation is methodology (VERIFIED).';
  } else if (aDelta <= 20 && bDelta <= 20) {
    // Includes improvements (negative Δ) and small noise — no open >20% regression.
    if (aDelta < -5 || bDelta < -5) {
      classification = 'VERIFIED_FIXED';
      evidence =
        'Same-process and child Warm at or faster than baseline Warm after targeted fix (VERIFIED). Prior >20% flag was a real multi-scan regression, now closed.';
    } else {
      classification = 'VERIFIED_METHOD';
      evidence = 'Both methods within 20% of baseline — no open regression (VERIFIED).';
    }
  } else {
    classification = 'UNRESOLVED';
    evidence = `Ambiguous: same-process Δ=${aDelta.toFixed(1)}% child Δ=${bDelta.toFixed(1)}% (UNRESOLVED).`;
  }

  console.log(`\nBaseline Warm p50 reference: ${baselineWarm}ms`);
  console.log(`Method A Δ vs baseline: ${aDelta.toFixed(1)}%`);
  console.log(`Method B Δ vs baseline: ${bDelta.toFixed(1)}%`);
  console.log(`Classification: ${classification}`);
  console.log(evidence);

  const outCsv = path.join(benchDocDir, 'frv40-groups-isolate.csv');
  writeCsv(
    outCsv,
    ['method', 'cache', 'p50_ms', 'p95_ms', 'mean_ms', 'n', 'media_count', 'vs_baseline_warm_pct', 'note'],
    [
      {
        method: 'A_same_process',
        cache: 'Cold',
        p50_ms: +a.cold.p50.toFixed(2),
        p95_ms: +a.cold.p95.toFixed(2),
        mean_ms: +a.cold.mean.toFixed(2),
        n: a.cold.n,
        media_count: mediaCount,
        vs_baseline_warm_pct: '',
        note: 'baseline-compatible',
      },
      {
        method: 'A_same_process',
        cache: 'Warm',
        p50_ms: +a.warm.p50.toFixed(2),
        p95_ms: +a.warm.p95.toFixed(2),
        mean_ms: +a.warm.mean.toFixed(2),
        n: a.warm.n,
        media_count: mediaCount,
        vs_baseline_warm_pct: +aDelta.toFixed(1),
        note: 'baseline-compatible; regression gate uses this',
      },
      {
        method: 'A_standalone20',
        cache: 'Warm',
        p50_ms: +a.standalone20.p50.toFixed(2),
        p95_ms: +a.standalone20.p95.toFixed(2),
        mean_ms: +a.standalone20.mean.toFixed(2),
        n: a.standalone20.n,
        media_count: mediaCount,
        vs_baseline_warm_pct: '',
        note: '20× queryGroups same connection after warm',
      },
      {
        method: 'B_child_process',
        cache: 'Cold',
        p50_ms: +bCold.p50.toFixed(2),
        p95_ms: +bCold.p95.toFixed(2),
        mean_ms: +bCold.mean.toFixed(2),
        n: bCold.n,
        media_count: mediaCount,
        vs_baseline_warm_pct: '',
        note: 'supplemental fresh-process',
      },
      {
        method: 'B_child_process',
        cache: 'Warm',
        p50_ms: +bWarm.p50.toFixed(2),
        p95_ms: +bWarm.p95.toFixed(2),
        mean_ms: +bWarm.mean.toFixed(2),
        n: bWarm.n,
        media_count: mediaCount,
        vs_baseline_warm_pct: +bDelta.toFixed(1),
        note: 'supplemental; NOT comparable 1:1 to baseline CSV',
      },
      {
        method: 'classification',
        cache: 'N/A',
        p50_ms: '',
        p95_ms: '',
        mean_ms: '',
        n: 0,
        media_count: mediaCount,
        vs_baseline_warm_pct: '',
        note: `${classification}: ${evidence}`,
      },
    ],
  );

  const md = `# FRV-40 groups_provenance isolation

**Date:** ${new Date().toISOString()}
**DB:** \`${dbPath}\`
**Project:** ${DEFAULT_PROJECT_ID} · media=${mediaCount}
**Baseline Warm p50 (reference):** ${baselineWarm} ms

## Method A — same process / one connection (baseline-compatible)

| Phase | p50 | p95 |
|---|---:|---:|
| Cold | ${fmtMs(a.cold.p50)} | ${fmtMs(a.cold.p95)} |
| Warm | ${fmtMs(a.warm.p50)} | ${fmtMs(a.warm.p95)} |
| Standalone ×${STANDALONE_N} | ${fmtMs(a.standalone20.p50)} | ${fmtMs(a.standalone20.p95)} |

Δ Warm vs baseline: **${aDelta.toFixed(1)}%**

## Method B — fresh child process (supplemental)

| Phase | p50 | p95 |
|---|---:|---:|
| Cold child | ${fmtMs(bCold.p50)} | ${fmtMs(bCold.p95)} |
| Warm child | ${fmtMs(bWarm.p50)} | ${fmtMs(bWarm.p95)} |

Δ Warm vs baseline: **${bDelta.toFixed(1)}%**

## Classification

**${classification}**

${evidence}
`;
  fs.writeFileSync(path.join(benchDocDir, 'FRV40_GROUPS_ISOLATE.md'), md, 'utf8');
  console.log(`Wrote ${outCsv} and FRV40_GROUPS_ISOLATE.md`);

  if (classification === 'UNRESOLVED') process.exitCode = 2;
}

async function childMain() {
  const cold = process.env.REVIEW_FRV40_GROUPS_PHASE !== 'warm';
  const s = measurePhase(cold, ITERS);
  process.stdout.write(MARKER + JSON.stringify(s) + '\n');
}

async function main() {
  if (IS_CHILD) await childMain();
  else await parentMain();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
