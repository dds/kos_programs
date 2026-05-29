// ============================================================
// files.ks  —  Storage utilities  (0:/lib/files.ks)
// ============================================================

@LAZYGLOBAL OFF.

GLOBAL FUNCTION printStorageStatus {
    printDirectory().
    PRINT "--- STORAGE STATUS ---".
    PRINT "Volume: " + CORE:VOLUME:NAME.
    PRINT "{0} {1} bytes":FORMAT("Capacity":PADRIGHT(12),  CORE:VOLUME:CAPACITY).
    PRINT "{0} {1} bytes":FORMAT("Free Space":PADRIGHT(12), CORE:VOLUME:FREESPACE).
    IF CORE:VOLUME:FREESPACE < 1000 {
        PRINT " ".
        PRINT "WARNING: Local storage is almost full!".
    }
}

GLOBAL FUNCTION printDirectory {
    PRINT "--- FILE LISTING ---".
    LOCAL startPath IS PATH().
    CD("1:/").
    _scanFolder(0).
    CD(startPath).
}

LOCAL FUNCTION _scanFolder {
    PARAMETER depth.
    LOCAL indent IS "".
    LOCAL d IS 0.
    UNTIL d >= depth { SET indent TO indent + "  ". SET d TO d + 1. }

    LOCAL items IS LIST().
    LIST FILES IN items.

    IF items:LENGTH = 0 AND depth = 0 {
        PRINT "(Drive is empty)".
        RETURN.
    }

    FOR item IN items {
        IF item:ISFILE {
            PRINT indent + "{0} {1} bytes":FORMAT(item:NAME:PADRIGHT(22), item:SIZE).
        } ELSE {
            PRINT indent + "+ [" + item:NAME + "]".
            CD(item:NAME).
            _scanFolder(depth + 1).
            CD("..").
        }
    }
}
