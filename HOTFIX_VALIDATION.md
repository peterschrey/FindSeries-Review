# HF66-Validierung

Zusätzlich zu HF65: korrigierter Throughput-AutoTune-Selbsttest und Resume-Kapazitätssemantik.

HF65 baut auf HF64 auf. Geprüft werden zusätzlich:

- partielle Claim-Indizes `ix_project_downloads_pending` und `ix_project_downloads_failed_retry`;
- Pending-/Retry-Claim ohne gemischten Statusscan;
- Claim-Batch 4 als Profilstandard und 8 für `Cat_Dentistry` statt 1;
- Media-/Download-Prefetch direkt aus dem Claim, wodurch der zweite Worker-Lookup entfällt;
- workerlokaler Ergebnis-Batch 4 inklusive Flush vor neuem Claimblock und beim Workerende;
- Claim-Konflikt-Circuit-Breaker mit Attempt-Rollback und Worker-Sentinel `__FS_RETRY__`;
- durchsatzsensitives AutoTune mit Floor und Mindestverbesserung;
- optionaler lokaler DB-Workspace bei weiter extern gespeichertem `Media`.

Der integrierte `Test-FindSeriesV5.ps1` muss auf Windows PowerShell 5.1 bzw. PowerShell 7 auf dem Zielsystem ausgeführt werden. Die Build-Umgebung selbst enthält keine Windows-PowerShell-Laufzeit.
