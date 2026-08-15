import { openReviewDb } from '../src/db.js';
import { queryGroups } from '../src/services/groups.js';
import type { GroupBy } from '@findseries/review-shared';

const dbPath =
  process.env.REVIEW_DB_PATH ?? 'C:/Temp/FindSeries-Review-Test/review-dev-mini.db';
const projectId = Number(process.env.REVIEW_BENCH_PROJECT_ID ?? 7);
const db = openReviewDb(dbPath);

const modes: GroupBy[] = ['provenance', 'uploader', 'series', 'seed', 'category'];
for (const groupBy of modes) {
  const t0 = performance.now();
  const r = queryGroups(db, {
    projectId,
    statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
    groupBy,
    limit: 20,
    sampleSize: 0,
  });
  console.log(
    `${groupBy}: ${(performance.now() - t0).toFixed(0)}ms groups=${r.groups.length} total=${r.resultTotal}`,
  );
}
db.close();
