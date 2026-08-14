/**
 * One-shot heavy groups timing (FRV-39 residual). sampleSize:0 limit:20.
 *   npx tsx scripts/bench-heavy-groups-once.ts
 */
import { openReviewDb } from '../src/db.js';
import { queryGroups } from '../src/services/groups.js';
import { DEFAULT_GATE_DB, DEFAULT_PROJECT_ID } from './bench-shared.js';

const db = openReviewDb(DEFAULT_GATE_DB, { readonly: true });
const filter = {
  projectId: DEFAULT_PROJECT_ID,
  statuses: ['unreviewed', 'unsure'] as const,
  limit: 20,
  sampleSize: 0,
};

for (const groupBy of ['category', 'series', 'seed'] as const) {
  const t0 = performance.now();
  const r = queryGroups(db, { ...filter, groupBy });
  const ms = performance.now() - t0;
  const n = Array.isArray((r as { groups?: unknown[] }).groups)
    ? (r as { groups: unknown[] }).groups.length
    : '?';
  console.log(`${groupBy}: ${ms.toFixed(0)}ms groups=${n}`);
}
db.close();
