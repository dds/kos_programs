// ============================================================
// boot.ks  —  Generic mission boot  (0:/boot/boot.ks)
// ============================================================

CORE:DOACTION("Open Terminal", TRUE).
CLEARSCREEN.
PRINT " ".
PRINT "  *  kOS FLIGHT COMPUTER  v2.0".
PRINT "  *  " + SHIP:NAME.
PRINT "  *  KSC UPLINK ACTIVE".
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

LOCAL FUNCTION _resolveScript {
    PARAMETER name.
    PARAMETER dirs.
    FOR d IN dirs {
        IF EXISTS("0:/" + d + "/" + name + ".ks") { RETURN d + "/" + name. }
    }
    IF EXISTS("0:/" + name + ".ks") { RETURN name. }
    RETURN "".
}

LOCAL FUNCTION _syncLib {
    PARAMETER libName.
    LOCAL src IS "0:/lib/" + libName + ".ks".
    LOCAL dst IS "1:/lib/" + libName + ".ks".
    COPYPATH(src, dst).
}

LOCAL FUNCTION _loadLib {
    PARAMETER libName.
    RUNPATH("1:/lib/" + libName + ".ks").
}

PRINT "  SYNC core ......... ".
LOCAL coreLibs IS LIST("state", "logs", "files").
FOR lib IN coreLibs { _syncLib(lib). }

_loadLib("state").
stateInit().
_loadLib("logs").
initLog().
_loadLib("files").

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
} ELSE {
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

PRINT "  SYNC Zombie ........".
COPYPATH("0:/cmd/zombie.ks", "1:/zombie").

PRINT "  SYNC " + vehicleScript + " ....... ".
COPYPATH("0:/" + vehicleScript + ".ks", "1:/" + vehicleScript + ".ks").
RUNPATH("1:/" + vehicleScript + ".ks").

PRINT "  SYNC libs ......... ".
FOR lib IN LIBS { _syncLib(lib). }
FOR lib IN LIBS { _loadLib(lib). }

_syncLib("resume").
_loadLib("resume").

PRINT " ".
PRINT "  BOOT #" + bootCount + " OK".
printStorageStatus().

PRINT " ".
PRINT "  >> Press any key for MANUAL mode (5s)".
LOCAL overrideStart IS TIME:SECONDS.
LOCAL manualMode IS FALSE.
WAIT UNTIL TIME:SECONDS > overrideStart + 5 OR TERMINAL:INPUT:HASCHAR.
IF TERMINAL:INPUT:HASCHAR {
    TERMINAL:INPUT:GETCHAR().
    SET manualMode TO TRUE.
}

IF manualMode {
    CLEARSCREEN.
    PRINT "  ========================================".
    PRINT "  MANUAL MODE    " + SHIP:NAME.
    PRINT "  ========================================".
    PRINT " ".
    PRINT "  -- ENVIRONMENT --".
    PRINT "  Body ........ " + SHIP:ORBIT:BODY:NAME.
    PRINT "  Status ...... " + SHIP:STATUS.
    PRINT "  Altitude .... " + ROUND(SHIP:ALTITUDE,0) + " m".
    IF SHIP:STATUS = "FLYING" OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "PRELAUNCH" {
        PRINT "  Airspeed .... " + ROUND(SHIP:AIRSPEED,1) + " m/s".
        PRINT "  Ground spd .. " + ROUND(SHIP:VELOCITY:SURFACE:MAG,1) + " m/s".
        PRINT "  Heading ..... " + ROUND(SHIP:FACING:YAW,1) + " deg".
        PRINT "  Latitude .... " + ROUND(SHIP:GEOPOSITION:LAT,4).
        PRINT "  Longitude ... " + ROUND(SHIP:GEOPOSITION:LNG,4).
    }
    IF SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "SUB_ORBITAL" {
        PRINT "  Apoapsis .... " + ROUND(SHIP:APOAPSIS/1000,1) + " km".
        PRINT "  Periapsis ... " + ROUND(SHIP:PERIAPSIS/1000,1) + " km".
        PRINT "  Inclination . " + ROUND(SHIP:ORBIT:INCLINATION,2) + " deg".
    }
    PRINT "  KSC link .... " + HOMECONNECTION:ISCONNECTED.
    PRINT "  Free space .. " + CORE:VOLUME:FREESPACE + " / " + CORE:VOLUME:CAPACITY + " bytes".
    PRINT " ".
    PRINT "  -- MISSION --".
    PRINT "  Vehicle ..... " + vehicleName.
    PRINT "  Target ...... " + targetName.
    LOCAL phase IS stateGet("phase", "(none)").
    PRINT "  Phase ....... " + phase.
    PRINT "  Boot # ...... " + bootCount.
    IF DEFINED planeActive {
        PRINT " ".
        PRINT "  -- PLANE --".
        PRINT "  Stall speed . " + PLANE_CFG["STALL_SPEED"] + " m/s".
        PRINT "  FBW ref spd . " + PLANE_CFG["FBW_REF_SPEED"] + " m/s".
        PRINT "  Cruise alt .. " + CFG["CRUISE_ALT"] + " m".
        PRINT "  Cruise spd .. " + CFG["CRUISE_SPEED"] + " m/s".
    }
    IF DEFINED obsActive {
        PRINT " ".
        PRINT "  -- OBSERVATION --".
        IF obsActive {
            PRINT "  Status ...... ACTIVE".
        } ELSE {
            PRINT "  Status ...... OFF".
        }
        PRINT "  Interval .... " + OBS_CFG["INTERVAL"] + "s".
        PRINT "  Min free .... " + OBS_CFG["MIN_FREE"] + " bytes".
    }
    PRINT " ".
    PRINT "  -- LOGS --".
    IF DEFINED flightLogPath {
        PRINT "  Flight log .. " + flightLogPath.
    }
    PRINT " ".
    PRINT "  ========================================".
    mLog("Manual override at boot.").
    UNLOCK ALL.
    SET SAS TO TRUE.
} ELSE {
    LOCAL phase IS stateGet("phase", "").
    IF phase = "DONE" {
        PRINT " ".
        PRINT "  MISSION COMPLETE. MANUAL MODE.".
        mLog("Reboot after DONE — manual mode.").
        UNLOCK ALL.
        SET SAS TO TRUE.
    } ELSE IF phase = "ABORT" {
        PRINT "  ABORT DETECTED — entering recovery mode.".
        mLog("Abort detected at reboot — loading recovery.").
        _syncLib("recovery").
        _loadLib("recovery").
        recoveryMode().
    } ELSE {
        PRINT "  RESUMING >> " + phase.
        mLog("Resuming mission from phase: " + phase).
        resumeMission().
    }
}

IF HOMECONNECTION:ISCONNECTED {
    LOCAL launchT IS ROUND(stateGetNum("launch_time", 0)).
    IF launchT = 0 { SET launchT TO ROUND(TIME:SECONDS). }
    LOCAL shipDir IS "0:/logs/archive/" + SHIP:NAME + "_" + launchT.
    IF NOT EXISTS("0:/logs/archive") { CREATEDIR("0:/logs/archive"). }
    IF NOT EXISTS(shipDir) { CREATEDIR(shipDir). }
    COPYPATH(flightLogPath, shipDir + "/" + flightLogPath).
    mLog("Auto-archived " + flightLogPath + " to " + shipDir + ".").
} ELSE {
    PRINT "  No KSC link — " + flightLogPath + " needs manual retrieval".
}

PRINT ("END OF LINE. GODSPEED.").
