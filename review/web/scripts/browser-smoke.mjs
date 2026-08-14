import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(__dirname, '../../../docs/review-mvp/verification');
fs.mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();

async function shot(w, h, name) {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  const t0 = performance.now();
  await page.goto('http://localhost:5173/', { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForTimeout(1500);
  const loadMs = Math.round(performance.now() - t0);
  const pathOut = path.join(outDir, name);
  await page.screenshot({ path: pathOut, fullPage: false });
  const domThumbs = await page.locator('.thumb').count();
  const title = await page.locator('h1').textContent();
  const overview = await page.locator('.summaryCard').count();
  await page.close();
  return { name, w, h, loadMs, domThumbs, title, overview, pathOut };
}

const r1 = await shot(1920, 1080, 'phase4-ui-1920x1080.png');
const r2 = await shot(2560, 1440, 'phase4-ui-2560x1440.png');

const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
await page.goto('http://localhost:5173/', { waitUntil: 'networkidle' });
await page.waitForTimeout(1000);
const scroller = page.locator('[data-testid="gallery-scroll"]');
const before = await page.locator('.thumb').count();
for (let i = 0; i < 20; i++) {
  await scroller.evaluate((el) => {
    el.scrollTop += 800;
  });
  await page.waitForTimeout(50);
}
const after = await page.locator('.thumb').count();
await page.screenshot({ path: path.join(outDir, 'phase4-ui-scrolled.png') });
await browser.close();

const report = {
  shots: [r1, r2],
  scroll: { before, after },
  note: 'DOM thumbs stay near viewport buffer; layout vs docs/review-mvp/prototypes/review-mvp.html',
};
fs.writeFileSync(path.join(outDir, 'BROWSER_SMOKE.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
