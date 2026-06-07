// ============================================================
// boot.ks  —  Generic mission boot  (0:/boot/boot.ks)
// ============================================================

CORE:DOEVENT("Open Terminal").
CLEARSCREEN.
PRINT " ".
PRINT "  * kOS FLIGHT COMPUTER  v2.0".
PRINT "  * " + SHIP:NAME.

LOCAL HAS_LINK IS HOMECONNECTION:ISCONNECTED.
IF HAS_LINK {
    PRINT "  * KSC UPLINK ACTIVE".
} ELSE {
    PRINT "  * OFFLINE MODE (No KSC Link)".
}
PRINT " ".

IF SHIP:STATUS = "PRELAUNCH" OR SHIP:STATUS = "LANDED" {
    SET BRAKES TO TRUE.
}

LOCAL isEVA IS SHIP:ROOTPART:NAME:CONTAINS("kerbalEVA").
LOCAL vehicleName IS "".
LOCAL targetName IS "".
LOCAL payloadTypes IS LIST().

IF isEVA {
    SET vehicleName TO "EVA".
    SET targetName TO SHIP:BODY:NAME:TOUPPER.
    PRINT "  EVA KERBAL DETECTED".
} ELSE {
    LOCAL rawTokens IS SHIP:NAME:SPLIT("-").
    LOCAL tokens IS LIST().
    FOR t IN rawTokens {
        LOCAL trimmed IS t:TRIM.
        IF trimmed <> "" { tokens:ADD(trimmed). }
    }
    SET vehicleName TO tokens[0].
    IF tokens:LENGTH >= 2 {
        SET targetName TO tokens[1]:TOUPPER.
        LOCAL idx IS 2.
        UNTIL idx >= tokens:LENGTH {
            payloadTypes:ADD(tokens[idx]:TOUPPER).
            SET idx TO idx + 1.
        }
    } ELSE {
        SET targetName TO "KERBIN".
    }
}

LOCAL FUNCTION ensureDir { PARAMETER p. IF NOT EXISTS(p) { CREATEDIR(p). } }
ensureDir("1:/lib").
ensureDir("1:/boot").
ensureDir("1:/logs").
ensureDir("1:/state").
ensureDir("1:/cmd").
ensureDir("1:/craft").
ensureDir("1:/roles").
ensureDir("1:/missions").

LOCAL FUNCTION _resolveScript {
    PARAMETER name.
    PARAMETER dirs.
    
    IF HAS_LINK {
        FOR d IN dirs {
            IF EXISTS("0:/" + d + "/" + name + ".ks") { RETURN d + "/" + name. }
        }
        IF EXISTS("0:/" + name + ".ks") { RETURN name. }
    }
    
    // Fallback: Check local drive for cached or compiled scripts
    FOR d IN dirs {
        IF EXISTS("1:/" + d + "/" + name + ".ks") OR EXISTS("1:/" + d + "/" + name + ".ksm") { 
            RETURN d + "/" + name. 
        }
    }
    IF EXISTS("1:/" + name + ".ks") OR EXISTS("1:/" + name + ".ksm") { RETURN name. }
    
    RETURN "".
}

GLOBAL KSM_SKIP IS LIST().

LOCAL FUNCTION _syncLib {
    PARAMETER libName.
    IF NOT HAS_LINK { RETURN. }

    LOCAL src IS "0:/lib/" + libName + ".ks".
    LOCAL dst IS "1:/lib/" + libName + ".ks".
    LOCAL dstKsm IS "1:/lib/" + libName + ".ksm".

    IF EXISTS(src) {
        IF NOT KSM_SKIP:CONTAINS(libName) {
            COMPILE src TO dstKsm.
        } ELSE {
            COPYPATH(src, dst).
        }
    }
}

LOCAL FUNCTION _loadLib {
    PARAMETER libName.
    IF EXISTS("1:/lib/" + libName + ".ksm") {
        RUNONCEPATH("1:/lib/" + libName + ".ksm").
    } ELSE {
        RUNONCEPATH("1:/lib/" + libName + ".ks").
    }
}

LOCAL FUNCTION _compiledPath {
    PARAMETER scriptPath_.
    IF scriptPath_:CONTAINS("/") {
        LOCAL parts IS scriptPath_:SPLIT("/").
        RETURN "1:/" + parts[0] + "/" + parts[1] + ".ksm".
    }
    RETURN "1:/" + scriptPath_ + ".ksm".
}

LOCAL FUNCTION _sourcePath {
    PARAMETER scriptPath_.
    RETURN "1:/" + scriptPath_ + ".ks".
}

