# Hotfix 66

- Selbsttest an HF65+ Throughput-AutoTune angepasst; der alte HF60-Marker `Durchsatzwerte dienen nur der Anzeige` ist nicht mehr erforderlich.
- `Resume` bricht bei bereits erreichtem `Category.MaxCategories`/`Category.MaxFiles` nicht mehr die gesamte Pipeline ab. Discovery wird bei erreichtem Limit übersprungen, nachgelagerte Stufen laufen weiter.
- Limit-bedingt übersprungene Discovery-Tasks werden nur reaktiviert, wenn für die jeweilige Discovery-Stufe wieder Kapazität vorhanden ist.
- Alle HF65 Download-Performance-Fixes unverändert enthalten.

# Hotfix 65

- Beschleunigt Download-Claims mit zwei partiellen Indizes für Pending- und Retry-Aufgaben (`ix_project_downloads_pending`, `ix_project_downloads_failed_retry`).
- Reserviert Downloadtasks blockweise pro SQLite-Write-Lock (Profilstandard `Download.ClaimBatchSize=4`; `Cat_Dentistry` produktiv 8) und reduziert damit Claim-Transaktionen/Prozessstarts gegenüber Batch 1 um 75 % bzw. 87,5 %.
- Liefert Media-/Download-Felder direkt aus dem Claim an den Worker; der bisherige zusätzliche SQLite-Lookup pro Datei entfällt.
- Bündelt Download-Ergebnisse workerlokal (`Download.CompletionBatchSize=4`): bis zu vier globale/Projekt-Statusabschlüsse teilen sich eine `BEGIN IMMEDIATE`-Transaktion. Unterfüllte Batches werden vor dem nächsten Claimblock und beim Workerende geflusht.
- Behebt den beobachteten Claim-Spin: nicht wiederverwendbare terminale globale Downloadzustände werden einmal auf `pending` repariert; Konfliktretries zählen weder als Attempt noch als verarbeitete Worker-Aufgabe.
- AutoTune ist nun durchsatzsensitiv. Nach dem Baseline-Fenster wird nur weiter reduziert, wenn `files/s` mindestens um `Download.AutoTuneMinImprovementPct` (Standard 2 %) steigt. Standard-Floor bei Produktionsdelays: 1000 ms (`Download.AutoTuneMinDelayMs`).
- Ergänzt `New-FindSeriesLocalWorkspace.ps1`, um die SQLite-DB auf eine lokale SSD/NVMe zu legen, während `Media` auf der bisherigen externen SSD bleibt.
- HF64 Category-Bulk/DriftGuard, HF63 Monitor und HF62 Download-Lease-/Identity-Fixes bleiben enthalten.

# Hotfix 64

- Category-Ergebnisse werden pro API-Seite set-basiert in einer Transaktion geschrieben statt über tausende Einzelstatements.
- Bereits eingereihte Pending-Kategorien können bei `Category.DriftGuard=Strict` beim Resume gegen `Category.ExcludeRegex` bereinigt und als `skipped` markiert werden.
- Category-Performance-Telemetrie ergänzt (`gate_ms`, `http_parse_ms`, `transform_ms`, `sql_build_ms`, `bulk_sqlite_ms`, `task_complete_ms`, `total_ms`).
- `Cat_Dentistry`: `Category.Workers=4`, Strict-DriftGuard und gezieltes Ausschlussmuster gegen offensichtlich abgedriftete Personen-/Smiling-/Jahreszweige.
- HF63-Monitor- und HF62-Download-/Neighbor-Fixes bleiben unverändert enthalten.

# Hotfix 63

- Korrigiert den HF62-Selbsttest-Gate: Der Test prüfte noch sechs veraltete HF60-Monitor-Marker (u. a. `.timeout 4000` und alte Scatter-Titel), obwohl HF62 bereits den neuen Monitor mit 10-s-SQLite-Busy-Timeout, 20-s-Ausführungsbudget und den gewünschten `MB/s vs.`-Charts integriert hatte.
- Der Selbsttest prüft jetzt die tatsächlich ausgelieferte HF63-Monitorarchitektur und startet weiterhin zusätzlich den echten Monitor-`-SelfTest` in einem separaten STA-PowerShell-Prozess.
- Produktivlogik aus HF62 bleibt unverändert: seltene Download-Lease-Heartbeats, SHA1-Identitätsreparatur, kleine adaptive Neighbor-Schreibchunks und automatischer HF61c/HF63-Monitor.

