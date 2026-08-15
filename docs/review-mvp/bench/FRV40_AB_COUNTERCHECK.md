# FRV-40 A/B Countercheck (controlled)

**Date:** 2026-08-15T18:38:42.868Z
**Shared DB:** `C:\Temp\FindSeries-Review-Test\findseries-v5-phase1-gate.db` (readonly; media=184991)
**A:** `C:\Users\pschr\cursor3-repos\FindSeries-Review-frv40-ab-a` @ Review-Base `d5013ba` (NOT proven historical CSV generator)
**B:** `C:\Users\pschr\cursor3-repos\FindSeries-Review` @ current HEAD
**Pairs:** 3 × alternating A→B · samples/phase=10 · total n/state=30

## Historical baseline provenance

| Item | Status |
|---|---|
| File | `docs/review-mvp/bench/frv40-results.baseline.csv` (immutable) |
| Introduced in Git | `c54ae4ba5b7989c874efb7777e60f9350f86ee9c` (2026-08-15 01:46 +0200) |
| Exact generation commit / DB copy / host | **NOT_VERIFIED** (file first appears in that commit; run provenance not recorded) |
| Era methodology (from code at c54ae4b) | same-process Cold→Warm suite (INFERRED from `bench-frv40.ts` at that commit) |

This A/B is a **code regression countercheck vs Review-Base**, not a reproduction of the historical CSV provenance.

## Results

| Metric | A p50 | A p95 | B p50 | B p95 | Δ B vs A |
|---|---:|---:|---:|---:|---:|
| gallery | 677.3 | 773.8 | 653.0 | 721.8 | -3.6% |
| category_subtree | 389.9 | 418.1 | 377.1 | 407.5 | -3.3% |
| category_gallery | 1718.9 | 1921.2 | 1624.4 | 1797.5 | -5.5% |
| focus | 1527.6 | 1866.8 | 1484.2 | 1652.3 | -2.8% |
| facets | 1728.7 | 1973.7 | 1724.1 | 1874.1 | -0.3% |
| status_counts | 5.6 | 6.0 | 5.4 | 6.0 | -2.7% |

## Classification

**VERIFIED_NO_CODE_REGRESSION**

HEAD within 20% of d5013ba on identical DB for all open metrics (VERIFIED). Historical CSV deltas are not a current code regression vs Review-Base.
