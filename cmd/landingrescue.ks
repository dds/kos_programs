// cmd/landingrescue.ks - Free space for FR3 Mun landing resume.
// Usage: RUNPATH("0:/cmd/landingrescue.ks").
// Usage cached: RUNPATH("1:/cmd/landingrescue.ks").

PARAMETER phaseName IS "LAND_DEORBIT".

LOCAL beforeFree IS CORE:VOLUME:FREESPACE.
PRINT "Landing rescue: free before " + beforeFree + " bytes.".

LOCAL keepLibs IS LIST(
    "STATE", "LOGS", "FILES", "BOOT_CORE", "RESUME", "RECOVERY",
    "PHASES", "UTILS", "UI", "FR3_PAYLOAD", "FR3_PROFILE", "FR3_SEQUENCE",
    "PAYLOAD_LANDING", "TARGETING", "COUNTDOWN", "MANEUVER", "LANDING_ASSIST"
).

LOCAL FUNCTION _deleteIfExists {
    PARAMETER path_.
    IF EXISTS(path_) {
        DELETEPATH(path_).
        RETURN TRUE.
    }
    RETURN FALSE.
}

LOCAL FUNCTION _baseName {
    PARAMETER fileName.
    LOCAL upper IS fileName:TOUPPER.
    IF upper:CONTAINS(".KSM") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF upper:CONTAINS(".KS") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 3). }
    RETURN fileName.
}

LOCAL FUNCTION _pruneDir {
    PARAMETER dirPath.
    PARAMETER keepNames.

    LOCAL removed IS 0.
    IF NOT EXISTS(dirPath) { RETURN removed. }
    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(dirPath).
    LIST FILES IN items.
    CD(startPath).
    FOR item IN items {
        LOCAL path_ IS dirPath + "/" + item:NAME.
        IF item:ISFILE {
            LOCAL base IS _baseName(item:NAME):TOUPPER.
            IF NOT keepNames:CONTAINS(base) {
                IF _deleteIfExists(path_) { SET removed TO removed + 1. }
            }
        }
    }
    RETURN removed.
}

LOCAL removed IS 0.

SET removed TO removed + _pruneDir("1:/lib", keepLibs).
SET removed TO removed + _pruneDir("1:/craft", LIST("FR3")).
SET removed TO removed + _pruneDir("1:/roles", LIST()).

IF EXISTS("1:/logs") {
    LOCAL logItems IS LIST().
    LOCAL startPath IS PATH().
    CD("1:/logs").
    LIST FILES IN logItems.
    CD(startPath).
    FOR item IN logItems {
        IF item:ISFILE {
            IF _deleteIfExists("1:/logs/" + item:NAME) {
                SET removed TO removed + 1.
            }
        }
    }
}

IF _deleteIfExists("1:/state/log_path.state") {
    SET removed TO removed + 1.
}

IF EXISTS("1:/lib/state.ksm") {
    RUNONCEPATH("1:/lib/state.ksm").
} ELSE IF EXISTS("1:/lib/state.ks") {
    RUNONCEPATH("1:/lib/state.ks").
}
IF DEFINED stateSet {
    stateSet("phase", phaseName:TOUPPER).
    stateSet("reload_required", "false").
    stateSet("lib_band", "LAND_ASSIST").
}

PRINT "Landing rescue: removed " + removed + " files.".
PRINT "Landing rescue: phase -> " + phaseName:TOUPPER + ".".
PRINT "Landing rescue: free after  " + CORE:VOLUME:FREESPACE + " bytes.".
PRINT "Run: REBOOT.".