LOCAL FUNCTION _syncScript {
    PARAMETER scriptPath_.
    IF NOT HAS_LINK { RETURN. }
    LOCAL src IS "0:/" + scriptPath_ + ".ks".
    LOCAL dst IS _sourcePath(scriptPath_).
    LOCAL dstKsm IS _compiledPath(scriptPath_).

    IF EXISTS(src) {
        COMPILE src TO dstKsm.
        IF EXISTS(dst) { DELETEPATH(dst). }
    }
}

LOCAL FUNCTION _runScript {
    PARAMETER scriptPath_.
    LOCAL compiled IS _compiledPath(scriptPath_).
    IF EXISTS(compiled) {
        RUNPATH(compiled).
    } ELSE {
        RUNPATH(_sourcePath(scriptPath_)).
    }
}

LOCAL FUNCTION _libBaseName {
    PARAMETER fileName.
    LOCAL upper IS fileName:TOUPPER.
    IF upper:CONTAINS(".KSM") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF upper:CONTAINS(".KS") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 3). }
    RETURN fileName.
}

LOCAL FUNCTION _pruneLibs {
    PARAMETER wantedLibs.
    LOCAL keep IS LIST("STATE", "LOGS", "FILES", "RESUME", "RECOVERY").
    FOR lib IN wantedLibs {
        LOCAL libKey IS lib:TOUPPER.
        IF NOT keep:CONTAINS(libKey) { keep:ADD(libKey). }
    }

    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD("1:/lib").
    LIST FILES IN items.
    CD(startPath).

    FOR item IN items {
        IF item:ISFILE {
            LOCAL base IS _libBaseName(item:NAME).
            IF NOT keep:CONTAINS(base:TOUPPER) {
                DELETEPATH("1:/lib/" + item:NAME).
            }
        }
    }
}

LOCAL FUNCTION _missionConfigIds {
    PARAMETER craftName.
    LOCAL ids IS LIST().
    LOCAL cfgDir IS "1:/missions/" + craftName.
    LOCAL archiveDir IS "0:/missions/" + craftName.
    IF HAS_LINK AND EXISTS(archiveDir) {
        SET cfgDir TO archiveDir.
    }
    IF NOT EXISTS(cfgDir) { RETURN ids. }

    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(cfgDir).
    LIST FILES IN items.
    CD(startPath).

    FOR item IN items {
        IF item:ISFILE {
            LOCAL nm IS item:NAME.
            IF nm:TOUPPER:CONTAINS(".CFG") {
                ids:ADD(nm:SUBSTRING(0, nm:LENGTH - 4)).
            }
        }
    }
    RETURN ids.
}

LOCAL FUNCTION _selectMissionId {
    PARAMETER craftName.
    LOCAL configured IS stateGet("mission_id", "").
    IF configured <> "" { RETURN configured. }

    LOCAL ids IS _missionConfigIds(craftName).
    IF ids:LENGTH = 0 { RETURN "". }
    IF ids:LENGTH = 1 { RETURN ids[0]. }

    PRINT " ".
    PRINT "  " + craftName + " MISSION SELECT".
    PRINT "  ------------------".
    LOCAL maxShown IS MIN(ids:LENGTH, 9).
    FROM { LOCAL i IS 0. } UNTIL i >= maxShown STEP { SET i TO i + 1. } DO {
        PRINT "  " + (i + 1) + ") " + ids[i].
    }
    PRINT " ".
    PRINT "  Press 1-" + maxShown + " to choose, or ENTER for " + ids[0] + ".".

    LOCAL choice IS 0.
    LOCAL picked IS FALSE.
    UNTIL picked {
        WAIT UNTIL TERMINAL:INPUT:HASCHAR.
        LOCAL ch IS TERMINAL:INPUT:GETCHAR().
        IF ch = CHAR(13) OR ch = CHAR(10) {
            SET picked TO TRUE.
        } ELSE {
            FROM { LOCAL i IS 0. } UNTIL i >= maxShown STEP { SET i TO i + 1. } DO {
                IF ch = "" + (i + 1) {
                    SET choice TO i.
                    SET picked TO TRUE.
                }
            }
        }
    }
    RETURN ids[choice].
}

LOCAL FUNCTION _missionConfigPath {
    PARAMETER craftName.
    PARAMETER missionId.
    LOCAL archivePath IS "0:/missions/" + craftName + "/" + missionId + ".cfg".
    IF HAS_LINK AND EXISTS(archivePath) { RETURN archivePath. }
    RETURN "1:/missions/" + craftName + "/" + missionId + ".cfg".
}

