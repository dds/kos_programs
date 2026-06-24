// Discard terminal input left over from before this boot. Manual mode
// should only arm from a key pressed after the boot script starts.

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

UNTIL NOT TERMINAL:INPUT:HASCHAR {
    TERMINAL:INPUT:GETCHAR().
}
GLOBAL BOOT_INPUT_DRAINED IS TRUE.

PRINT " ".
PRINT "  * kOS FLIGHT COMPUTER  v2.0".
PRINT "  * " + SHIP:NAME.

WAIT 1. // Slight wait for radio to come online.
LOCAL HAS_LINK IS HOMECONNECTION:ISCONNECTED.

LOCAL FUNCTION _bootCue {
    PARAMETER linked.
    LOCAL v IS GETVOICE(0).
    SET v:LOOP TO FALSE.
    SET v:VOLUME TO 0.35.
    SET v:ATTACK TO 0.005.
    SET v:DECAY TO 0.015.
    SET v:SUSTAIN TO 0.75.
    SET v:RELEASE TO 0.03.
    IF linked {
        SET v:WAVE TO "triangle".
        v:PLAY(LIST(
            NOTE("c5", 0.06, 0.045),
            NOTE("e5", 0.06, 0.045),
            NOTE("g5", 0.09, 0.070)
        )).
    } ELSE {
        SET v:WAVE TO "sine".
        v:PLAY(LIST(
            NOTE(220, 0.09, 0.070),
            NOTE(146.83, 0.13, 0.105),
            NOTE(196, 0.08, 0.060),
            NOTE(130.81, 0.16, 0.135)
        )).
    }
}

_bootCue(HAS_LINK).
PRINT " ".

IF SHIP:STATUS = "PRELAUNCH" OR SHIP:STATUS = "LANDED" {
    SET BRAKES TO TRUE.
}

GLOBAL KSM_SKIP IS LIST().

LOCAL FUNCTION _ensureDir {
    PARAMETER p.
    IF NOT EXISTS(p) { CREATEDIR(p). }
}

LOCAL FUNCTION _syncLib {
    PARAMETER libName.
    IF NOT HAS_LINK { RETURN. }
    LOCAL src IS "0:/lib/" + libName + ".ks".
    LOCAL dst IS "1:/lib/" + libName + ".ks".
    LOCAL dstKsm IS "1:/lib/" + libName + ".ksm".
    IF EXISTS(src) {
        IF NOT KSM_SKIP:CONTAINS(libName) {
            // Compile on the spacious archive, then copy the .ksm down
            // (delete first so it needs only the file's size) — a
            // nearly-full probe can't hold the compiler's scratch space.
            LOCAL arKsm IS "0:/lib/" + libName + ".ksm".
            COMPILE src TO arKsm.
            IF EXISTS(dstKsm) { DELETEPATH(dstKsm). }
            COPYPATH(arKsm, dstKsm).
        } ELSE {
            COPYPATH(src, dst).
        }
    }
}

LOCAL FUNCTION _loadLib {
    PARAMETER libName.
    IF EXISTS("1:/lib/" + libName + ".ksm") {
        RUNONCEPATH("1:/lib/" + libName + ".ksm").
    } ELSE IF EXISTS("1:/lib/" + libName + ".ks") {
        RUNONCEPATH("1:/lib/" + libName + ".ks").
    } ELSE {
        PRINT "  WARN: " + libName + " unavailable".
    }
}

