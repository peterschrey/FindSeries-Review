# FindSeries V5.0.14 Hotfix 66

HF66 korrigiert den HF65-Rollout: Der Selbsttest prüft nun die neue durchsatzsensitive AutoTune-Logik, und im Modus `Resume` blockieren bereits erreichte Discovery-Limits nicht mehr Metadata/Download des vorhandenen Bestands.

HF66 baut auf HF65 auf und korrigiert zwei Resume-Regressionspunkte. HF65 optimiert die Download-Queue für große Projekte mit SQLite und mehreren Download-Workern.

Kernänderungen: separate partielle Pending-/Retry-Indizes, Claim-Batches von standardmäßig vier Tasks, Media-Prefetch im Claim, Schutz vor terminalen Claim-Spins und ein durchsatzsensitives AutoTune mit konfigurierbarem Mindestabstand.

Alle HF64-Category-, HF63-Monitor-, HF62-Lease-/Identity- und vorherigen Fixes bleiben enthalten.