# Hotfix 62

- Behebt das Download-Writer-Thrashing bei großen/lang laufenden Dateien: Download-Leases gelten vier Stunden und werden nicht mehr alle 60 Sekunden von jedem Worker erneuert. Der Heartbeat greift erst nach der halben Lease-Dauer.
- Ergänzt partielle Indizes für die seltene Lease-Erneuerung (`ix_downloads_owner_worker_lease`, `ix_project_downloads_worker_lease`).
- Repariert explizite Inkonsistenzen zwischen `media.sha1` und `downloads.verified_sha1` vor der Download-Queue. Solche terminalen globalen Downloads werden einmal auf `pending` zurückgesetzt statt tausendfach zwischen `pending` und `running` zu rotieren.
- Korrigiert auch den Worker-seitigen SHA1-Reuse: Lookup erfolgt wie im Bulk-Fast-Path über `downloads.verified_sha1`.
- Neighbor-Bulk-Schreibungen starten mit 10 statt 100 Treffern pro SQLite-Transaktion und halbieren bei Timeout bis auf eine Zeile.
- Integriert den HF61c-Monitor als Standardmonitor: 9 Charts, Downloads-MB/s und System-Netzwerk über Zeit, vier Scatterplots mit Verbindungslinien, sauberes Schließen ohne `PipelineStoppedException`.
- Monitor-Read-only-Abfragen erhalten 20 Sekunden Budget; der automatische GUI-Start wartet bis zu 20 Sekunden auf die Sichtbarkeitsbestätigung.
- `Get-FindSeriesStatus.ps1` zeigt bei `Download.AutoTune=false` keinen fiktiven nächsten Delay-Schritt mehr an.
- Enthält HF60 und alle vorherigen Korrekturen vollständig.

# Hotfix 60

- Behebt den HF59-Selbsttestabbruch `UNIQUE constraint failed: media.sha1`: Der Regressionstest erzeugte zwei Medien mit derselben 40-stelligen SHA1, obwohl das produktive Schema diese Identität eindeutig hält.
- SHA1-Bulk-Reuse sucht jetzt schema-kompatibel nach einem abgeschlossenen `downloads.verified_sha1` statt nach einem zweiten `media.sha1`-Datensatz.
- Neuer partieller Index `ix_downloads_verified_sha1` beschleunigt diesen Lookup.
- Laufzeitregression prüft direkten Reuse, SHA1-Reuse und einen echten Pending-Fall unter aktivem Unique-Index.
- Enthält HF59-User-Agent-Korrektur sowie HF57/HF58 Bulk-Reuse, SQLITE_IOERR-Robustheit und alle vier Monitor-Scatterplots vollständig.

# Hotfix 58

- Korrigiert einen False-Positive im HF57-Selbsttest: Der Monitor trennte die Messfenster technisch bereits, verwendete aber die Anzeige `Letztes Fenster` statt `Letztes vollständiges Fenster`.
- Der Monitor benennt das letzte abgeschlossene AutoTune-Fenster nun explizit und der Regressionstest prüft zusätzlich die zugrunde liegenden `LastWindow*`-Felder.
- Sämtliche HF57-Funktionen bleiben enthalten: Bulk-Reuse-Fast-Path, SQLITE_IOERR-Retry/Entkopplung des Ereignislogs sowie alle vier Scatterplots plus `reused/s`.

# Changelog

## 5.0.14-hotfix57

- Neuer Download-Reuse-Fast-Path: exakte globale Treffer und SHA1-Dubletten werden vor der Worker-Queue in Batches auf `reused` gesetzt.
- `Download.ReuseBatchSize` ergänzt; Standard 5.000.
- `disk I/O error (10)` / `SQLITE_IOERR` wird als Infrastrukturfehler mit bis zu drei Retries und Backoff behandelt.
- Download-Claim, atomarer Abschluss und Worker-Cleanup erhalten 60 Sekunden SQLite-Ausführungsbudget.
- Temporäre Fehler beim Schreiben des Ereignisprotokolls beenden den Hauptlauf nicht mehr.
- Monitor zeigt `reused/s` sowie neue Scatterplots Aufgaben/s→MB/s und Downloads/s→MB/s.
- Die bisherigen Delay→Downloads/s- und Delay→MB/s-Scatterplots bleiben erhalten.
- Enthält HF55 und alle vorherigen Korrekturen vollständig.

