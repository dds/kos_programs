CLEARSCREEN.

LOCAL missionName IS "".
LOCAL i IS 0.
UNTIL i >= SHIP:NAME:LENGTH {
    LOCAL c IS SHIP:NAME:SUBSTRING(i,1).
    IF c:MATCHESPATTERN("\\w") { SET missionName TO missionName + c. }
    ELSE { BREAK. }
    SET i TO i + 1.
}
IF missionName = "" { SET missionName TO "JUST_LIBS". }

PRINT "=================================".
PRINT " BOOT  —  " + missionName.
PRINT "=================================".

LOCAL FUNCTION ensureDir { PARAMETER p. IF NOT EXISTS(p) { CREATEDIR(p). } }
FOR dir IN LIST("lib", "boot", "logs", "state") {
    ensureDir("1:/{0}":FORMAT(dir)).
}.

PRINT "Syncing archive...".
COPYPATH("0:/lib/state.ks",          "1:/lib/state.ks").
COPYPATH("0:/lib/logs.ks",            "1:/lib/logs.ks").
COPYPATH("0:/lib/maneuver.ks",       "1:/lib/maneuver.ks").
COPYPATH("0:/lib/orbit.ks",          "1:/lib/orbit.ks").
COPYPATH("0:/" + missionName + ".ks","1:/" + missionName + ".ks").
PRINT "Sync complete.".

// ── Load libs (order matters: state before log) ────────────
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/log.ks").
initLog().
RUNPATH("1:/lib/maneuver.ks").
RUNPATH("1:/lib/orbit.ks").

LOCAL bootCount IS stateGetNum("boot_count", 0) + 1.
stateSetNum("boot_count", bootCount).
mLog("=== BOOT #" + bootCount + " === " + missionName + " ===").
PRINT "Boot #" + bootCount.

IF bootCount >= 2 {
    PRINT " ".
    PRINT "*** MANUAL / RECOVERY MODE ***".
    PRINT "All locks released. Available helpers:".
    PRINT "  stateDump()               -- show all persisted state".
    PRINT "  setState('PHASE')         -- force mission phase".
    PRINT "  resetBootCount()          -- re-arm auto on next reboot".
    PRINT "  patch('FR2')              -- upload + hotpatch script".
    PRINT "  resumeMission()           -- resume from saved phase".
    PRINT " ".
    mLog("Manual/recovery mode. Boot #" + bootCount + ". Phase was: " + stateGet("phase","NONE")).
    UNLOCK ALL.
    SET SAS TO TRUE.
    // Operator drives from here.
} ELSE {
    PRINT "First boot — starting auto sequence.".
    mLog("Auto sequence start.").
    RUNPATH("1:/" + missionName + ".ks").
    main().
}

// ── Manual-mode helpers ────────────────────────────────────

GLOBAL FUNCTION resetBootCount {
    stateSetNum("boot_count", 0).
    PRINT "Boot count reset. Reboot to re-arm auto mode.".
    mLog("Boot count reset by operator.").
}

GLOBAL FUNCTION setState {
    PARAMETER s.
    stateSet("phase", s).
    PRINT "Phase forced to: " + s.
    mLog("Phase manually forced to: " + s).
}

GLOBAL FUNCTION resumeMission {
    RUNPATH("1:/" + missionName + ".ks").
    mLog("Resuming mission from phase: " + stateGet("phase","NONE")).
    main().
}

GLOBAL FUNCTION patch {
    PARAMETER aPath.
    LOCAL archivePath IS "0:/{0}.ks":FORMAT(aPath).
    PRINT "Patching from: " + archivePath.
    COPYPATH(archivePath, "1:/patched.ks").
    RUNPATH("1:/patched.ks").
    mLog("Patch loaded: " + archivePath).
}