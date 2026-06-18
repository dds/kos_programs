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
    } ELSE IF EXISTS("1:/lib/" + libName + ".ks") {
        RUNONCEPATH("1:/lib/" + libName + ".ks").
    } ELSE {
        PRINT "  WARN: " + libName + " unavailable".
    }
}

_ensureDir("1:/lib").
_ensureDir("1:/run").
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
_loadLib("dependencies").
BOOT_LIB_RAN:ADD("dependencies").
bootPreamble().
stateInit().
initLog().
WAIT 0.001.

bootEnsureDirs().
LOCAL vehicleInfo IS bootVehicleInfo().
LOCAL isEVA IS vehicleInfo["IS_EVA"].
LOCAL vehicleName IS vehicleInfo["VEHICLE"].
LOCAL targetName IS vehicleInfo["TARGET"].
LOCAL payloadTypes IS vehicleInfo["PAYLOADS"].

IF bootShouldResetMissionOnBoot(isEVA) {
    bootResetMissionSelection(vehicleName, targetName, payloadTypes).
}

LOCAL bootCount IS stateGetNum("boot_count", 0) + 1.
stateSet("boot_count", bootCount).
IF bootCount = 1 {
    stateSet("vehicle",  vehicleName).
    stateSet("target",   targetName).
    stateSet("payloads", payloadTypes:JOIN(",")).
}

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
    bootCleanup(cleanupVehicle, vehicleLibs).
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
printStorageStatus().
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
LOCAL skipTailSolar IS FALSE.
LOCAL tailSolarPhase IS stateGet("phase", "").
LOCAL tailSolarBand IS stateGet("lib_band", "").
IF tailSolarPhase = "LAND" OR tailSolarPhase = "LAND_ASSIST"
        OR tailSolarPhase = "LAND_DEORBIT"
        OR tailSolarPhase = "AEROBRAKE"
        OR tailSolarPhase = "DESCENT"
        OR tailSolarBand = "LANDING"
        OR tailSolarBand = "LAND_DEORBIT"
        OR tailSolarBand = "AEROBRAKE" {
    SET skipTailSolar TO TRUE.
}
IF HOMECONNECTION:ISCONNECTED AND NOT skipTailSolar
        AND EXISTS("0:/cmd/orientForSolar.ks") {
    RUNPATH("0:/cmd/orientForSolar.ks").
}
PRINT "END OF LINE. GODSPEED.".
UNLOCK ALL.
SET SAS TO TRUE.