## 5.0.14-hotfix55

- Korrigiert einen falschen Negativbefund im HF54-Selbsttest: Der Test erkannte den Text `ORDER BY pd.rowid` in einem SQL-Kommentar als produktiven Legacy-Pfad, obwohl der tatsächliche Claim bereits `INDEXED BY ix_project_downloads_queue` und `ORDER BY pd.status,pd.media_id` verwendete.
- Der Regressionstest bewertet jetzt nur ausführbare SQL-Zeilen und ignoriert Kommentarzeilen.
- Produktiver Download-Queue-Pfad und Performance-Einstellungen bleiben gegenüber HF54 unverändert.

## 5.0.14-hotfix55
- Download-Claim nutzt jetzt `ix_project_downloads_queue` direkt.
- `ORDER BY pd.rowid` im Download-Claim entfernt; keine per-Claim TEMP-B-Tree-Sortierung des Restbestands mehr.
- Worker-Cleanup kann auf die aktive Stufe begrenzt werden; Downloadfehler räumen nur Download-Leases auf.
- Orchestrator überspringt `download_tuning`-Polling vollständig, wenn `Download.AutoTune=false`.
- HF53 Neighbor-Seed-Join-Fix unverändert enthalten.

# FindSeries 5.0.14-hotfix53

## Hotfix 53

- behebt den 60-Sekunden-Timeout in `Seed-FsNeighborTasks`;
- erzwingt den TEMP-Seed-Batch mit `CROSS JOIN` als äußere SQLite-Join-Schleife;
- verhindert dadurch einen vom Planner gewählten Vollscan von `media` je Seed-Batch;
- ergänzt einen Selbsttest gegen die frühere `JOIN media m ON ...`-Form;
- Download-Limitierung bleibt unverändert bei 1.370 ms globalem Startabstand, vier Workern und deaktiviertem AutoTune.

- Behebt den nach HF51 sichtbar gewordenen SQLite-Timeout beim Metadaten-Seeding (`Metadaten-Aufgaben schreiben | ... 444 offene Medien`).
- Der Ausnahme-/Resume-Pfad scannt nicht mehr den vollständigen `project_media`-Bestand mit einem zufälligen Join auf `media`, sondern ermittelt zuerst ausschließlich das indexierte Task-Abdeckungsdelta.
- Ergänzt benannte Covering-Indizes `ix_project_media_media_scan` und `ix_metadata_tasks_media_cover`, damit der Delta-Anti-Join auch auf lang laufenden Workspaces einen deterministischen Indexpfad verwendet.
- Kleine Reparaturdeltas werden in höchstens 100er-Schreibchunks verarbeitet. Überschreitet ein Chunk dennoch 60 Sekunden, wird er halbiert und mit denselben IDs erneut versucht, bis hinunter zu einer einzelnen Zeile.
- Große Erst-Seeds behalten 500er-Schreibchunks; die Optimierung reduziert also nicht unnötig den Durchsatz bei neuen Projekten.
- Der Selbsttest enthält eine Produktionsregression mit 58.000 Projektmedien und exakt 444 fehlenden Metadaten-Tasks und verlangt, dass nur diese 444 Delta-Zeilen geprüft und wieder angelegt werden.
- Enthält HF51 vollständig: Resume verarbeitet vorhandene Medienidentitätskonflikte ausschließlich über die Konfliktqueue und führt keinen redundanten Vollabgleich aus.
- Downloadsteuerung bleibt unverändert bei standardmäßig vier Workern, 1.370 ms globalem Downloadabstand, deaktiviertem AutoTune und `mailto:pschrey@gmail.com`.

# FindSeries 5.0.14-hotfix51

