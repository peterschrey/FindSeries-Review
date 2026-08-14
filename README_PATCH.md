# HF66-Kurzüberblick

HF66 korrigiert zwei beim HF65-Rollout sichtbare Resume-Probleme: Der Selbsttest erwartet jetzt das seit HF65 bewusst durchsatzsensitive AutoTune statt der veralteten HF60-Aussage, Durchsatzwerte dienten nur der Anzeige. Außerdem blockiert ein bereits erreichtes historisches Category-/Media-Limit im Modus `Resume` nicht mehr die gesamte Pipeline. Die betroffene Discovery-Stufe wird übersprungen; Metadata/Neighbor/Download dürfen mit dem vorhandenen Bestand weiterlaufen.

Die HF65-Downloadoptimierungen (partielle Claim-Indizes, Claim-Batch, Prefetch, Completion-Batch, Claim-Spin-Schutz und throughput-aware AutoTune) bleiben unverändert enthalten.

HF65 beschleunigt die Download-Stufe dort, wo der aktuelle Produktionslauf Zeit verliert: beim SQLite-Claim und bei wiederholten Claim-Konflikten. Pending- und Retry-Aufgaben erhalten getrennte partielle Indizes, Downloads werden blockweise pro Write-Lock reserviert (Profilstandard 4, `Cat_Dentistry` 8) und der Claim liefert die benötigten Media-/Download-Felder direkt mit. Dadurch entfällt der bisherige zweite SQLite-Lookup pro Datei. Zusätzlich werden Ergebnis-Updates in 4er-Batches committed; dadurch sinkt auch die Zahl der `BEGIN IMMEDIATE`-Finalisierungen deutlich.

Zusätzlich verhindert ein Circuit-Breaker den beobachteten Endlos-Spin eines nicht wiederverwendbaren terminalen Downloadzustands. Solche Konflikte werden einmal repariert, ohne den Task-Attempt- oder Worker-Zähler hochzuzählen.

AutoTune ist in HF65 durchsatzsensitiv: Nach einem Baseline-Fenster wird der Downloadabstand nur weiter reduziert, wenn der Dateidurchsatz messbar steigt. Standard-Floor bei normalen Produktionsdelays ist 1000 ms; konfigurierbar über `Download.AutoTuneMinDelayMs`. `Download.AutoTuneMinImprovementPct` steuert die nötige Verbesserung (Standard 2 %).

Für einen optionalen Hardware-Test liegt `New-FindSeriesLocalWorkspace.ps1` bei. Es kopiert nur die SQLite-DB in einen lokalen Workspace und bindet `Media` (und vorhandenes `Review`) per NTFS-Junction aus dem bisherigen externen Workspace ein.