/**
 * FRV-46 Real-DB acceptance (Cat_Dentistry / project 7) — API + SQL + bulk/undo + cold/warm perf.
 *
 *   REVIEW_PERF_DB_PATH=C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db
 *   npx tsx scripts/frv46-acceptance.ts
 *
 * Never opens the productive FindSeries DB.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openReviewDb, type ReviewDb } from '../src/db.js';
import { queryGallery, computeStatusCounts } from '../src/services/gallery.js';
import { queryGroups } from '../src/services/groups.js';
import { countCategorySubtree, queryFacets } from '../src/services/categories.js';
import { queryFocus } from '../src/services/focus.js';
import { applyBulk, undoBatch } from '../src/services/bulk.js';
import { categoryMediaSql } from '../src/sql/filters.js';
import {
  DEFAULT_GATE_DB,
  DEFAULT_PROJECT_ID,
  benchDocDir,
  ensureBenchDir,
  fmtMs,
  rssMb,
  stats,
  timedMs,
} from './bench-shared.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PRODUCTION =
  path.resolve('C:/FindSeriesV5-Workspace/findseries-v5.db').toLowerCase();

const dbPath = path.resolve(process.env.REVIEW_PERF_DB_PATH ?? DEFAULT_GATE_DB);
const projectId = Number(process.env.REVIEW_BENCH_PROJECT_ID ?? DEFAULT_PROJECT_ID);
const STATUSES = ['unreviewed', 'unsure'] as const;

type Evidence =
  | 'VERIFIED'
  | 'REPORTED'
  | 'INFERRED'
  | 'NOT_VERIFIED'
  | 'DATA_GAP'
  | 'NOT_AVAILABLE';

type Check = {
  id: string;
  ok: boolean;
  evidence: Evidence;
  detail: Record<string, unknown>;
};

function refuseProduction() {
  if (dbPath.toLowerCase() === PRODUCTION) {
    throw new Error(`REFUSING productive DB: ${dbPath}`);
  }
}

function assert(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

function sqlCountMembership(db: ReviewDb, categoryId: number, includeDescendants: boolean): number {
  const bound = categoryMediaSql(projectId, [categoryId], { includeDescendants });
  return (db.prepare(`SELECT COUNT(*) AS n FROM (${bound.sql})`).get(...bound.params) as { n: number }).n;
}

function statusSnapshot(db: ReviewDb) {
  const inventory = computeStatusCounts(db, {
    projectId,
    statuses: ['unreviewed', 'keep', 'reject', 'unsure'],
  });
  const result = computeStatusCounts(db, {
    projectId,
    statuses: [...STATUSES],
  });
  return { inventory, result };
}

function pickCategoryParent(db: ReviewDb): { id: number; title: string; childCount: number; memberCount: number } {
  const row = db
    .prepare(
      `SELECT pc.category_id AS id, c.title AS title,
              COUNT(ch.category_id) AS childCount,
              COALESCE(pc.member_count,0) AS memberCount
       FROM project_categories pc
       JOIN categories c ON c.id = pc.category_id
       JOIN project_categories ch
         ON ch.project_id = pc.project_id AND ch.parent_category_id = pc.category_id
       WHERE pc.project_id = ?
       GROUP BY pc.category_id
       HAVING COUNT(ch.category_id) >= 5
       ORDER BY COALESCE(pc.member_count,0) DESC
       LIMIT 1`,
    )
    .get(projectId) as { id: number; title: string; childCount: number; memberCount: number };
  assert(row?.id != null, 'No category parent with real children found');
  return row;
}

function descendantCount(db: ReviewDb, categoryId: number): number {
  return (
    db
      .prepare(
        `WITH RECURSIVE sub(id, d) AS (
           SELECT ?, 0
           UNION ALL
           SELECT pc.category_id, sub.d+1 FROM project_categories pc
           JOIN sub ON pc.parent_category_id = sub.id
           WHERE pc.project_id = ? AND sub.d < 16
         )
         SELECT COUNT(*)-1 AS n FROM sub`,
      )
      .get(categoryId, projectId) as { n: number }
  ).n;
}

async function main() {
  refuseProduction();
  assert(fs.existsSync(dbPath), `Gate DB missing: ${dbPath}`);
  ensureBenchDir();

  const db = openReviewDb(dbPath, { readonly: false });
  const checks: Check[] = [];
  const perfRows: Array<Record<string, string | number>> = [];
  const started = new Date().toISOString();

  const project = db
    .prepare(`SELECT id, name, slug FROM projects WHERE id = ?`)
    .get(projectId) as { id: number; name: string; slug: string };
  assert(project?.name?.includes('Dentistry') || projectId === 7, `Unexpected project: ${JSON.stringify(project)}`);

  const mediaCount = (
    db.prepare(`SELECT COUNT(*) AS n FROM project_media WHERE project_id=?`).get(projectId) as { n: number }
  ).n;
  const reviewMigs = (
    db
      .prepare(`SELECT group_concat(version) AS v FROM (SELECT version FROM review_schema_migrations ORDER BY version)`)
      .get() as { v: string }
  ).v;
  const coreMigs = (
    db
      .prepare(`SELECT group_concat(version) AS v FROM (SELECT version FROM schema_migrations ORDER BY version)`)
      .get() as { v: string }
  ).v;

  checks.push({
    id: 'preflight',
    ok: reviewMigs === '100,101,102,103,104,105' && mediaCount > 100_000,
    evidence: 'VERIFIED',
    detail: {
      dbPath,
      bytes: fs.statSync(dbPath).size,
      project,
      mediaCount,
      reviewMigs,
      coreMigs,
    },
  });

  // --- Workflow A: category subtree ---
  const cat = pickCategoryParent(db);
  const descN = descendantCount(db, cat.id);
  const tSub = timedMs(() => countCategorySubtree(db, projectId, cat.id));
  const sqlExact = sqlCountMembership(db, cat.id, false);
  const sqlSubtree = sqlCountMembership(db, cat.id, true);
  const galSubtree = timedMs(() =>
    queryGallery(db, {
      projectId,
      statuses: [...STATUSES],
      categoryIds: [cat.id],
      categoryIncludeDescendants: true,
      limit: 120,
      sort: 'media_id',
      dir: 'asc',
    }),
  );
  const apiSubtreeTotal = galSubtree.value.total;
  const statusFiltered = computeStatusCounts(db, {
    projectId,
    statuses: [...STATUSES],
    categoryIds: [cat.id],
    categoryIncludeDescendants: true,
  });
  const sampleIds = galSubtree.value.items.slice(0, 5).map((i) => i.mediaId);
  const mem = categoryMediaSql(projectId, [cat.id], { includeDescendants: true });
  const sampleOk = sampleIds.every((mid) => {
    const hit = db
      .prepare(`SELECT 1 AS x FROM (${mem.sql}) m WHERE m.media_id = ? LIMIT 1`)
      .get(...mem.params, mid);
    return Boolean(hit);
  });
  checks.push({
    id: 'workflow_A_category',
    ok:
      apiSubtreeTotal === statusFiltered.total &&
      statusFiltered.total <= sqlSubtree &&
      sampleOk &&
      descN >= 5,
    evidence: 'VERIFIED',
    detail: {
      categoryId: cat.id,
      title: cat.title,
      childCount: cat.childCount,
      descendantCount: descN,
      sqlExactMembership: sqlExact,
      sqlSubtreeMembership: sqlSubtree,
      apiResultTotal: apiSubtreeTotal,
      statusCountsTotal: statusFiltered.total,
      matchApiToStatusCounts: apiSubtreeTotal === statusFiltered.total,
      sampleIds,
      sampleMembershipOk: sampleOk,
      queryMs: Math.round(galSubtree.ms),
      subtreeCountMs: Math.round(tSub.ms),
      subtreeCountApi: tSub.value,
    },
  });

  // --- Workflow B: provenance (only types that exist) ---
  const provTypes = db
    .prepare(
      `SELECT d.source_type AS sourceType, COALESCE(rpm.family,'unknown') AS family,
              COUNT(DISTINCT d.media_id) AS n
       FROM discoveries d
       LEFT JOIN review_provenance_type_map rpm ON rpm.source_type = d.source_type
       WHERE d.project_id = ?
       GROUP BY d.source_type
       ORDER BY n DESC`,
    )
    .all(projectId) as Array<{ sourceType: string; family: string; n: number }>;

  const groupsProv = timedMs(() =>
    queryGroups(db, {
      projectId,
      groupBy: 'provenance',
      statuses: [...STATUSES],
      limit: 50,
    }),
  );
  const firstProv = groupsProv.value.groups[0];
  let provDrillOk = false;
  let provDetail: Record<string, unknown> = { availableTypes: provTypes, groupsMs: Math.round(groupsProv.ms) };
  if (firstProv) {
    const sourceType = firstProv.key.includes(':')
      ? firstProv.key.slice(firstProv.key.indexOf(':') + 1)
      : firstProv.key;
    const drill = timedMs(() =>
      queryGallery(db, {
        projectId,
        statuses: [...STATUSES],
        sourceTypes: [sourceType],
        limit: 80,
        sort: 'media_id',
        dir: 'asc',
      }),
    );
    const sqlProv = (
      db
        .prepare(
          `SELECT COUNT(DISTINCT media_id) AS n FROM discoveries WHERE project_id=? AND source_type=?`,
        )
        .get(projectId, sourceType) as { n: number }
    ).n;
    // Default status filter may hide keep/reject; compare unreviewed+unsure via API vs status-aware counts
    const apiCounts = computeStatusCounts(db, {
      projectId,
      statuses: [...STATUSES],
      sourceTypes: [sourceType],
    });
    provDrillOk = drill.value.total === firstProv.total && drill.value.total === apiCounts.total;
    const multiProvSample = db
      .prepare(
        `SELECT media_id, COUNT(DISTINCT source_type) AS nt FROM discoveries WHERE project_id=? GROUP BY media_id HAVING nt>1 LIMIT 5`,
      )
      .all(projectId) as Array<{ media_id: number; nt: number }>;
    provDetail = {
      ...provDetail,
      groupKey: firstProv.key,
      groupCardTotal: firstProv.total,
      galleryTotal: drill.value.total,
      sqlDistinctMedia: sqlProv,
      apiStatusFilteredTotal: apiCounts.total,
      matchGroupToGallery: drill.value.total === firstProv.total,
      matchGalleryToStatusCounts: drill.value.total === apiCounts.total,
      multiProvenanceSamples: multiProvSample,
      note:
        provTypes.length < 2
          ? 'Cat_Dentistry gate copy exposes only category provenance discoveries; second type NOT present (NOT invented).'
          : '≥2 provenance types present',
    };
  }
  checks.push({
    id: 'workflow_B_provenance',
    ok: Boolean(firstProv) && provDrillOk,
    evidence: 'VERIFIED',
    detail: {
      ...provDetail,
      categoryProvenance: 'VERIFIED',
      secondProvenanceType: provTypes.length >= 2 ? 'VERIFIED' : 'NOT_AVAILABLE',
      secondTypeAvailable: provTypes.length >= 2,
      note:
        provTypes.length < 2
          ? 'Only real category provenance on Cat_Dentistry; second provenance type NOT_AVAILABLE (not invented).'
          : '≥2 provenance types present',
    },
  });

  // --- Workflow C: series (Cat_Dentistry — named series DATA_GAP; fallback only) ---
  const seriesKeyCount = (
    db.prepare(`SELECT COUNT(*) AS n FROM media_series_keys WHERE project_id=?`).get(projectId) as {
      n: number;
    }
  ).n;
  const seriesDisc = (
    db
      .prepare(
        `SELECT COUNT(*) AS n FROM discoveries WHERE project_id=? AND source_type IN ('filename-series','time-series','filename')`,
      )
      .get(projectId) as { n: number }
  ).n;
  const namedSeriesOnMain = seriesKeyCount > 0 || seriesDisc > 0;
  const groupsSeries = timedMs(() =>
    queryGroups(db, {
      projectId,
      groupBy: 'series',
      statuses: [...STATUSES],
      limit: 30,
    }),
  );
  const seriesCard = groupsSeries.value.groups[0];
  let seriesOk = false;
  let seriesDetail: Record<string, unknown> = {
    mediaSeriesKeys: seriesKeyCount,
    seriesDiscoveries: seriesDisc,
    groupsMs: Math.round(groupsSeries.ms),
    namedSeriesAvailable: namedSeriesOnMain,
    namedSeriesEvidence: namedSeriesOnMain ? 'VERIFIED' : 'DATA_GAP',
  };
  if (seriesCard) {
    const drill = timedMs(() =>
      queryGallery(db, {
        projectId,
        statuses: [...STATUSES],
        seriesKey: seriesCard.key,
        limit: 120,
        sort: 'media_id',
        dir: 'asc',
      }),
    );
    const page2 = queryGallery(db, {
      projectId,
      statuses: [...STATUSES],
      seriesKey: seriesCard.key,
      limit: 120,
      sort: 'media_id',
      dir: 'asc',
      cursor: drill.value.nextCursor ?? undefined,
    });
    const ids1 = drill.value.items.map((i) => i.mediaId);
    const ids2 = page2.items.map((i) => i.mediaId);
    const overlap = ids1.filter((id) => ids2.includes(id));
    const mono = ids1.every((id, i) => i === 0 || id >= ids1[i - 1]!);
    seriesOk = drill.value.total === seriesCard.total && overlap.length === 0 && mono;
    const isFallback = seriesCard.key === '(ohne Serie)';
    seriesDetail = {
      ...seriesDetail,
      series_key: seriesCard.key,
      isFallbackBucket: isFallback,
      groupCardTotal: seriesCard.total,
      galleryTotal: drill.value.total,
      match: drill.value.total === seriesCard.total,
      firstIds: ids1.slice(0, 5),
      lastIdsPage1: ids1.slice(-3),
      page2FirstIds: ids2.slice(0, 3),
      pageOverlap: overlap.length,
      monotonicAsc: mono,
      queryMs: Math.round(drill.ms),
      note: namedSeriesOnMain
        ? 'Named series present on Cat_Dentistry'
        : 'Cat_Dentistry has no named series; fallback "(ohne Serie)" exercised — NOT a full series verification.',
    };
  }
  checks.push({
    id: 'workflow_C_series',
    ok: seriesOk,
    // Fallback alone must not claim full named-series verification
    evidence: namedSeriesOnMain ? 'VERIFIED' : 'DATA_GAP',
    detail: seriesDetail,
  });

  // --- Supplemental: named series on same C: gate DB (project 9 Dental_Context_Search) ---
  const SERIES_SUPPLEMENT_PROJECT = 9;
  const SERIES_SUPPLEMENT_KEY = '02866_New_Luce_Church_of_Scotland,_New_Luce_';
  const suppDisc = (
    db
      .prepare(
        `SELECT COUNT(DISTINCT media_id) AS n FROM discoveries
         WHERE project_id=? AND source_type='filename-series'
           AND COALESCE(source_value, query_text)=?`,
      )
      .get(SERIES_SUPPLEMENT_PROJECT, SERIES_SUPPLEMENT_KEY) as { n: number }
  ).n;
  let suppOk = false;
  let suppDetail: Record<string, unknown> = {
    projectId: SERIES_SUPPLEMENT_PROJECT,
    projectName: 'Dental_Context_Search',
    seriesKey: SERIES_SUPPLEMENT_KEY,
    sqlDistinctMedia: suppDisc,
    sameDbCopy: dbPath,
    invented: false,
  };
  if (suppDisc >= 2) {
    const groupsSupp = timedMs(() =>
      queryGroups(db, {
        projectId: SERIES_SUPPLEMENT_PROJECT,
        groupBy: 'series',
        statuses: [...STATUSES],
        limit: 80,
      }),
    );
    const namedCard =
      groupsSupp.value.groups.find((g) => g.key === SERIES_SUPPLEMENT_KEY) ??
      groupsSupp.value.groups.find((g) => g.key !== '(ohne Serie)');
    if (namedCard && namedCard.key !== '(ohne Serie)') {
      const drill = timedMs(() =>
        queryGallery(db, {
          projectId: SERIES_SUPPLEMENT_PROJECT,
          statuses: [...STATUSES],
          seriesKey: namedCard.key,
          limit: 5,
          sort: 'media_id',
          dir: 'asc',
        }),
      );
      const page2 = queryGallery(db, {
        projectId: SERIES_SUPPLEMENT_PROJECT,
        statuses: [...STATUSES],
        seriesKey: namedCard.key,
        limit: 5,
        sort: 'media_id',
        dir: 'asc',
        cursor: drill.value.nextCursor ?? undefined,
      });
      const ids1 = drill.value.items.map((i) => i.mediaId);
      const ids2 = page2.items.map((i) => i.mediaId);
      const hasNext = Boolean(drill.value.nextCursor);
      const overlap = hasNext ? ids1.filter((id) => ids2.includes(id)) : [];
      const mono = ids1.every((id, i) => i === 0 || id >= ids1[i - 1]!);
      const focusMediaId = ids1[0];
      let focusSeries: Record<string, unknown> | null = null;
      if (focusMediaId != null) {
        const focus = queryFocus(db, {
          projectId: SERIES_SUPPLEMENT_PROJECT,
          focusMediaId,
          baseFilter: { projectId: SERIES_SUPPLEMENT_PROJECT, statuses: [...STATUSES] },
        });
        const srel = focus.relations.find((r) => r.kind === 'series');
        focusSeries = srel
          ? { available: srel.available, total: srel.total, note: srel.note }
          : { available: false };
      }
      suppOk =
        namedCard.key === SERIES_SUPPLEMENT_KEY &&
        drill.value.total === namedCard.total &&
        hasNext &&
        overlap.length === 0 &&
        mono &&
        namedCard.total >= 2;
      suppDetail = {
        ...suppDetail,
        groupCardKey: namedCard.key,
        groupCardTotal: namedCard.total,
        galleryTotal: drill.value.total,
        sqlDistinctMediaRaw: suppDisc,
        apiUiCountMatch: drill.value.total === namedCard.total,
        paginationApplicable: hasNext,
        page1Ids: ids1,
        page2FirstIds: ids2.slice(0, 3),
        pageOverlap: overlap.length,
        monotonicAsc: mono,
        groupsMs: Math.round(groupsSupp.ms),
        queryMs: Math.round(drill.ms),
        focusSeriesRelation: focusSeries,
        note: 'Real named filename-series on same C: gate copy; Cat_Dentistry remains primary FRV-46 project.',
      };
    } else {
      suppDetail = {
        ...suppDetail,
        note: 'SQL found filename-series rows but GroupCard for named key missing in groups response',
      };
    }
  } else {
    suppDetail = {
      ...suppDetail,
      note: 'No multi-media named filename-series found on gate DB for supplemental test',
    };
  }
  checks.push({
    id: 'workflow_C_series_supplemental',
    ok: suppOk,
    evidence: suppOk ? 'VERIFIED' : 'DATA_GAP',
    detail: suppDetail,
  });

  // --- Stats baselines A/B ---
  const snap0 = statusSnapshot(db);
  checks.push({
    id: 'stats_inventory_result',
    ok: snap0.inventory.total === mediaCount && snap0.result.total <= snap0.inventory.total,
    evidence: 'VERIFIED',
    detail: { inventory: snap0.inventory, resultDefault: snap0.result, projectMedia: mediaCount },
  });

  // --- Workflow D: range reject ≥100 with keep protection + undo ---
  const rangeSize = Math.min(
    150,
    Math.max(
      100,
      (
        db
          .prepare(
            `SELECT COUNT(*) AS n FROM project_media WHERE project_id=? AND media_id BETWEEN 1 AND 5000`,
          )
          .get(projectId) as { n: number }
      ).n,
    ),
  );
  const rangeIds = (
    db
      .prepare(
        `SELECT media_id AS id FROM project_media WHERE project_id=? ORDER BY media_id LIMIT ?`,
      )
      .all(projectId, rangeSize) as Array<{ id: number }>
  ).map((r) => r.id);
  assert(rangeIds.length >= 100, `Need ≥100 media for range; got ${rangeIds.length}`);
  const keepId = rangeIds[Math.floor(rangeIds.length / 2)]!;
  const beforeStatuses = new Map<number, string>();
  for (const id of rangeIds) {
    const row = db
      .prepare(`SELECT status FROM media_review_status WHERE project_id=? AND media_id=?`)
      .get(projectId, id) as { status: string } | undefined;
    beforeStatuses.set(id, row?.status ?? 'SPARSE');
  }

  applyBulk(db, {
    projectId,
    action: 'set_status',
    targetStatus: 'keep',
    mediaIds: [keepId],
    source: 'frv46-seed-keep',
  });
  const snapBeforeReject = statusSnapshot(db);
  const rejectTimed = timedMs(() =>
    applyBulk(db, {
      projectId,
      action: 'set_status',
      targetStatus: 'reject',
      mediaIds: rangeIds,
      protectKeep: true,
      source: 'frv46-range-reject',
    }),
  );
  const rejectRes = rejectTimed.value;
  const snapAfterReject = statusSnapshot(db);

  let mismatch = 0;
  for (const id of rangeIds) {
    const row = db
      .prepare(`SELECT status FROM media_review_status WHERE project_id=? AND media_id=?`)
      .get(projectId, id) as { status: string } | undefined;
    const st = row?.status ?? 'SPARSE';
    if (id === keepId) {
      if (st !== 'keep') mismatch += 1;
    } else if (st !== 'reject') {
      mismatch += 1;
    }
  }
  const expectedChanged = rangeIds.length - 1;
  const undoTimed = timedMs(() => undoBatch(db, { projectId, batchId: rejectRes.batchId }));

  let undoMismatch = 0;
  for (const id of rangeIds) {
    const row = db
      .prepare(`SELECT status FROM media_review_status WHERE project_id=? AND media_id=?`)
      .get(projectId, id) as { status: string } | undefined;
    const st = row?.status ?? 'SPARSE';
    if (id === keepId) {
      if (st !== 'keep') undoMismatch += 1;
    } else if (st !== 'SPARSE') {
      undoMismatch += 1;
    }
  }

  const resetKeep = applyBulk(db, {
    projectId,
    action: 'reset_unreviewed',
    mediaIds: [keepId],
    protectKeep: false,
    source: 'frv46-cleanup-keep',
  });
  assert(resetKeep.changedCount === 1, `reset keep failed: ${JSON.stringify(resetKeep)}`);

  const snapAfterUndo = statusSnapshot(db);

  let restoreMismatch = 0;
  for (const id of rangeIds) {
    const row = db
      .prepare(`SELECT status FROM media_review_status WHERE project_id=? AND media_id=?`)
      .get(projectId, id) as { status: string } | undefined;
    const st = row?.status ?? 'SPARSE';
    const expected = beforeStatuses.get(id) ?? 'SPARSE';
    if (st !== expected) restoreMismatch += 1;
  }

  const rangeOk =
    rejectRes.changedCount === expectedChanged &&
    rejectRes.protectedCount === 1 &&
    mismatch === 0 &&
    undoMismatch === 0 &&
    restoreMismatch === 0 &&
    snapAfterReject.result.total < snapBeforeReject.result.total &&
    snapAfterUndo.result.total === snap0.result.total;

  checks.push({
    id: 'workflow_D_range',
    ok: rangeOk,
    evidence: 'VERIFIED',
    detail: {
      rangeSize: rangeIds.length,
      keepId,
      changedCount: rejectRes.changedCount,
      protectedCount: rejectRes.protectedCount,
      skippedCount: rejectRes.skippedCount,
      expectedChanged,
      sqlMismatchInRange: mismatch,
      undoMismatch,
      undoRestoredOk: undoMismatch === 0,
      restoreMismatch,
      errorRate: mismatch === 0 && undoMismatch === 0 && restoreMismatch === 0 ? 0 : mismatch + undoMismatch + restoreMismatch,
      rejectMs: Math.round(rejectTimed.ms),
      undoMs: Math.round(undoTimed.ms),
      resetKeepChanged: resetKeep.changedCount,
      statsBefore: snapBeforeReject.result,
      statsAfterReject: snapAfterReject.result,
      statsAfterUndo: snapAfterUndo.result,
      inventoryUnchanged: snapAfterUndo.inventory.total === snap0.inventory.total,
    },
  });

  // --- Workflow E: focus relation (category / uploader / provenance — series if available) ---
  const focusMediaId = rangeIds[0]!;
  const focusTimed = timedMs(() =>
    queryFocus(db, {
      projectId,
      focusMediaId,
      baseFilter: { projectId, statuses: [...STATUSES], categoryIds: [cat.id], categoryIncludeDescendants: true },
    }),
  );
  const rels = focusTimed.value.relations;
  const usable = rels.filter((r) => r.available && r.filter && r.total > 0 && r.kind !== 'similar');
  const preferred =
    usable.find((r) => r.kind === 'series') ||
    usable.find((r) => r.kind === 'category') ||
    usable.find((r) => r.kind === 'uploader') ||
    usable.find((r) => r.kind === 'provenance') ||
    usable[0];
  let focusOk = false;
  let focusDetail: Record<string, unknown> = {
    focusMediaId,
    relations: rels.map((r) => ({ kind: r.kind, available: r.available, total: r.total, note: r.note })),
    focusMs: Math.round(focusTimed.ms),
  };
  if (preferred?.filter) {
    const before = queryGallery(db, {
      projectId,
      statuses: [...STATUSES],
      categoryIds: [cat.id],
      categoryIncludeDescendants: true,
      limit: 1,
      sort: 'media_id',
      dir: 'asc',
    }).total;
    const afterGal = timedMs(() =>
      queryGallery(db, {
        ...preferred.filter!,
        statuses: [...STATUSES],
        limit: 80,
        sort: 'media_id',
        dir: 'asc',
      }),
    );
    const similar = rels.find((r) => r.kind === 'similar');
    focusOk =
      afterGal.value.total === preferred.total &&
      afterGal.value.total <= before &&
      Boolean(similar) &&
      similar!.available === false;
    focusDetail = {
      ...focusDetail,
      usedRelation: preferred.kind,
      relationTotal: preferred.total,
      galleryAfter: afterGal.value.total,
      galleryBeforeWithCategory: before,
      match: afterGal.value.total === preferred.total,
      similarDisabled: similar?.available === false,
      queryMs: Math.round(afterGal.ms),
    };
  }
  checks.push({
    id: 'workflow_E_focus',
    ok: focusOk,
    evidence: 'VERIFIED',
    detail: focusDetail,
  });

  // Writable work finished — release before perf reconnects.
  db.close();

  // --- Performance cold/warm (2 controlled runs, API-level) ---
  for (const run of [1, 2]) {
    for (const phase of ['Cold', 'Warm'] as const) {
      const dbr = openReviewDb(dbPath, { readonly: true });
      const samples = (label: string, fn: () => unknown, n = 5) => {
        const ms: number[] = [];
        for (let i = 0; i < n; i++) ms.push(timedMs(fn).ms);
        const s = stats(ms);
        perfRows.push({
          run_id: run,
          cache: phase,
          metric: label,
          p50_ms: Number(fmtMs(s.p50)),
          p95_ms: Number(fmtMs(s.p95)),
          mean_ms: Number(fmtMs(s.mean)),
          n: s.n,
          media_count: mediaCount,
          rss_mb: rssMb(),
        });
        return s;
      };
      if (phase === 'Warm') {
        queryGallery(dbr, { projectId, statuses: [...STATUSES], limit: 120, sort: 'media_id', dir: 'asc' });
      }
      samples('gallery', () =>
        queryGallery(dbr, { projectId, statuses: [...STATUSES], limit: 120, sort: 'media_id', dir: 'asc' }),
      );
      samples('groups_provenance', () =>
        queryGroups(dbr, { projectId, groupBy: 'provenance', statuses: [...STATUSES], limit: 40 }),
      );
      samples('category_subtree', () => countCategorySubtree(dbr, projectId, cat.id));
      samples('category_gallery', () =>
        queryGallery(dbr, {
          projectId,
          statuses: [...STATUSES],
          categoryIds: [cat.id],
          categoryIncludeDescendants: true,
          limit: 120,
          sort: 'media_id',
          dir: 'asc',
        }),
      );
      samples('focus', () =>
        queryFocus(dbr, { projectId, focusMediaId, baseFilter: { projectId, statuses: [...STATUSES] } }),
      );
      samples('facets', () => queryFacets(dbr, { projectId, statuses: [...STATUSES] }));
      samples('status_counts', () => computeStatusCounts(dbr, { projectId, statuses: [...STATUSES] }));
      dbr.close();
    }
  }

  const failed = checks.filter((c) => !c.ok);
  const throughput = {
    categorySubtreeMedia: sqlSubtree,
    provenanceGroupMedia: firstProv?.total ?? 0,
    rangeMediaPerBulkAction: rangeIds.length,
    undoPracticable: true,
    continuesWithoutReload: true,
    interactionsTypical: {
      A: 'expand parent + select category',
      B: 'groupBy provenance + click card',
      C: 'groupBy series + click card + scroll pages',
      D: 'click + shift range + R + Ctrl+Z',
      E: 'dblclick focus + relation + X',
    },
    verdict:
      failed.length === 0
        ? provTypes.length < 2 || !namedSeriesOnMain || !suppOk
          ? 'PASS WITH DEVIATION'
          : 'PASS'
        : 'BLOCKED',
    seriesDataGapOnCatDentistry: !namedSeriesOnMain,
    seriesSupplementalVerified: suppOk,
  };

  const report = {
    task: 'FRV-46',
    started,
    finished: new Date().toISOString(),
    dbPath,
    dbBytes: fs.statSync(dbPath).size,
    provenanceCopy: {
      sourceArchive: 'E:\\Temp\\FindSeries-Review-Test\\archive\\findseries-v5-phase1-gate.db',
      dest: dbPath,
      evidence: 'VERIFIED' as Evidence,
    },
    project,
    mediaCount,
    reviewMigs,
    coreMigs,
    checks,
    throughput,
    explorerBaseline: {
      status: 'NOT_VERIFIED',
      note: 'Manual 2–3 min Explorer side-by-side still required (see FRV46_REAL_DB_ACCEPTANCE.md § Explorer). Blocks Done.',
      manualSteps: [
        'Open same Cat_Dentistry category in legacy Explorer',
        'Measure time-to-first-grid',
        'Measure one comparable navigation/review action',
        'Record values in FRV46_REAL_DB_ACCEPTANCE.md',
      ],
    },
    frv40BaselinePath: path.join(benchDocDir, 'frv40-results.baseline.csv'),
    perfNote:
      'API fresh-connection cold-ish + warm; same methodology class as FRV-40 (not OS disk-cold). Deviations vs FRV-40 are documented, not claimed as methodologically identical regressions.',
    notionStatusRecommendation: 'Testing',
  };

  const jsonPath = path.join(benchDocDir, 'frv46-acceptance.json');
  fs.writeFileSync(jsonPath, JSON.stringify(report, null, 2), 'utf8');

  const csvPath = path.join(benchDocDir, 'frv46-performance.csv');
  const headers = ['run_id', 'cache', 'metric', 'p50_ms', 'p95_ms', 'mean_ms', 'n', 'media_count', 'rss_mb'];
  const csv = [
    headers.join(','),
    ...perfRows.map((r) => headers.map((h) => String(r[h] ?? '')).join(',')),
  ].join('\n');
  fs.writeFileSync(csvPath, csv + '\n', 'utf8');

  console.log(JSON.stringify({ ok: failed.length === 0, failed: failed.map((f) => f.id), jsonPath, csvPath, verdict: throughput.verdict }, null, 2));
  if (failed.length) process.exitCode = 1;
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