- Behebt den Resume-Abbruch bei offenen Medienidentitätskonflikten: Der normale Start verarbeitet nach Schema-Migration V2 ausschließlich die persistente Konfliktqueue und führt keinen redundanten Vollabgleich aller Medien mehr aus.
- Entfernt den vollständigen Identitätsabgleich nach jeder einzelnen Zusammenführung; `Merge-FsMediaRows` übernimmt Identitäten bereits atomar auf den überlebenden Datensatz.
- Der weiterhin benötigte einmalige Vollabgleich während einer erstmaligen Schema-Migration arbeitet in begrenzten Blöcken von 5.000 Medien statt in einem einzigen potenziell länger als 180 Sekunden laufenden SQLite-Aufruf.
- Ergänzt einen ausführbaren Queue-Only-Selbsttest und statische Regressionstests gegen die erneute Einführung des Vollscans im Resume-Pfad.
- Der integrierte Updater verwendet standardmäßig den gemessenen globalen Downloadabstand von 1.370 ms, vier Download-Worker und deaktiviertes Download-AutoTune.
- Downloadlogik, 429-Behandlung und die HF50-Reuse-Korrektur bleiben ansonsten unverändert.

# FindSeries 5.0.14-hotfix50

- Behebt den produktiven StrictMode-Abbruch `Die Eigenschaft "bytes" wurde für dieses Objekt nicht gefunden`.
- `downloads.bytes` wird im Medien-Join nun ausdrücklich als `download_bytes` ausgewählt und vor der Wiederverwendung defensiv gelesen; `media` besitzt selbst keine `bytes`-Spalte.
- Das Download-Timing wird unabhängig vom konkreten Pipelineobjekt in ein fest geformtes Objekt mit `GateMs`, `HttpMs`, `DelayMs`, `Attempts` und `Bytes` normalisiert.
- Der Selbsttest führt zusätzlich den echten `Invoke-FsDownloadWorkerItem`-Reuse-Pfad mit einem bereits abgeschlossenen Download und gespeichertem Bytewert aus.
- Frühere HF47-HF49-Fehler mit fehlendem `GateMs` oder `bytes` werden gezielt reaktiviert; echte HTTP-404/410-Fehler bleiben final.
- Downloadsteuerung, 429-Regelung, Charts und Performance-Telemetrie bleiben gegenüber HF49 unverändert.

# FindSeries 5.0.14-hotfix48

- Behebt die HF47-Workerregression der neuen Detailmessung: Das Download-Timingobjekt wird nun aus der vollständigen PowerShell-Success-Pipeline eindeutig anhand der Eigenschaften `GateMs`, `HttpMs`, `DelayMs`, `Attempts` und `Bytes` ausgewählt.
- Unterdrückt unbeabsichtigte Ausgaben des Heartbeat-Callbacks und der Performance-Protokollierung im Download-Retry-Pfad.
- Ergänzt einen echten lokalen Download-Selbsttest mit absichtlich „lautem“ Heartbeat. Der Resume-Lauf startet nur, wenn genau ein vollständiges Timingobjekt zurückkommt.
- Reaktiviert beim Update gezielt ausschließlich die durch den HF47-`GateMs`-Fehler final fehlgeschlagenen Downloadtasks; echte HTTP-404- und sonstige Fehler bleiben unverändert.
- Behebt die zentrale HF45/HF46-Performance-Regression: Eine nach HTTP 429 aktivierte 15-Sekunden-Staffelung blieb dauerhaft bestehen. Vier Worker konnten dadurch zusammen nur ungefähr vier Dateien pro Minute starten.
- Die Dateigate speichert nun eine endliche Zahl von Recovery-Slots. Nach vier einmalig im Abstand von 3 Sekunden gestarteten Requests kehrt sie automatisch zum normalen Delay zurück.
- Der initiale Prozessstart bleibt unverändert bei 0/15/30/45 Sekunden.
- Verkürzt die Burst-Erholung auf 8 erfolgreiche Dateien und 20 Sekunden ohne neue 429. Die gemeinsame Pause beträgt 20 Sekunden, sofern `Retry-After` nichts Längeres verlangt.
- Erweitert die Monitorhistorie auf bis zu 1.000 Punkte. Scatter-Plots zeigen vollständige Fenster, Recovery-Punkte und periodische Live-Punkte auch bei identischem Delay.
- Korrigiert den Marker-Jitter am Delay 0, sodass gespiegelte Marker nicht mehr paarweise übereinanderliegen. Die chronologischen Linien bleiben auf den echten Messkoordinaten.
- Ergänzt `download_item`-Profiling für Claim, Lookup, Vorbereitung, Gate, HTTP, Move, SHA1, DB-Abschluss und sonstigen Overhead.
- Ergänzt das parameterlose `Analyze-FindSeriesPerformance.ps1` einschließlich Auswertung headerloser Alt-CSV-Dateien und Ressourcen-Schnappschuss.
- Der Updater entfernt vor dem Start einen alten Gate-Zustand, verlangt ausdrücklich mindestens HF50 und führt den produktiven Selbsttest aus.

