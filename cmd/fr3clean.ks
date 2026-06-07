// cmd/fr3clean.ks - Standalone aggressive FR3 cache cleanup.
// Usage: RUNPATH("0:/cmd/fr3clean.ks").
// Cached: RUNPATH("1:/cmd/fr3clean.ks").

LOCAL beforeFree IS CORE:VOLUME:FREESPACE.
LOCAL removed IS 0.

LOCAL FUNCTION _base {
    PARAMETER fileName.
    LOCAL upper IS fileName:TOUPPER.
    IF upper:CONTAINS(".KSM") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF upper:CONTAINS(".KS") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 3). }
    IF upper:CONTAINS(".CFG") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
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
            LOCAL baseName IS _base(item:NAME):TOUPPER.
            IF NOT keepNames:CONTAINS(baseName) {
                _deleteIfExists(dirPath + "/" + item:NAME).
            }
        }
    }
}

LOCAL keepLibs IS LIST(
    "STATE", "LOGS", "FILES", "BOOT_CORE", "RESUME", "RECOVERY"
).
LOCAL keepCmds IS LIST("FR3CLEAN", "ZOMBIE").

PRINT "FR3 clean: free before " + beforeFree + " bytes.".

_pruneDir("1:/lib", keepLibs).
_pruneDir("1:/craft", LIST()).
_pruneDir("1:/roles", LIST()).
_pruneDir("1:/cmd", keepCmds).
_pruneDir("1:/missions/FR3", LIST()).
_pruneDir("1:/missions/FR2", LIST()).
_pruneDir("1:/missions", LIST()).

IF EXISTS("1:/logs") {
    LOCAL logItems IS LIST().
    LOCAL startPath IS PATH().
    CD("1:/logs").
    LIST FILES IN logItems.
    CD(startPath).
    FOR item IN logItems {
        IF item:ISFILE { _deleteIfExists("1:/logs/" + item:NAME). }
    }
}
_deleteIfExists("1:/state/log_path.state").

PRINT "FR3 clean: removed " + removed + " files.".
PRINT "FR3 clean: free after  " + CORE:VOLUME:FREESPACE + " bytes.".
PRINT "Run: REBOOT.".
