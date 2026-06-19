// cmd/fr3clean.ks - Standalone aggressive FR3 cache cleanup.
// Usage: RUNPATH("0:/cmd/fr3clean.ks").

LOCAL beforeFree IS CORE:VOLUME:FREESPACE.
LOCAL removed IS 0.

LOCAL FUNCTION _base {
    PARAMETER fileName.
    IF fileName:CONTAINS(".KSM") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF fileName:CONTAINS(".KS") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 3). }
    IF fileName:CONTAINS(".CFG") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    RETURN fileName.
}

LOCAL FUNCTION _deleteIfExists {
    PARAMETER path_.
    IF EXISTS(path_) {
        DELETEPATH(path_).
        SET removed TO removed + 1.
    }
}

LOCAL FUNCTION _pruneDir {
    PARAMETER dirPath.
    PARAMETER keepNames.
    IF NOT EXISTS(dirPath) { RETURN. }

    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(dirPath).
    LIST FILES IN items.
    CD(startPath).

    FOR item IN items {
        IF item:ISFILE {
            LOCAL baseName IS _base(item:NAME).
            IF NOT keepNames:CONTAINS(baseName) {
                _deleteIfExists(dirPath + "/" + item:NAME).
            }
        }
    }
}

LOCAL FUNCTION _deleteLogFiles {
    PARAMETER dirPath.
    LOCAL count IS 0.
    IF NOT EXISTS(dirPath) { RETURN count. }

    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(dirPath).
    LIST FILES IN items.
    CD(startPath).

    FOR item IN items {
        LOCAL itemPath IS dirPath + "/" + item:NAME.
        IF item:ISFILE {
            IF item:NAME:CONTAINS(".LOG") OR item:NAME:CONTAINS(".log")
                    OR item:NAME = "log_path.state" {
                _deleteIfExists(itemPath).
                SET count TO count + 1.
            }
        } ELSE {
            SET count TO count + _deleteLogFiles(itemPath).
        }
    }
    RETURN count.
}

LOCAL keepLibs IS LIST(
    "STATE", "LOGS", "FILES", "BOOT_LIB", "RESUME", "RECOVERY"
).
PRINT "FR3 clean: free before " + beforeFree + " bytes.".

_pruneDir("1:/lib", keepLibs).
_pruneDir("1:/craft", LIST()).
_pruneDir("1:/roles", LIST()).
_pruneDir("1:/cmd", LIST()).
_deleteIfExists("1:/zombie").

IF EXISTS("1:/run") {
    _deleteLogFiles("1:/run").
}

PRINT "FR3 clean: removed " + removed + " files.".
PRINT "FR3 clean: free after  " + CORE:VOLUME:FREESPACE + " bytes.".
PRINT "Run: REBOOT.".
