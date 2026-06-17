// ============================================================
// cleanup.ks - Local volume cleanup helpers
// ============================================================

GLOBAL FUNCTION cleanupLocalVolume {
    LOCAL beforeFree IS CORE:VOLUME:FREESPACE.
    PRINT "Cleanup: free before " + beforeFree + " bytes.".

    LOCAL removedKs IS _cleanupRemoveSources("1:/").
    LOCAL removedLogs IS _cleanupClearLogs().

    PRINT "Cleanup: removed " + removedKs + " source files.".
    PRINT "Cleanup: removed " + removedLogs + " log/state files.".
    PRINT "Cleanup: free after  " + CORE:VOLUME:FREESPACE + " bytes.".
    PRINT "Cleanup: gained      " + (CORE:VOLUME:FREESPACE - beforeFree) + " bytes.".
}

LOCAL FUNCTION _cleanupRemoveSources {
    PARAMETER path_.

    LOCAL removed IS 0.
    IF NOT EXISTS(path_) { RETURN removed. }

    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(path_).
    LIST FILES IN items.
    CD(startPath).

    FOR item IN items {
        LOCAL itemPath IS path_ + item:NAME.
        IF item:ISFILE {
            IF _cleanupShouldDeleteSource(itemPath, item:NAME) {
                DELETEPATH(itemPath).
                SET removed TO removed + 1.
            }
        } ELSE {
            SET removed TO removed + _cleanupRemoveSources(itemPath + "/").
        }
    }
    RETURN removed.
}

LOCAL FUNCTION _cleanupShouldDeleteSource {
    PARAMETER path_.
    PARAMETER name_.

    LOCAL upPath IS path_:TOUPPER.
    IF upPath:LENGTH >= 12 AND upPath:SUBSTRING(0, 12) = "1:/MISSIONS/" { RETURN FALSE. }
    IF NOT name_:CONTAINS(".KS") { RETURN FALSE. }
    IF name_:CONTAINS(".KSM") { RETURN FALSE. }
    IF path_ = "1:/BOOT/BOOT.KS" { RETURN FALSE. }
    RETURN TRUE.
}

LOCAL FUNCTION _cleanupClearLogs {
    LOCAL removed IS 0.

    IF EXISTS("1:/run/log_path.state") {
        LOCAL logPath IS OPEN("1:/run/log_path.state"):READALL:STRING:TRIM.
        IF logPath <> "" AND EXISTS(logPath) {
            DELETEPATH(logPath).
            SET removed TO removed + 1.
        }
        DELETEPATH("1:/run/log_path.state").
        SET removed TO removed + 1.
    }

    IF EXISTS("1:/run") {
        SET removed TO removed + _cleanupRemoveLogFiles("1:/run/").
    }
    RETURN removed.
}

LOCAL FUNCTION _cleanupRemoveLogFiles {
    PARAMETER path_.

    LOCAL removed IS 0.
    IF NOT EXISTS(path_) { RETURN removed. }

    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(path_).
    LIST FILES IN items.
    CD(startPath).

    FOR item IN items {
        LOCAL itemPath IS path_ + item:NAME.
        IF item:ISFILE {
            IF item:NAME:CONTAINS(".LOG") OR item:NAME:CONTAINS(".log") {
                DELETEPATH(itemPath).
                SET removed TO removed + 1.
            }
        } ELSE {
            SET removed TO removed + _cleanupRemoveLogFiles(itemPath + "/").
        }
    }
    RETURN removed.
}
