// ============================================================
// logs.ks  —  Archive flight log to KSC  (0:/cmd/logs.ks)
// Usage: RUNPATH("0:/cmd/logs.ks").
// ============================================================

IF NOT HOMECONNECTION:ISCONNECTED {
    PRINT "  No KSC link — cannot archive.".
} ELSE {
    IF archiveLog() {
        PRINT "  Log archived and local spool rotated.".
    } ELSE {
        PRINT "  No flight log archived.".
    }
}
