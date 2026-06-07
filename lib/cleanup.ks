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

    LOCAL upperName IS name_:TOUPPER.
    LOCAL upperPath IS path_:TOUPPER.
    IF NOT upperName:CONTAINS(".KS") { RETURN FALSE. }
    IF upperName:CONTAINS(".KSM") { RETURN FALSE. }
    IF upperPath = "1:/BOOT/BOOT.KS" { RETURN FALSE. }
    RETURN TRUE.
}

LOCAL FUNCTION _cleanupClearLogs {
    LOCAL removed IS 0.

    IF EXISTS("1:/state/log_path.state") {
        LOCAL logPath IS OPEN("1:/state/log_path.state"):READALL:STRING:TRIM.
        IF logPath <> "" AND EXISTS(logPath) {
            DELETEPATH(logPath).
            SET removed TO removed + 1.
        }
        DELETEPATH("1:/state/log_path.state").
        SET removed TO removed + 1.
    }

    IF EXISTS("1:/logs") {
        SET removed TO removed + _cleanupRemoveAllFiles("1:/logs/").
    }
    RETURN removed.
}

LOCAL FUNCTION _cleanupRemoveAllFiles {
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
            DELETEPATH(itemPath).
            SET removed TO removed + 1.
        } ELSE {
            SET removed TO removed + _cleanupRemoveAllFiles(itemPath + "/").
        }
    }
    RETURN removed.
}
