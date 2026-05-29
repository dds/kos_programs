// ============================================================
// boot.ks  —  Generic mission boot  (0:/boot/boot.ks)
// ============================================================

CLEARSCREEN.
PRINT "=== BOOT: " + SHIP:NAME + " ===".

LOCAL rawTokens IS SHIP:NAME:SPLIT("-").
LOCAL tokens IS LIST().
FOR t IN rawTokens {
    LOCAL trimmed IS t:TRIM.
    IF trimmed <> "" { tokens:ADD(trimmed). }
}
IF tokens:LENGTH < 2 {
    PRINT "BOOT ERROR: name must be VEHICLE-TARGET[-TYPE...]".
    PRINT "Got: " + SHIP:NAME.
    WAIT UNTIL FALSE.
}
LOCAL vehicleName IS tokens[0].
LOCAL targetName  IS tokens[1]:TOUPPER.
LOCAL payloadTypes IS LIST().
LOCAL idx IS 2.
UNTIL idx >= tokens:LENGTH {
    payloadTypes:ADD(tokens[idx]:TOUPPER).
    SET idx TO idx + 1.
}

LOCAL FUNCTION ensureDir { PARAMETER p. IF NOT EXISTS(p) { CREATEDIR(p). } }
ensureDir("1:/lib").
ensureDir("1:/boot").
ensureDir("1:/logs").
ensureDir("1:/state").
ensureDir("1:/cmd").

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

PRINT "Syncing core libs...".
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

PRINT "Syncing vehicle script...".
COPYPATH("0:/" + vehicleName + ".ks", "1:/" + vehicleName + ".ks").
RUNPATH("1:/" + vehicleName + ".ks").

PRINT "Syncing mission libs...".
FOR lib IN LIBS { _syncLib(lib). }
FOR lib IN LIBS { _loadLib(lib). }

_syncLib("resume").
_loadLib("resume").

PRINT "Sync complete.".
printStorageStatus().

PRINT " ".
PRINT "Press any key within 5s for manual mode...".
LOCAL overrideStart IS TIME:SECONDS.
LOCAL manualMode IS FALSE.
WAIT UNTIL TIME:SECONDS > overrideStart + 5 OR TERMINAL:INPUT:HASCHAR.
IF TERMINAL:INPUT:HASCHAR {
    TERMINAL:INPUT:GETCHAR().
    SET manualMode TO TRUE.
}

IF manualMode {
    PRINT "Manual mode — type resumeMission(). to continue.".
    mLog("Manual override at boot.").
    UNLOCK ALL.
    SET SAS TO TRUE.
} ELSE {
    PRINT "Auto-resuming...".
    LOCAL phase IS stateGet("phase", "").
    IF phase = "DONE" {
        PRINT "Mission complete. Manual mode.".
        mLog("Reboot after DONE — manual mode.").
        UNLOCK ALL.
        SET SAS TO TRUE.
    } ELSE {
        mLog("Resuming mission from phase: " + phase).
        resumeMission().
    }
}
