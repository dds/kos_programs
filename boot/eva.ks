// ============================================================
// eva.ks  —  EVA kerbal boot  (0:/boot/eva.ks)
// ============================================================

CLEARSCREEN.
PRINT " ".
PRINT "  *  kOS EVA COMPUTER  v1.0".
PRINT "  *  " + SHIP:NAME.
PRINT " ".

LOCAL FUNCTION ensureDir { PARAMETER p. IF NOT EXISTS(p) { CREATEDIR(p). } }
ensureDir("1:/lib").
ensureDir("1:/logs").
ensureDir("1:/state").
ensureDir("1:/roles").

LOCAL FUNCTION _syncLib {
    PARAMETER libName.
    COPYPATH("0:/lib/" + libName + ".ks", "1:/lib/" + libName + ".ks").
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
    stateSet("vehicle",  "EVA").
    stateSet("target",   SHIP:BODY:NAME:TOUPPER).
    stateSet("payloads", "").
}
mLog("=== EVA BOOT #" + bootCount + " === " + SHIP:NAME + " ===").

LOCAL evaScript IS "".
IF EXISTS("0:/roles/EVA.ks") { SET evaScript TO "roles/EVA". }
ELSE IF EXISTS("0:/EVA.ks") { SET evaScript TO "EVA". }
ELSE {
    PRINT "  !! EVA.ks NOT FOUND".
    PRINT "  SYSTEM HALTED.".
    mLogError("No EVA.ks found in roles/ or root.").
    WAIT UNTIL FALSE.
}

PRINT "  SYNC " + evaScript + " ....... ".
COPYPATH("0:/" + evaScript + ".ks", "1:/" + evaScript + ".ks").
RUNPATH("1:/" + evaScript + ".ks").

PRINT "  SYNC libs ......... ".
FOR lib IN LIBS { _syncLib(lib). }
FOR lib IN LIBS { _loadLib(lib). }

_syncLib("resume").
_loadLib("resume").

PRINT " ".
PRINT "  EVA BOOT #" + bootCount + " OK".
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
    PRINT " ".
    PRINT "  MANUAL MODE".
    mLog("Manual override at EVA boot.").
} ELSE {
    LOCAL phase IS stateGet("phase", "").
    IF phase = "DONE" {
        PRINT " ".
        PRINT "  EVA COMPLETE. MANUAL MODE.".
        mLog("Reboot after DONE — manual mode.").
    } ELSE {
        PRINT "  RESUMING >> " + phase.
        mLog("Resuming EVA from phase: " + phase).
        resumeMission().
    }
}