# FindSeries 5.0.14-hotfix44

- Ersetzt die sprunghafte 400→800→1600-ms-Eskalation durch eine gemäßigte Erhöhung je echtem 429-Burst: ca. 25 %, mindestens 20 ms, höchstens 100 ms.
- Ein Burst bleibt bis mindestens 20 erfolgreichen Dateien **nach der letzten 429-Antwort** und mindestens 60 Sekunden ohne weitere 429 geöffnet. Verspätete Antworten paralleler Worker erzeugen dadurch keinen künstlichen neuen Burst.
- Weitere 429 im offenen Burst erhöhen den Delay nicht, erneuern aber die gemeinsame Pause. Echte Folgebursts behalten die Pause von 60/120/240/300 Sekunden; `Retry-After` hat Vorrang.
- Nach zwei stabilen Schutzfenstern wird der Delay proportional um ca. 10 %, mindestens 20 ms und höchstens 100 ms reduziert. Hohe Fehlwerte werden so wesentlich schneller abgebaut als mit festen 20-ms-Schritten.
- Jeder neue Run beginnt beim konfigurierten Warm-up-Wert; ein überhöhter Delay eines abgebrochenen Vorgängerlaufs wird nicht übernommen.
- Scatter-Linien bleiben auf den exakten Messwerten; Marker werden rein visuell leicht versetzt und zeigen im Tooltip weiterhin die tatsächlichen Werte und die Messungsnummer.
- Ergänzt einen ausführbaren Test, der zwei Download-Worker gegeneinander claimen lässt und doppelte `media_id`-Vergaben sowie widersprüchliche Lease-Owner ausschließt.
- Enthält HF43 vollständig und wird weiterhin ausschließlich als selbstenthaltendes Drop-in-ZIP verteilt.

# FindSeries 5.0.14-hotfix43

- Behebt den Windows-PowerShell-Parserfehler in den 429-Statusmeldungen: Variablen direkt vor einem Doppelpunkt werden nun als `${burstNumber}:` geschrieben.
- Ergänzt einen statischen Regressionstest gegen ungeklammerte `$burstNumber:`-Vorkommen.
- Keine Änderung an 429-Logik, Downloadsteuerung, Workerlogik oder Monitorverhalten gegenüber HF42.

# FindSeries V5.0.14 Hotfix 43

## HF43 – 429-Recovery und laufbezogene Charts

- Sicherer Neustart: Der Download beginnt mindestens mit dem konfigurierten Startabstand; ein zuvor gelernter Wert von 0 ms wird nicht übernommen.
- 429-Antworten und 429-Bursts werden getrennt gezählt.
- Ein Burst bleibt bis zum ersten erfolgreichen Download geöffnet.
- Neuer Burst: Rückkehr auf mindestens 400 ms bei der üblichen CLI-Konfiguration; weitere Bursts eskalieren auf 800 bzw. 1600 ms.
- Gemeinsame Pause: 60, 120, 240 und anschließend maximal 300 Sekunden; ein längeres `Retry-After` hat Vorrang.
- Auch weitere 429 innerhalb eines offenen Bursts erneuern die gemeinsame Pause, ohne den Delay erneut zu erhöhen.
- Nach der Pause reservieren die Worker ihre Startzeit mit bis zu zwei Sekunden Jitter und dem globalen Anfrageabstand.
- Charts zeigen ausschließlich Messwerte des aktuellen Runs und starten daher bei jedem Neustart leer.
- Historische Messwerte bleiben in SQLite erhalten.
- User-Agent einschließlich `mailto:pschrey@gmail.com` bleibt aktiv.

