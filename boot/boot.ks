// ============================================================
// boot.ks  —  Generic mission boot  (0:/boot/boot.ks)
// ============================================================

CLEARSCREEN.
PRINT " ".
PRINT "  *  kOS FLIGHT COMPUTER  v2.0".
PRINT "  *  " + SHIP:NAME.
PRINT "  *  KSC UPLINK ACTIVE".
PRINT " ".

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
    IF tokens:LENGTH < 2 {
        PRINT "  !! NAME ERROR".
        PRINT "  !! Expected: VEHICLE-TARGET[-TYPE...]".
        PRINT "  !! Got: " + SHIP:NAME.
        PRINT " ".
        PRINT "  SYSTEM HALTED.".
        WAIT UNTIL FALSE.
    }
    SET vehicleName TO tokens[0].
    SET targetName TO tokens[1]:TOUPPER.
    LOCAL idx IS 2.
    UNTIL idx >= tokens:LENGTH {
        payloadTypes:ADD(tokens[idx]:TOUPPER).
        SET idx TO idx + 1.
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
mLog("=== BOOT #" + bootCount + " === " + SHIP:NAME + " ===").

LOCAL vehicleScript IS "".
IF isEVA {
    SET vehicleScript TO _resolveScript("EVA", LIST("roles")).
} ELSE IF CORE:TAG <> "" {
    SET vehicleScript TO _resolveScript(CORE:TAG, LIST("roles", "craft")).
    IF vehicleScript <> "" {
        PRINT "  CORE TAG: " + CORE:TAG + " -> " + vehicleScript + ".ks".
    } ELSE {
        PRINT "  CORE TAG: " + CORE:TAG + " (no script found, trying vehicle).".
        SET vehicleScript TO "".
    }
}
IF vehicleScript = "" {
    SET vehicleScript TO _resolveScript(vehicleName, LIST("craft")).
}
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
    LOCAL dq IS CHAR(34).
    PRINT " ".
    PRINT "  MANUAL MODE".
    PRINT "  Commands (copy into terminal):".
    PRINT "  RUNPATH(" + dq + "1:/cmd/resume.ks" + dq + ").".
    PRINT "  RUNPATH(" + dq + "1:/cmd/setstate.ks" + dq + "," + dq + "PHASE" + dq + ").".
    PRINT "  RUNPATH(" + dq + "1:/cmd/dump.ks" + dq + ").".
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
    } ELSE {
        PRINT "  RESUMING >> " + phase.
        mLog("Resuming mission from phase: " + phase).
        resumeMission().
    }
}
