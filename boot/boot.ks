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

LOCAL FUNCTION _syncLibText {
    PARAMETER fileName.
    IF NOT HAS_LINK { RETURN. }
    LOCAL src IS "0:/lib/" + fileName.
    LOCAL dst IS "1:/lib/" + fileName.
    IF EXISTS(src) {
        COPYPATH(src, dst).
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
    _syncLibText("dependencies.txt").
    IF EXISTS("0:/VERSION") {
        COPYPATH("0:/VERSION", "1:/run/code_version.state").
    }
} ELSE {
    PRINT "  LOAD core (cached) . ".
}

_loadLib("boot_lib").
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
stateSetNum("boot_count", bootCount).
IF bootCount = 1 {
    stateSet("vehicle",  vehicleName).
    stateSet("target",   targetName).
    stateSet("payloads", payloadTypes:JOIN(",")).
}

LOCAL vehicleScript IS "".
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
    PRINT "  SYNC Zombie ........".
    IF EXISTS("0:/cmd/zombie.ks") { COPYPATH("0:/cmd/zombie.ks", "1:/zombie"). }
    IF vehicleScript <> "" {
        PRINT "  SYNC " + vehicleScript + " ....... ".
        bootSyncScript(vehicleScript, HAS_LINK).
        bootMissionConfig(vehicleName, HAS_LINK).
    }
}


IF vehicleScript <> "" {
    bootRunScript(vehicleScript).
}

LOCAL vehicleLibs IS LIST().
IF vehicleScript <> "" {
    SET vehicleLibs TO bootVehicleLibs().
}

IF DEFINED BOOT_CLEANUP {
    LOCAL cleanupVehicle IS BOOT_CLEANUP["vehicle"].
    LOCAL cleanupCmds IS LIST().
    IF BOOT_CLEANUP:HASKEY("keepCmds") { SET cleanupCmds TO BOOT_CLEANUP["keepCmds"]. }
    bootCleanup(cleanupVehicle, vehicleLibs, cleanupCmds).
}

IF HAS_LINK {
    PRINT "  SYNC libs ......... ".
    bootPruneLibs(vehicleLibs).
    bootLibLoadList(vehicleLibs).
    bootCmdSync().
    bootLibLoad("resume").
    // Recovery is loaded only at startup/abort or after manual mode.
    LOCAL phase_ IS stateGet("phase", "").
    IF phase_ = "" OR phase_ = "ABORT" {
        bootLibLoad("recovery").
    }
} ELSE {
    PRINT "  NO LINK: Bypassing library sync.".
    bootLibLoadList(vehicleLibs).
    bootLibLoad("resume").
}

PRINT " ".
PRINT "  BOOT #" + bootCount + " OK".
printStorageStatus().
IF HAS_LINK { archiveLog(). }
IF stateGet("phase", "") = "ABORT" { bootLibLoad("recovery"). }

bootResumeOrManual(HAS_LINK).
IF HAS_LINK {
    bootLibLoad("recovery").
}
PRINT "END OF LINE. GODSPEED.".
UNLOCK ALL.
SET SAS TO TRUE.
