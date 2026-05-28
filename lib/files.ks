@LAZYGLOBAL OFF.

DECLARE GLOBAL FUNCTION printStorageStatus {
    printDirectory(). 
    
    PRINT "--- STORAGE STATUS ---".
    PRINT "Volume: " + CORE:VOLUME:NAME.
    PRINT "{0} {1} bytes":FORMAT("Capacity":PADRIGHT(12), CORE:VOLUME:CAPACITY).
    PRINT "{0} {1} bytes":FORMAT("Free Space":PADRIGHT(12), CORE:VOLUME:FREESPACE).

    IF CORE:VOLUME:FREESPACE < 1000 {
        PRINT " ".
        PRINT "WARNING: Local storage is almust full!".
    }
}

DECLARE GLOBAL FUNCTION printDirectory {
    PRINT "--- FILE LISTING ---".

    LOCAL startPath is PATH().

    CD("1:/").

    scanFolder(" ").

    CD(startPath).
}

DECLARE LOCAL FUNCTION scanFolder {
    PARAMETER indent.

    LOCAL currentItems IS LIST().

    LIST FILES IN currentItems.

    IF currentItems:LENGTH = 0 AND indent = " " {
        PRINT indent + "(Drive is empty)".
        RETURN.
    }

    FOR item in currentItems {
        IF item:ISFILE {
            PRINT indent + "{0} {1} bytes":FORMAT(item:NAME:padright(20), item:SIZE).
        } ELSE {
            PRINT indent + "+ [" + item:NAME + "]".
            CD(item:NAME).
            scanFolder(indent + " ").
            CD("..").
        }
    }
}
