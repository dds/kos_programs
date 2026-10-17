// ============================================================
// diagnostic_log.ks - Shared archive-only diagnostic reports
// (0:/lib/diagnostic_log.ks)
// Commands load this directly; it is absent from flight-band dependencies.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION diagnosticArchiveOpen {
    PARAMETER prefix.
    LOCAL result IS LEXICON("READY", FALSE, "COMPLETE", FALSE, "PATH", "",
        "DIR", "0:/logs/archive/_diagnostics").
    IF NOT HOMECONNECTION:ISCONNECTED {
        PRINT "Diagnostic requires an archive link. Re-run when connected; no report recorded.".
        RETURN result.
    }
    FOR dir_ IN LIST("0:/logs", "0:/logs/archive", result["DIR"]) {
        IF NOT EXISTS(dir_) { CREATEDIR(dir_). }
    }
    SET result["PATH"] TO result["DIR"] + "/" + prefix + "_" + slug() + "_"
        + ROUND(TIME:SECONDS,0) + ".log".
    SET result["READY"] TO TRUE.
    SET result["COMPLETE"] TO TRUE.
    PRINT "Archive report: " + result["PATH"].
    RETURN result.
}

GLOBAL FUNCTION diagnosticArchiveLine {
    PARAMETER reportState.
    PARAMETER row.
    PRINT row.
    IF NOT reportState["READY"] { RETURN FALSE. }
    IF NOT HOMECONNECTION:ISCONNECTED {
        IF reportState["COMPLETE"] { PRINT "Archive link lost; snapshot incomplete. Re-run when connected.". }
        SET reportState["COMPLETE"] TO FALSE.
        RETURN FALSE.
    }
    LOCAL dest IS reportState["PATH"].
    LOG row TO dest.
    RETURN TRUE.
}

GLOBAL FUNCTION diagnosticArchiveClose {
    PARAMETER reportState.
    PARAMETER label.
    LOCAL captureStatus IS "complete".
    IF NOT reportState["COMPLETE"] { SET captureStatus TO "incomplete". }
    LOCAL completionRow IS label + " " + captureStatus + " ut=" + TIME:SECONDS
        + " file=" + reportState["PATH"].
    diagnosticArchiveLine(reportState, completionRow).
    LOCAL verified IS FALSE.
    IF reportState["READY"] AND reportState["COMPLETE"] AND HOMECONNECTION:ISCONNECTED {
        IF EXISTS(reportState["PATH"]) {
            SET verified TO OPEN(reportState["PATH"]):READALL:STRING:CONTAINS(completionRow).
        }
    }
    IF verified { PRINT "Verified snapshot in archive: " + reportState["PATH"]. }
    ELSE { PRINT "Snapshot incomplete or unverified: " + reportState["PATH"] + ". Re-run with a stable archive link.". }
    RETURN verified.
}
