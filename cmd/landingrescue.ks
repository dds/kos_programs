// cmd/landingrescue.ks - Free space for FR3 Mun landing resume.
// Usage: RUNPATH("0:/cmd/landingrescue.ks").
// Usage cached: RUNPATH("1:/cmd/landingrescue.ks").

PARAMETER phaseName IS "LAND_DEORBIT".

LOCAL beforeFree IS CORE:VOLUME:FREESPACE.
PRINT "Landing rescue: free before " + beforeFree + " bytes.".

LOCAL keepLibs IS LIST(
    "STATE", "LOGS", "FILES", "BOOT_LIB", "RESUME", "RECOVERY",
    "PHASES", "UTILS", "UI", "FR3_PAYLOAD", "FR3_PROFILE", "FR3_SEQUENCE"
).
IF phaseName = "LAND_ASSIST" {
    keepLibs:ADD("LANDING_CARRIER").
} ELSE IF phaseName = "LAND_DEORBIT" {
    keepLibs:ADD("PAYLOAD_LANDING").
    keepLibs:ADD("LANDING_ASSIST").
    keepLibs:ADD("TARGETING").
    keepLibs:ADD("COUNTDOWN").
    keepLibs:ADD("MANEUVER").
}

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
    IF fileName:CONTAINS(".KSM") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF fileName:CONTAINS(".KS") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 3). }
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
            LOCAL base IS _baseName(item:NAME).
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
SET removed TO removed + _pruneDir("1:/cmd", LIST("LANDASSIST", "LANDINGRESCUE", "SETLANDASSIST")).
SET removed TO removed + _pruneDir("1:/missions/FR3", LIST()).
IF _deleteIfExists("1:/zombie") { SET removed TO removed + 1. }

IF EXISTS("1:/run") {
    LOCAL logItems IS LIST().
    LOCAL startPath IS PATH().
    CD("1:/run").
    LIST FILES IN logItems.
    CD(startPath).
    FOR item IN logItems {
        IF item:ISFILE AND (item:NAME:CONTAINS(".LOG") OR item:NAME:CONTAINS(".log")) {
            IF _deleteIfExists("1:/run/" + item:NAME) {
                SET removed TO removed + 1.
            }
        }
    }
}

IF _deleteIfExists("1:/run/log_path.state") {
    SET removed TO removed + 1.
}

RUNPATH("1:/lib/boot_lib").
bootLibLoad("state").
stateSet("phase", phaseName).
stateSet("reload_required", "false").
IF phaseName = "LAND_DEORBIT" {
    stateSet("lib_band", "LAND_DEORBIT").
} ELSE IF phaseName = "LAND_ASSIST" {
    stateSet("lib_band", "LAND_ASSIST").
} ELSE {
    stateSet("lib_band", "LAND_ASSIST").
}

PRINT "Landing rescue: removed " + removed + " files.".
PRINT "Landing rescue: phase -> " + phaseName + ".".
PRINT "Landing rescue: free after  " + CORE:VOLUME:FREESPACE + " bytes.".
PRINT "Run: REBOOT.".
