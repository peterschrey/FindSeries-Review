/**
 * FRV-40 browser metrics on Real-DB (≥100k) via the FRV-46 stack
 * (static dist + buffered /api proxy + writable C: gate copy).
 *
 * Measures authentic time-to-first-grid + scroll/virtualization/long-tasks.
 *
 *   npm run bench:frv40:browser
 *
 * Note: page.evaluate / addInitScript payloads are stringified so tsx/esbuild
 * does not inject __name helpers into the Chromium context.
 */
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { pathToFileURL } from 'node:url';
import {
  DEFAULT_PERF_DB,
  DEFAULT_PROJECT_ID,
  assertSafeBenchDb,
  benchDocDir,
  ensureBenchDir,
  fmtMs,
  writeCsv,
} from './bench-shared.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../..');
const webRoot = path.join(repoRoot, 'review/web');

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  ensureBenchDir();
  const dbPath = assertSafeBenchDb(process.env.REVIEW_PERF_DB_PATH ?? DEFAULT_PERF_DB);
  if (!fs.existsSync(dbPath)) throw new Error(`Gate DB missing: ${dbPath}`);

  process.env.REVIEW_PERF_DB_PATH = dbPath;

  if (!fs.existsSync(path.join(webRoot, 'dist/index.html'))) {
    throw new Error('review/web/dist missing — run web build first');
  }
  if (!fs.existsSync(path.join(repoRoot, 'review/api/dist/index.js'))) {
    throw new Error('review/api/dist missing — run api build first');
  }

  const stackUrl = pathToFileURL(path.join(webRoot, 'acceptance/frv46-stack.mjs')).href;
  const { startFrv46Stack, stopFrv46Stack } = await import(stackUrl);

  const requireWeb = createRequire(path.join(webRoot, 'package.json'));
  const { chromium } = requireWeb('playwright') as typeof import('playwright');

  const state = await startFrv46Stack();
  const baseURL = state.baseURL as string;

  try {
    const browser = await chromium.launch({ headless: true });
    const context = await browser.newContext();

    await context.route('**/api/media/*/thumb**', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'image/svg+xml',
        body: '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>',
      });
    });

    await context.addInitScript(`(() => {
      window.__frv40 = { longTasks: [], frameDts: [] };
      try {
        var obs = new PerformanceObserver(function (list) {
          var entries = list.getEntries();
          for (var i = 0; i < entries.length; i++) {
            window.__frv40.longTasks.push(entries[i].duration);
          }
        });
        obs.observe({ entryTypes: ['longtask'] });
      } catch (e) {}
    })()`);

    const measureVisit = async (label: string) => {
      const page = await context.newPage();
      await page.addInitScript(`(() => {
        try { localStorage.clear(); } catch (e) {}
      })()`);

      const t0 = performance.now();
      await page.goto(baseURL, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector('[data-testid="gallery-scroll"] [data-testid^="thumb-"]', {
        timeout: 300_000,
      });
      const ttfMs = performance.now() - t0;

      let resultTotal = -1;
      try {
        const text = await page.getByTestId('result-total').innerText({ timeout: 30_000 });
        const m = text.match(/Ergebnis:\s*([\d.]+)/);
        if (m) resultTotal = Number(m[1]!.replace(/\./g, ''));
      } catch {
        /* optional */
      }

      const scroll = page.getByTestId('gallery-scroll');
      const domBefore = await page.evaluate(`document.querySelectorAll('*').length`);
      const thumbsBefore = await page.evaluate(
        `document.querySelectorAll('[data-testid^="thumb-"]').length`,
      );

      await page.evaluate(`(() => {
        window.__frv40.frameDts = [];
        var last = performance.now();
        var frames = 0;
        function tick(now) {
          window.__frv40.frameDts.push(now - last);
          last = now;
          frames += 1;
          if (frames < 120) requestAnimationFrame(tick);
        }
        requestAnimationFrame(tick);
      })()`);

      for (let i = 0; i < 40; i++) {
        await scroll.evaluate(`(el) => { el.scrollTop += 900; }`);
        await sleep(40);
      }
      await sleep(800);

      const metrics = (await page.evaluate(`(() => {
        var frv = window.__frv40;
        var mem = performance.memory && performance.memory.usedJSHeapSize;
        var dts = frv.frameDts.filter(function (d) { return d > 0 && d < 5000; });
        var sorted = dts.slice().sort(function (a, b) { return a - b; });
        var p95 = sorted.length > 0
          ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))]
          : 0;
        return {
          longTasks: frv.longTasks.slice(),
          frameP95: p95,
          frameN: dts.length,
          jsHeap: mem == null ? null : mem,
          domNodes: document.querySelectorAll('*').length,
          thumbCount: document.querySelectorAll('[data-testid^="thumb-"]').length
        };
      })()`)) as {
        longTasks: number[];
        frameP95: number;
        frameN: number;
        jsHeap: number | null;
        domNodes: number;
        thumbCount: number;
      };

      await page.close();
      return {
        label,
        ttfMs,
        resultTotal,
        domBefore: Number(domBefore),
        thumbsBefore: Number(thumbsBefore),
        ...metrics,
      };
    };

    console.log(`FRV-40 browser bench against ${dbPath} @ ${baseURL}`);
    const cold = await measureVisit('Cold');
    console.log(
      `Cold first-grid: ${fmtMs(cold.ttfMs)}ms (resultTotal=${cold.resultTotal}, thumbs=${cold.thumbCount})`,
    );
    const warm = await measureVisit('Warm');
    console.log(
      `Warm first-grid: ${fmtMs(warm.ttfMs)}ms (resultTotal=${warm.resultTotal}, thumbs=${warm.thumbCount})`,
    );

    await browser.close();

    const pick = warm;
    const longTaskCount = pick.longTasks.length;
    const longTaskMax = longTaskCount ? Math.max(...pick.longTasks) : 0;
    const longTaskSum = pick.longTasks.reduce((a: number, b: number) => a + b, 0);
    const memMb = pick.jsHeap != null ? pick.jsHeap / (1024 * 1024) : null;
    const mediaN = Math.max(cold.resultTotal, warm.resultTotal, 0);

    const md = `# FRV-40 Browser Benchmark (Real-DB)

**Date:** ${new Date().toISOString()}
**DB:** \`${dbPath}\` (C: gate copy; not production)
**Project:** ${DEFAULT_PROJECT_ID}
**Result total (UI):** Cold ${cold.resultTotal} · Warm ${warm.resultTotal}
**Stack:** FRV-46 static dist + buffered /api proxy

## Metrics

| Metric | Cold | Warm |
|---|---:|---:|
| time_to_first_grid_ms | ${fmtMs(cold.ttfMs)} | ${fmtMs(warm.ttfMs)} |
| Visible thumbs in DOM | ${cold.thumbCount} | ${warm.thumbCount} |
| DOM nodes (after scroll) | — | ${pick.domNodes} |
| Long tasks (count) | ${cold.longTasks.length} | ${longTaskCount} |
| Long tasks (max ms) | ${fmtMs(cold.longTasks.length ? Math.max(...cold.longTasks) : 0)} | ${fmtMs(longTaskMax)} |
| rAF frame p95 (ms) | — | ${fmtMs(pick.frameP95)} |
| JS heap used (MB) | — | ${memMb != null ? memMb.toFixed(1) : 'n/a'} |

## Acceptance checks

- Result total > 100000: **${warm.resultTotal > 100_000 || cold.resultTotal > 100_000 ? 'YES' : 'NO'}**
- DOM thumbs << media count (virtualized): **${pick.thumbCount < 500 ? 'YES' : 'CHECK'}** (${pick.thumbCount} thumbs)
- No 100k DOM nodes: **${pick.domNodes < 50_000 ? 'YES' : 'NO'}** (${pick.domNodes})

## Notes

- Thumbs are SVG placeholders (no E: media I/O) — grid/scroll still exercise Real-DB gallery APIs.
- Long-task observer is Chromium-only; may be empty if none >50ms.
- API \`time_to_first_grid\` in frv40-results.csv remains a gallery-proxy note; **this browser metric is authoritative**.
`;

    fs.writeFileSync(path.join(benchDocDir, 'FRV40_BROWSER.md'), md, 'utf8');
    writeCsv(path.join(benchDocDir, 'frv40-browser.csv'), ['metric', 'cache', 'value', 'unit', 'note'], [
      {
        metric: 'time_to_first_grid',
        cache: 'Cold',
        value: +cold.ttfMs.toFixed(1),
        unit: 'ms',
        note: `real-db; resultTotal=${cold.resultTotal}`,
      },
      {
        metric: 'time_to_first_grid',
        cache: 'Warm',
        value: +warm.ttfMs.toFixed(1),
        unit: 'ms',
        note: `real-db; resultTotal=${warm.resultTotal}`,
      },
      {
        metric: 'scroll_dom_nodes',
        cache: 'Warm',
        value: pick.domNodes,
        unit: 'count',
        note: `thumbs=${pick.thumbCount}`,
      },
      {
        metric: 'scroll_long_tasks_count',
        cache: 'Warm',
        value: longTaskCount,
        unit: 'count',
        note: `max_ms=${longTaskMax.toFixed(1)}; sum_ms=${longTaskSum.toFixed(1)}`,
      },
      {
        metric: 'scroll_raf_frame_p95',
        cache: 'Warm',
        value: +pick.frameP95.toFixed(1),
        unit: 'ms',
        note: `n=${pick.frameN}`,
      },
      {
        metric: 'js_heap_mb',
        cache: 'Warm',
        value: memMb != null ? +memMb.toFixed(2) : '',
        unit: 'MB',
        note: memMb == null ? 'Chromium performance.memory n/a' : 'ok',
      },
      {
        metric: 'media_count_ui',
        cache: 'N/A',
        value: mediaN,
        unit: 'count',
        note: 'from Ergebnis label',
      },
    ]);

    console.log('Wrote FRV40_BROWSER.md and frv40-browser.csv');
    if (!(cold.resultTotal > 100_000 || warm.resultTotal > 100_000)) {
      throw new Error(
        `Expected UI result total >100k; got cold=${cold.resultTotal} warm=${warm.resultTotal}`,
      );
    }
    if (pick.thumbCount > 2000) {
      throw new Error(`Virtualization bound failed: ${pick.thumbCount} thumbs in DOM`);
    }
  } finally {
    await stopFrv46Stack();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