_ensureDir("1:/lib").
_ensureDir("1:/run").
LOCAL preSweptLogs IS 0.
LOCAL preOldLogPath IS "".
IF HAS_LINK {
    _ensureDir("0:/logs").
    _ensureDir("0:/logs/archive").
}
IF EXISTS("1:/run/log_path.state") {
    SET preOldLogPath TO OPEN("1:/run/log_path.state"):READALL:STRING:TRIM.
}
IF EXISTS("1:/run/logs") {
    LOCAL preSweepPath IS PATH().
    LOCAL preLogDirs IS LIST().
    CD("1:/run/logs").
    LIST FILES IN preLogDirs.
    CD(preSweepPath).
    FOR preLogDir IN preLogDirs {
        LOCAL preLogDirPath IS "1:/run/logs/" + preLogDir:NAME.
        IF preLogDir:ISFILE {
            IF preLogDir:NAME:CONTAINS(".LOG") OR preLogDir:NAME:CONTAINS(".log") {
                IF HAS_LINK {
                    LOCAL preArchivePath IS "0:/logs/archive/" + preLogDir:NAME.
                    IF EXISTS(preArchivePath) { DELETEPATH(preArchivePath). }
                    COPYPATH(preLogDirPath, preArchivePath).
                }
                DELETEPATH(preLogDirPath).
                SET preSweptLogs TO preSweptLogs + 1.
            }
        } ELSE {
            LOCAL preLogItems IS LIST().
            CD(preLogDirPath).
            LIST FILES IN preLogItems.
            CD(preSweepPath).
            LOCAL preArchiveDir IS "0:/logs/archive/" + preLogDir:NAME.
            IF HAS_LINK { _ensureDir(preArchiveDir). }
            FOR preLogItem IN preLogItems {
                IF preLogItem:ISFILE {
                    IF preLogItem:NAME:CONTAINS(".LOG") OR preLogItem:NAME:CONTAINS(".log") {
                        LOCAL preLogPath IS preLogDirPath + "/" + preLogItem:NAME.
                        IF HAS_LINK {
                            LOCAL preArchiveItem IS preArchiveDir + "/" + preLogItem:NAME.
                            IF EXISTS(preArchiveItem) { DELETEPATH(preArchiveItem). }
                            COPYPATH(preLogPath, preArchiveItem).
                        }
                        DELETEPATH(preLogPath).
                        SET preSweptLogs TO preSweptLogs + 1.
                    }
                }
            }
        }
    }
}
IF preOldLogPath <> "" AND EXISTS(preOldLogPath) {
    IF HAS_LINK {
        _ensureDir("0:/logs/archive/_boot_sweep").
        LOCAL preOldParts IS preOldLogPath:SPLIT("/").
        LOCAL preOldName IS preOldParts[preOldParts:LENGTH - 1].
        LOCAL preOldArchivePath IS "0:/logs/archive/_boot_sweep/" + preOldName.
        IF EXISTS(preOldArchivePath) { DELETEPATH(preOldArchivePath). }
        COPYPATH(preOldLogPath, preOldArchivePath).
    }
    DELETEPATH(preOldLogPath).
    SET preSweptLogs TO preSweptLogs + 1.
}
IF EXISTS("1:/run/log_path.state") {
    IF HAS_LINK {
        _ensureDir("0:/logs/archive/_boot_sweep").
        LOCAL preStateArchivePath IS "0:/logs/archive/_boot_sweep/log_path.state".
        IF EXISTS(preStateArchivePath) {
            DELETEPATH(preStateArchivePath).
        }
        COPYPATH("1:/run/log_path.state", preStateArchivePath).
    }
    DELETEPATH("1:/run/log_path.state").
    SET preSweptLogs TO preSweptLogs + 1.
}
IF HAS_LINK {
    PRINT "  SYNC boot lib ..... ".
    _syncLib("boot_lib").
    _syncLib("dependencies").
    IF EXISTS("0:/VERSION") {
        COPYPATH("0:/VERSION", "1:/run/code_version.state").
    }
} ELSE {
    PRINT "  LOAD core (cached) . ".
}

_loadLib("boot_lib").
LOCAL sweptLogs IS preSweptLogs.
IF DEFINED bootSweepLogs {
    SET sweptLogs TO sweptLogs + bootSweepLogs("1:/run/logs", "0:/logs/archive", HAS_LINK).
    SET sweptLogs TO sweptLogs + bootSweepLogs("1:/run", "0:/logs/archive/_boot_sweep", HAS_LINK).
}
IF sweptLogs > 0 {
    PRINT "  OLD LOGS swept: " + sweptLogs + ".".
}
_loadLib("dependencies").
BOOT_LIB_RAN:ADD("dependencies").
bootPreamble().
stateInit().
stateRemove("lib_band_libs").
WAIT 0.001.

bootEnsureDirs().
LOCAL vehicleInfo IS bootVehicleInfo().
LOCAL isEVA IS vehicleInfo["IS_EVA"].
LOCAL vehicleName IS vehicleInfo["VEHICLE"].
LOCAL targetName IS vehicleInfo["TARGET"].
LOCAL payloadTypes IS vehicleInfo["PAYLOADS"].

LOCAL bootCount IS stateGetNum("boot_count", 0) + 1.
stateSet("boot_log_count", bootCount).

IF bootShouldResetMissionOnBoot(isEVA) {
    bootResetMissionSelection(vehicleName, targetName, payloadTypes).
    stateSet("boot_log_count", bootCount).
}

stateSet("boot_count", bootCount).
IF bootCount = 1 {
    stateSet("vehicle",  vehicleName).
    stateSet("target",   targetName).
    stateSet("payloads", payloadTypes).
}
initLog().