- Behebt den HF40-Abbruch aller Download-Worker unter `Set-StrictMode`: die pro Prozess verwendete Claim-Queue wird beim Laden des Search-Moduls initialisiert und vor jeder Verwendung StrictMode-sicher geprüft.
- Ergänzt einen ausführbaren Selbsttest des echten Worker-Queue-Wrappers `Get-FsNextDownloadTask`, damit dieser Fehler künftig vor einem Resume erkannt wird.
- Startet den Monitor nicht mehr mit dem Windows-Startflag `SW_HIDE`, das auch das erste WinForms-Fenster unsichtbar halten kann.
- Der Monitor blendet stattdessen erst nach dem sichtbaren `Shown`-Ereignis ausschließlich sein Konsolenfenster aus.
- Hauptanwendung und Monitor verwenden einen Bereitschaftsmarker: FindSeries meldet den automatischen Start erst, wenn das GUI-Fenster sichtbar bestätigt wurde. Ein vorzeitig beendeter Prozess oder ein ausbleibender GUI-Start wird mit Monitorlog und PID gemeldet.
- Enthält alle SQLite-, Block-Claim-, 429- und Dark-Chart-Änderungen aus HF40 kumulativ.

# FindSeries V5 – Changelog

## 5.0.14-hotfix38

- Vereinfacht die Download-Anfragesteuerung: ohne HTTP 429 wird der Delay nach jedem vollständigen 100er-Fenster um 20 ms bis auf 0 ms reduziert; Dateien/s und MB/s bleiben reine Telemetrie.
- Erhöht den Delay ausschließlich beim ersten HTTP 429 eines neuen 30-Sekunden-Bursts um 20 ms.
- Ergänzt eine einmalige gemeinsame 30-Sekunden-Zwangspause je neuem 429-Burst; parallele 429 desselben Bursts schaukeln Delay und Pause nicht hoch. Längeres `Retry-After` bleibt verbindlich.
- Behebt leere WinForms-Charts unter Windows PowerShell 5.1 durch rekursives Entfalten von JSON-Arrays und explizite `DataPoint`-Objekte mit `double[]`-Y-Werten.
- Wiederholt read-only Monitorabfragen bei `database is locked` und hält währenddessen den letzten gültigen Snapshot.
- Ersetzt technische Autotune-Kürzel in Fortschrittsleiste und Monitor durch unmittelbar verständliche Angaben zu Gesamtfortschritt, diesem Lauf, Tempo, Restzeit und Anfrageabstand.
- Ergänzt einen ausführbaren Monitor-Chart-Selbsttest im integrierten Updateprozess.
- Verteilung weiterhin ausschließlich als Drop-in-ZIP mit integriertem Updater.

## 5.0.14-hotfix37

- Startet den grafischen Monitor als versteckten STA-Prozess und hält die SQLite-Zugriffe des Monitors strikt read-only.
- Baut die WinForms-Oberfläche vor der ersten Datenbankabfrage auf und protokolliert Start- und Lesefehler sichtbar.
- Enthält kumulativ die HF36-Korrektur des kandidatengesteuerten Download-Seeding-Fast-Paths.

## 5.0.14-hotfix36

- Behebt den falschen Download-Seeding-Fast-Path nach vollständig vorbereitetem Bestand.
- Die schnelle EXISTS-Prüfung verwendet jetzt exakt dieselben Kriterien wie das eigentliche Batch-Seeding: URL, Medientyp, globale Review-Sperre und vorhandene skipped-Tasks.
- Ein zweiter Seeding-Aufruf endet dadurch mit `FastPath=True`, `Scanned=0` und `Processed=0`, statt eine leere Batchtransaktion auszuführen.
- Enthält kumulativ die SQLite-kompatible zweistufige Metadatenmigration aus HF35.
- Verteilung weiterhin ausschließlich als Drop-in-ZIP mit integriertem Updater.

## 5.0.14-hotfix35

- Behebt den HF34-Selbsttestabbruch `near "DO": syntax error` im Metadaten-Seeding. Der mehrdeutige SQLite-Pfad `INSERT ... SELECT ... ON CONFLICT DO UPDATE` wurde durch eine transaktionale, zweistufige Aktualisierung ersetzt: vorhandene Tasks werden zuerst aktualisiert, fehlende Tasks anschließend mit `WHERE NOT EXISTS` eingefügt.
- Die Änderung ist idempotent, bleibt unter `BEGIN IMMEDIATE` race-sicher und liefert weiterhin die getrennten Zähler für Kandidaten sowie neu/aktualisierte Tasks.
- Der Selbsttest erkennt den fehlerhaften UPSERT-Pfad künftig statisch und führt den produktiven Fallback-Seedingpfad weiterhin ausführbar aus.
- Updateverteilung erfolgt ab HF35 ausschließlich über das Drop-in-ZIP. Das darin enthaltene `Update-And-Resume-FindSeries.ps1` wird direkt aus einem temporär entpackten Drop-in gestartet; eine separate Updater-Datei ist nicht mehr erforderlich.

