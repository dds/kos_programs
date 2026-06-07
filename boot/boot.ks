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

LOCAL FUNCTION _syncMissionConfigs {
    PARAMETER craftName.
    IF NOT HAS_LINK { RETURN. }
    LOCAL srcDir IS "0:/missions/" + craftName.
    IF NOT EXISTS(srcDir) { RETURN. }

    LOCAL dstDir IS "1:/missions/" + craftName.
    ensureDir(dstDir).

    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(srcDir).
    LIST FILES IN items.
    CD(startPath).

    FOR item IN items {
        IF item:ISFILE {
            COPYPATH(srcDir + "/" + item:NAME, dstDir + "/" + item:NAME).
        }
    }
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
    IF EXISTS("0:/" + vehicleScript + ".ks") {
        COPYPATH("0:/" + vehicleScript + ".ks", "1:/" + vehicleScript + ".ks").
    }
    _syncMissionConfigs(vehicleName).
}

// 1. Run the vehicle script first so it can define the LIBS global variable
RUNPATH("1:/" + vehicleScript + ".ks").

// 2. Now that LIBS exists, sync them if we have a connection
IF HAS_LINK {
    PRINT "  SYNC libs ......... ".
    IF DEFINED LIBS {
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
