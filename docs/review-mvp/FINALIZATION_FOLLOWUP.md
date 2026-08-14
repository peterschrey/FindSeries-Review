# Finalization P0 Follow-up (nicht Phase 3)

Vor produktiver physischer Finalisierung noch:

1. Review-Hardlinks/Copy-Pfade (`review_exports.review_path`) ebenfalls bereinigen.
2. Reconcile/Retry für Zustand: DB global rejected, Datei physisch noch vorhanden.
3. `REVIEW_DELETE_ROOTS` / `REVIEW_MEDIA_ROOTS` in Deployment verbindlich setzen.

Die Finalize-API bleibt in Phase-3-UI bewusst unintegriert.