LOCAL FUNCTION _applyMissionConfig {
    PARAMETER craftName.
    PARAMETER missionId.
    IF missionId = "" { RETURN FALSE. }

    LOCAL path_ IS _missionConfigPath(craftName, missionId).
    IF NOT EXISTS(path_) {
        PRINT "  Mission config not found: " + path_.
        RETURN FALSE.
    }

    LOCAL raw IS OPEN(path_):READALL:STRING.
    LOCAL lines IS raw:SPLIT(CHAR(10)).
    FOR lineRaw IN lines {
        LOCAL line IS lineRaw:REPLACE(CHAR(13), ""):TRIM.
        IF line <> "" {
            LOCAL skipLine IS FALSE.
            IF line:SUBSTRING(0, 1) = "#" { SET skipLine TO TRUE. }
            IF line:LENGTH >= 2 AND line:SUBSTRING(0, 2) = "//" { SET skipLine TO TRUE. }
            IF NOT skipLine {
                LOCAL parts IS line:SPLIT("=").
                IF parts:LENGTH >= 2 {
                    LOCAL key IS parts[0]:TRIM:TOUPPER.
                    LOCAL value IS parts[1]:TRIM.
                    stateSet("mission_cfg_" + key, value).
                    IF key = "MISSION_ID" {
                        stateSet("mission_id", value).
                    } ELSE IF key = "MISSION_NAME" {
                        stateSet("mission_name", value).
                    } ELSE IF key = "TARGET" {
                        stateSet("target", value:TOUPPER).
                    } ELSE IF key = "PAYLOADS" {
                        stateSet("payloads", value:TOUPPER).
                    }
                }
            }
        }
    }

    IF stateGet("mission_id", "") = "" { stateSet("mission_id", missionId). }
    PRINT "  Mission: " + stateGet("mission_name", missionId).
    PRINT "  Target:  " + stateGet("target", "KERBIN").
    PRINT "  Payload: " + stateGet("payloads", "").
    RETURN TRUE.
}

LOCAL FUNCTION _pruneMissionConfigs {
    PARAMETER craftName.
    LOCAL cfgDir IS "1:/missions/" + craftName.
    IF NOT EXISTS(cfgDir) { RETURN. }

    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(cfgDir).
    LIST FILES IN items.
    CD(startPath).

    FOR item IN items {
        IF item:ISFILE {
            DELETEPATH(cfgDir + "/" + item:NAME).
        }
    }
}

LOCAL FUNCTION _bootMissionConfig {
    PARAMETER craftName.
    LOCAL targetFromName IS stateGet("target", "KERBIN"):TOUPPER.
    LOCAL payloadsFromName IS stateGet("payloads", "").
    LOCAL hasNameMission IS targetFromName <> "KERBIN" OR payloadsFromName <> "".
    LOCAL missionId IS stateGet("mission_id", "").

    IF missionId = "" AND NOT hasNameMission {
        SET missionId TO _selectMissionId(craftName).
    }
    IF missionId <> "" {
        _applyMissionConfig(craftName, missionId).
    }
}

LOCAL FUNCTION _isLaunchStartPhase {
    PARAMETER phaseName.
    LOCAL phase IS phaseName:TOUPPER.
    RETURN phase = "" OR phase = "LUNCH" OR phase = "FAIR" OR phase = "ANTS".
}

LOCAL FUNCTION _shouldResetMissionOnBoot {
    IF isEVA { RETURN FALSE. }
    IF SHIP:STATUS = "PRELAUNCH" { RETURN TRUE. }

    LOCAL phase IS stateGet("phase", "").
    IF SHIP:BODY:NAME = "Kerbin"
            AND SHIP:STATUS = "LANDED"
            AND stateGetNum("launch_time", 0) = 0
            AND _isLaunchStartPhase(phase) {
        RETURN TRUE.
    }
    RETURN FALSE.
}

LOCAL FUNCTION _resetMissionSelection {
    LOCAL removed IS stateRemovePrefix("mission_cfg_").
    FOR key IN LIST(
        "mission_id", "mission_name", "phase", "fairing_deployed",
        "lib_band", "lib_band_phase", "lib_band_libs",
        "reload_required", "reload_reason", "reload_next_phase",
        "reload_next_band"
    ) {
        stateRemove(key).
    }

    stateSet("vehicle", vehicleName).
    stateSet("target", targetName).
    stateSet("payloads", payloadTypes:JOIN(",")).
    PRINT "  Mission selection reset for prelaunch.".
    mLog("Mission selection reset before launch; cleared " + removed + " config keys.").
}

