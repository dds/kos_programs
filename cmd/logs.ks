// ============================================================
// logs.ks  —  Archive flight log to KSC  (0:/cmd/logs.ks)
// Usage: RUNPATH("1:/cmd/logs.ks").
// ============================================================

IF NOT HOMECONNECTION:ISCONNECTED {
    PRINT "  No KSC link — cannot archive.".
} ELSE {
    IF NOT EXISTS("0:/logs") { CREATEDIR("0:/logs"). }
    LOCAL logPath IS flightLogPath().
    IF logPath = "" OR NOT EXISTS(logPath) {
        PRINT "  No flight log found.".
    } ELSE {
        LOCAL archivePath IS "0:/logs/" + logPath:REPLACE("1:/logs/","").
        COPYPATH(logPath, archivePath).
        PRINT "  Log archived to " + archivePath.
    }
}