## 5.0.14-hotfix34

- Ersetzt die nicht installierten HF32/HF33-Pakete kumulativ und stellt sicher, dass `FindSeries.Search.psm1` vollständig bleibt; Query-, Metadata-, Neighbor-, Autotune- und Download-Worker werden durch einen Regressionstest explizit geprüft.
- Trennt Autotune-Kennzahlen eindeutig: **aktuelles unvollständiges Fenster**, **letztes vollständiges 100er-Fenster** und **bestes vollständiges Fenster nach Dateien/s**. MB/s wird jeweils nur für dasselbe Fenster angezeigt.
- Die Entscheidung nennt nun ausdrücklich den Vergleich zum vorherigen vollständigen Fenster; der globale Bestwert wird nicht mehr als aktuelle Rate dargestellt.
- Scatter-Plots `Delay vs. Dateien/s` und `Delay vs. MB/s` verwenden ausschließlich vollständige Messfenster; Falschfarben zeigen weiterhin die zeitliche Reihenfolge.
- Enthält die Resume-Beschleunigung aus HF32/HF33: verifizierter Metadaten-Snapshot, Taskabdeckungs-Fast-Path und kandidatengesteuertes Download-Seeding statt wiederholter Vollscans.
- Enthält den automatischen Monitorstart aus `FindSeries.ps1`, die Monitor-Einzelinstanz, 10-s-Polling, 30-s-Verlaufspolling und vollständige Fehlerprotokollierung.
- Ergänzt die idempotente Telemetriemigration um Felder für das letzte vollständige Fenster und den Zeitpunkt der letzten Entscheidung.

## 5.0.14-hotfix33

- Nimmt das noch nicht installierte HF32 vollständig auf: schnelle Metadaten-Snapshots, kandidatengesteuertes Download-Seeding, automatischer Monitorstart und die beiden Falschfarben-Scatter-Plots.
- Der Monitor fragt den Workspace standardmäßig nur noch alle 10 Sekunden ab statt alle 2 Sekunden. Die Verlaufstabelle wird nur alle 30 Sekunden neu gelesen, passend zur Erzeugung der Live-Messpunkte.
- Ergänzt den Index `ix_project_downloads_updated` für die rollierende Monitor-Prognose.
- Zeitreihen verwenden explizite OLE-Automation-Zeitwerte und den numerischen Serienindex; fehlerhafte Einzelcharts blockieren nicht mehr die gesamte Monitoransicht.
- Monitorfehler werden vollständig in einem mehrzeiligen Textfeld angezeigt und zusätzlich nach `Diagnostics\download-monitor.log` geschrieben.
- Bei einem vorübergehenden SQLite-Lesefehler bleibt der letzte gültige Snapshot sichtbar.
- Die zentrale Autotune-Telemetrie wird alle 10 statt alle 5 Sekunden aggregiert. Die Downloadworker und das 100er-Messfenster bleiben unverändert; unnötige SQLite-Lesevorgänge werden halbiert.

## 5.0.14-hotfix32

- Resume-Start beschleunigt: vollständig bearbeitete Metadaten werden über einen verifizierten, projektbezogenen Snapshot beziehungsweise über die vorhandene Taskabdeckung erkannt. Der frühere Join über alle `project_media`-/`media`-Zeilen entfällt im Normalfall.
- Die zweite Metadatenstufe desselben Laufs verwendet den soeben erstellten Snapshot und scannt den Bestand nicht erneut, sofern die Nachbarsuche keine Projektmedien ergänzt hat.
- Download-Seeding ist kandidatengesteuert: Es liest nur noch `selected=1`, `download_requested=0` und `score >= Download.MinScore`. Ein abgeschlossenes Projekt überspringt den vollständigen Projektbestandsscan.
- Neue Indizes: `ix_metadata_tasks_level`, `ix_project_media_updated` und der partielle Index `ix_project_media_download_seed`.
- Der Download-Monitor wird bei direkten `FindSeries.ps1`-Aufrufen automatisch unmittelbar vor dem Download-Workerstart geöffnet. Mit `-NoMonitor` kann dies deaktiviert werden.
- Eine benannte Mutex-Sperre verhindert doppelte Monitorfenster.
- Monitor erweitert um zwei Scatter-Plots: Delay gegen Dateien/s sowie Delay gegen MB/s. Falschfarben kodieren die zeitliche Entwicklung von blau (früh) bis rot (spät).

