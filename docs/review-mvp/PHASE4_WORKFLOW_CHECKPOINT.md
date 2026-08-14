# Phase-4 Checkpoint (Cleanup A–E + FRV-22 … FRV-26)

**Stand:** 2026-08-14  
**Branch:** `review-mvp`  
**Basis:** `5b2aabd9eb66bb058528742ee314f59a8a09e0d0`  
**STOP vor FRV-27**

## 1. Phase-3 Cleanup

| Punkt | Status |
|---|---|
| A Controlled Search | Done — Draft + Debounce 250ms + filterEpoch cancel |
| B Request Keys | Done — Gallery≠groupBy; Groups≠sort/dir; Facets global |
| C Status-Overview | Done — Inventory getrennt; Result sum==total |
| D Global AND Drilldown | Done — alsoCategoryIds / alsoSourceTypes |
| E Browser Smoke | Done — 1920/2560 Screenshots + Virtualizer 100k Test |

## 2. FRV-22–26

| Task | Status |
|---|---|
| FRV-22 Selection Click/Ctrl/Shift | Done |
| FRV-23 Keyboard K/R/U/N + Bulk | Done |
| FRV-24 Keep-Schutz UI | Done (protectKeep=true, Banner counts) |
| FRV-25 Undo + Auto-Advance | Done (kein unsicheres Redo) |
| FRV-26 Projects + Persistence | Done |

## 3–8. Kurz

Siehe Report nach Push.

## 9. Redo

Redo bewusst **nicht** implementiert: Batch-Undo ist history-id-basiert; sicheres Redo ohne neue Semantik nicht exakt abbildbar.

## 10. SHA

nach Push