IF HAS_LINK {
    PRINT "  SYNC core ......... ".
    LOCAL coreLibs IS LIST("state", "logs", "files").
    FOR lib IN coreLibs { _syncLib(lib). }
} ELSE {
    PRINT "  LOAD core (cached) . ".
}

_loadLib("state").
stateInit().
_loadLib("logs").
initLog().
WAIT 0.001. // Let the start time tick and get created.
_loadLib("files").

IF _shouldResetMissionOnBoot() {
    _resetMissionSelection().
}

LOCAL bootCount IS stateGetNum("boot_count", 0) + 1.
stateSetNum("boot_count", bootCount).
IF bootCount = 1 {
    stateSet("vehicle",  vehicleName).
    stateSet("target",   targetName).
    stateSet("payloads", payloadTypes:JOIN(",")).
}
LOCAL vehicleScript IS "".
IF isEVA {
    SET vehicleScript TO _resolveScript("EVA", LIST("roles")).
} ELSE IF CORE:TAG <> "" {
    SET vehicleScript TO _resolveScript(CORE:TAG, LIST("roles", "craft")).
    IF vehicleScript <> "" {
        PRINT "  CORE TAG: " + CORE:TAG + " -> " + vehicleScript + ".ks".
    } ELSE {
        PRINT "  CORE TAG: " + CORE:TAG + " (no script found, trying vehicle).".
    }
}

IF vehicleScript = "" {
    SET vehicleScript TO _resolveScript(vehicleName, LIST("craft")).
}

mLog("=== BOOT #" + bootCount + " === " + SHIP:NAME + " ===").

IF vehicleScript = "" {
    PRINT "  !! SCRIPT NOT FOUND: " + vehicleName.
    PRINT "  !! Checked craft/ and root.".
    PRINT "  SYSTEM HALTED.".
    mLogError("No script found for " + vehicleName).
    WAIT UNTIL FALSE.
}

IF vehicleScript:CONTAINS("/") {
    LOCAL parts IS vehicleScript:SPLIT("/").
    ensureDir("1:/" + parts[0]).
}

IF HAS_LINK {
    PRINT "  SYNC Zombie ........".
    IF EXISTS("0:/cmd/zombie.ks") { COPYPATH("0:/cmd/zombie.ks", "1:/zombie"). }

    PRINT "  SYNC " + vehicleScript + " ....... ".
    _syncScript(vehicleScript).
    _bootMissionConfig(vehicleName).
    _pruneMissionConfigs(vehicleName).
}

// 1. Run the vehicle script first so it can define the LIBS global variable
_runScript(vehicleScript).

// 2. Now that LIBS exists, sync them if we have a connection
IF HAS_LINK {
    PRINT "  SYNC libs ......... ".
    IF DEFINED LIBS {
        _pruneLibs(LIBS).
        FOR lib IN LIBS { _syncLib(lib). }
    }
    _syncLib("resume").
    _syncLib("recovery").
} ELSE {
    PRINT "  NO LINK: Bypassing library sync.".
}

// 3. Load the libraries into memory
IF DEFINED LIBS {
    FOR lib IN LIBS { _loadLib(lib). }
}
_loadLib("resume").

PRINT " ".
PRINT "  BOOT #" + bootCount + " OK".
printStorageStatus().

// Archive the boot log.
IF HAS_LINK { archiveLog(). }

PRINT " ".
PRINT "  >> Press any key for MANUAL mode (5s)".
LOCAL overrideStart IS TIME:SECONDS.
LOCAL manualMode IS FALSE.
WAIT UNTIL TIME:SECONDS > overrideStart + 5 OR TERMINAL:INPUT:HASCHAR.
IF TERMINAL:INPUT:HASCHAR {
    TERMINAL:INPUT:GETCHAR().
    SET manualMode TO TRUE.
}

IF NOT manualMode {
    LOCAL phase IS stateGet("phase", "").
    IF phase = "DONE" {
        PRINT " ".
        PRINT "  MISSION COMPLETE. MANUAL MODE.".
        mLog("Reboot after DONE — manual mode.").
    } ELSE IF phase = "ABORT" {
        PRINT "  ABORT DETECTED — entering recovery mode.".
        mLog("Abort detected at reboot — loading recovery.").
        // Ensure recovery logic doesn't crash if offline
        recoveryMode().
    } ELSE {
        PRINT "  RESUMING >> " + phase.
        mLog("Resuming mission from phase: " + phase).
        resumeMission().
    }
}

IF HAS_LINK { 
    archiveLog(). 
    _syncLib("recovery"). 
    _loadLib("recovery").
}
PRINT ("END OF LINE. GODSPEED.").
UNLOCK ALL.
SET SAS TO TRUE.