## 5.0.14-hotfix31

- Behebt den Syntaxfehler der Monitor-Prognoseabfrage (`near ")": syntax error`).
- Berechnet Beginn und Dauer des rollierenden 10-Minuten-Fensters jetzt in PowerShell; SQLite zählt nur noch die seitdem abgeschlossenen Downloadobjekte.
- Die GUI-Charts für Delay, Dateien/s und MB/s werden dadurch wieder regelmäßig aktualisiert.
- Ergänzt einen statischen Regressionstest und eine ausführbare SQLite-Zeitfensterabfrage im Selbsttest.
- Produktive Download-, Worker- und Autotune-Logik bleiben gegenüber HF30 unverändert.


## 5.0.14-hotfix30

### Autotune-Zählung repariert

- Das Download-Autotune zählt erfolgreiche Downloads nicht mehr in jedem Worker einzeln.
- Der Orchestrator ermittelt das Messfenster zentral aus den bereits committed `project_downloads`-Zuständen.
- Damit steigt `Fenster x/100` zuverlässig mit den tatsächlich neu abgeschlossenen Downloads dieser Session.
- Telemetriefehler werden nicht mehr stumm verworfen, sondern höchstens einmal pro Minute als Warnung ausgegeben.
- Die HF29-Tabellen `download_tuning` und `download_tuning_samples` werden über eine explizite, idempotente Workspace-Migration angelegt beziehungsweise ergänzt.
- Pro 30 Sekunden wird ein Live-Messpunkt gespeichert; nach 100 erfolgreichen Downloads folgt ein vollständiger Vergleichspunkt und eine Änderung um 20 ms.
- Ein HTTP 429 erhöht den Basisdelay um 20 ms und setzt das laufende Messfenster zurück; `Retry-After` bleibt ein separater temporärer Cooldown.
- Es existiert weiterhin keine positive Mindestverzögerung: 0 ms ist zulässig.

### Strukturierte Fortschrittsanzeige

Die Downloadanzeige trennt jetzt klar:

- Gesamtfortschritt,
- in dieser Session bearbeitete Objekte,
- davon neu heruntergeladen, wiederverwendet, fehlgeschlagen und übersprungen,
- offene und aktive Aufgaben,
- rollierende Bearbeitungsrate,
- Restdauer und voraussichtliche lokale Fertigstellungszeit,
- aktuellen Autotune-Delay, Messfenster und gemessenen Durchsatz.

Die Prognose wird aus einem rollierenden Zehn-Minuten-Fenster tatsächlich neu terminaler Aufgaben berechnet. Historisch erledigte Dateien fließen nicht in die Sessionrate ein.

### Grafischer Downloadmonitor

`Show-FindSeriesDownloadMonitor.ps1` besitzt jetzt einen WinForms-Modus mit drei echten Liniendiagrammen:

1. Delay über die Zeit,
2. Dateien pro Sekunde,
3. Megabyte pro Sekunde.

Der Monitor läuft in einem separaten PowerShell-Prozess und liest ausschließlich SQLite-Telemetrie. Falls Windows Forms oder das Charting-Assembly nicht verfügbar sind, wird automatisch die ASCII-Konsolenansicht verwendet.

### Unverändert

- `Download.Workers` und `Download.DelayMs` werden unverändert aus Profil beziehungsweise CLI übernommen.
- Der Wikimedia-User-Agent enthält `mailto:pschrey@gmail.com`.
- Lokale Konfigurationen werden durch den Drop-in nicht überschrieben.

## 5.0.14-hotfix29

- Erstes Download-Autotune mit 20-ms-Schritten und separatem Monitor.
- Restdauer und Abschlussuhrzeit ergänzt.