LOCAL vehicleScript IS "".
LOCAL isRoleScript IS FALSE.
IF isEVA {
    SET vehicleScript TO bootResolveScript("EVA", LIST("roles"), HAS_LINK).
} ELSE IF CORE:TAG <> "" {
    SET vehicleScript TO bootResolveScript(CORE:TAG, LIST("roles", "craft"), HAS_LINK).
    IF vehicleScript <> "" {
        PRINT "  CORE TAG: " + CORE:TAG + " -> " + vehicleScript + ".ks".
    } ELSE {
        PRINT "  CORE TAG: " + CORE:TAG + " (no script found, trying vehicle).".
    }
}
IF vehicleScript = "" {
    SET vehicleScript TO bootResolveScript(vehicleName, LIST("craft"), HAS_LINK).
}
IF vehicleScript:CONTAINS("/") {
    LOCAL scriptParts IS vehicleScript:SPLIT("/").
    IF scriptParts[0] = "roles" { SET isRoleScript TO TRUE. }
}

mLog("=== BOOT #" + bootCount + " === " + SHIP:NAME + " ===").
IF vehicleScript = "" {
    PRINT "  !! SCRIPT NOT FOUND: " + vehicleName.
    mLogError("No script found for " + vehicleName).
}

IF vehicleScript:CONTAINS("/") {
    LOCAL parts IS vehicleScript:SPLIT("/").
    _ensureDir("1:/" + parts[0]).
}

IF HAS_LINK {
    IF vehicleScript <> "" {
        PRINT "  SYNC " + vehicleScript + " ....... ".
        COPYPATH("0:/" + vehicleScript, "1:/" + vehicleScript).
    }
}

bootMissionConfig(vehicleName, HAS_LINK).

LOCAL vehicleLibs IS LIST().
IF isRoleScript AND vehicleScript <> "" {
    // Roles may not have mission profiles; keep their explicit boot hook.
    RUNPATH(vehicleScript).
    SET vehicleLibs TO bootVehicleLibs().
} ELSE {
    SET vehicleLibs TO bootPlannedMissionLibs().
}

IF HAS_LINK {
    PRINT "  SYNC libs ......... ".
    LOCAL cleanupVehicle IS vehicleName.
    IF vehicleScript:CONTAINS("/") {
        LOCAL cleanupParts IS vehicleScript:SPLIT("/").
        IF cleanupParts[0] = "craft" { SET cleanupVehicle TO cleanupParts[1]. }
    }
    bootCleanup(cleanupVehicle, vehicleLibs, vehicleName).
    bootLibLoadList(vehicleLibs).
} ELSE {
    PRINT "  NO LINK: Bypassing library sync.".
    bootLibLoadList(vehicleLibs).
}

IF vehicleScript <> "" {
    RUNPATH(vehicleScript).
}

IF stateGet("mission_id", "") <> "" {
    bootApplyMissionConfig(vehicleName, stateGet("mission_id", ""), HAS_LINK).
}
bootLibLoad("resume").
// Recovery is loaded only at startup/abort or after manual mode.
LOCAL phase_ IS stateGet("phase", "").
IF phase_ = "" OR phase_ = "ABORT" {
    bootLibLoad("recovery").
}

PRINT " ".
PRINT "  BOOT #" + bootCount + " OK".
IF DEFINED printStorageStatus { printStorageStatus(). }
IF HAS_LINK { archiveLog(). }
IF stateGet("phase", "") = "ABORT" { bootLibLoad("recovery"). }

IF isRoleScript {
    PRINT "  ROLE MAIN >> " + vehicleScript.
    mLog("Starting role main: " + vehicleScript).
    main().
    IF HOMECONNECTION:ISCONNECTED { archiveLog(). }
} ELSE {
    bootResumeOrManual(HAS_LINK).
}
IF HAS_LINK {
    bootLibLoad("recovery").
}
LOCAL tailSolarInSpace IS SHIP:STATUS = "ORBITING"
    OR SHIP:STATUS = "ESCAPING"
    OR SHIP:STATUS = "SUB_ORBITAL".
// Skip the (slow) solar re-orient on a manual boot — the operator has
// taken over and can run cmd/orientForSolar.ks if they want it.
IF NOT BOOT_MANUAL_REQUESTED AND HOMECONNECTION:ISCONNECTED
        AND tailSolarInSpace AND EXISTS("0:/cmd/orientForSolar.ks") {
    RUNPATH("0:/cmd/orientForSolar.ks").
}
PRINT "END OF LINE. GODSPEED.".
UNLOCK ALL.
SET SAS TO TRUE.
