// ============================================================
// logs.ks  —  Archive flight log to KSC  (0:/cmd/logs.ks)
// Usage: RUNPATH("1:/cmd/logs.ks").
// ============================================================

IF NOT HOMECONNECTION:ISCONNECTED {
    PRINT "  No KSC link — cannot archive.".
} ELSE {
    IF NOT EXISTS("0:/logs") { CREATEDIR("0:/logs"). }
    IF flightLogPath = "" OR NOT EXISTS(flightLogPath) {
        PRINT "  No flight log found.".
    } ELSE {
        LOCAL archivePath IS "0:/logs/" + flightLogPath:REPLACE("1:/logs/","").
        COPYPATH(flightLogPath, archivePath).
        PRINT "  Log archived to " + archivePath.
    }
}
