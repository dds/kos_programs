// ============================================================
// boot.ks  —  Generic mission boot  (0:/boot/boot.ks)
// Shared across ALL vehicles and missions. Never edit.
//
// Ship name format:  VEHICLE-TARGET-TYPE1-TYPE2-...
// e.g.  FR2-MUN-RELAY1-PROBE1
//       FR2-MINMUS-RELAY1
//       FR2-KERBIN-STKSAT1
//
// Parses name → MISSION lexicon, persists to state.json,
// loads VEHICLE.ks as the flight computer.
// ============================================================

CLEARSCREEN.

// ── Parse ship name ────────────────────────────────────────
// Split on "-", trim whitespace from each token.
// Tokens: [0]=vehicle  [1]=target  [2..n]=payload types
LOCAL rawTokens IS SHIP:NAME:SPLIT("-").
LOCAL tokens IS LIST().
FOR t IN rawTokens {
    LOCAL trimmed IS t:TRIM.
    IF trimmed <> "" { tokens:ADD(trimmed). }
}

IF tokens:LENGTH < 2 {
    PRINT "BOOT ERROR: ship name must be VEHICLE-TARGET[-TYPE...]".
    PRINT "Got: " + SHIP:NAME.
    PRINT "Halting.".
    // Can't log yet, state not init'd. Just stop.
    WAIT UNTIL FALSE.
}

LOCAL vehicleName IS tokens[0].           // "FR2"
LOCAL targetName  IS tokens[1]:TOUPPER.   // "MUN"
LOCAL payloadTypes IS LIST().             // ["RELAY1","PROBE1"]
LOCAL i IS 2.
UNTIL i >= tokens:LENGTH {
    payloadTypes:ADD(tokens[i]:TOUPPER).
    SET i TO i + 1.
}

PRINT "=================================".
PRINT " BOOT  —  " + SHIP:NAME.
PRINT " Vehicle : " + vehicleName.
PRINT " Target  : " + targetName.
PRINT " Payloads: " + payloadTypes:JOIN(", ").
PRINT "=================================".

// ── Ensure local dirs ──────────────────────────────────────
LOCAL FUNCTION ensureDir { PARAMETER p. IF NOT EXISTS(p) { CREATEDIR(p). } }
ensureDir("1:/lib").
ensureDir("1:/boot").
ensureDir("1:/logs").
ensureDir("1:/state").

// ── Sync archive → local ───────────────────────────────────
PRINT "Syncing archive...".
COPYPATH("0:/boot/boot.ks",              "1:/boot/boot.ks").
COPYPATH("0:/lib/countdown.ks",          "1:/lib/countdown.ks").
COPYPATH("0:/lib/state.ks",              "1:/lib/state.ks").
COPYPATH("0:/lib/log.ks",                "1:/lib/log.ks").
COPYPATH("0:/lib/maneuver.ks",           "1:/lib/maneuver.ks").
COPYPATH("0:/lib/orbit.ks",              "1:/lib/orbit.ks").
COPYPATH("0:/lib/files.ks",              "1:/lib/files.ks").
COPYPATH("0:/" + vehicleName + ".ks",    "1:/" + vehicleName + ".ks").
PRINT "Sync complete.".

// ── Load libs ──────────────────────────────────────────────
RUNPATH("1:/lib/countdown.ks").
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/log.ks").
initLog().
RUNPATH("1:/lib/maneuver.ks").
RUNPATH("1:/lib/orbit.ks").
RUNPATH("1:/lib/files.ks").

// ── Persist parsed mission descriptor ─────────────────────
// Only write on first boot — preserve existing state on reboot.
// Operator can override via setState() in manual mode.
LOCAL bootCount IS stateGetNum("boot_count", 0) + 1.
stateSetNum("boot_count", bootCount).

IF bootCount = 1 {
    stateSet("vehicle",  vehicleName).
    stateSet("target",   targetName).
    stateSet("payloads", payloadTypes:JOIN(",")).
    // phase not set here — vehicle script sets it on first run
}

mLog("=== BOOT #" + bootCount + " === " + SHIP:NAME + " ===").
mLog("vehicle=" + vehicleName + "  target=" + targetName + "  payloads=" + payloadTypes:JOIN(",")).

// ── Expose MISSION lexicon for vehicle script ──────────────
// Rebuilt from state each boot so it's always consistent.
GLOBAL MISSION IS LEXICON(
    "vehicle",  stateGet("vehicle",  vehicleName),
    "target",   stateGet("target",   targetName),
    "payloads", stateGet("payloads", payloadTypes:JOIN(","))
).

// Helper: get payload list as a LIST()
GLOBAL FUNCTION missionPayloads {
    RETURN MISSION["payloads"]:SPLIT(",").
}

// Helper: check if a payload type is in this mission
GLOBAL FUNCTION missionHas {
    PARAMETER typeStr.
    FOR p IN missionPayloads() {
        IF p:TOUPPER = typeStr:TOUPPER { RETURN TRUE. }
    }
    RETURN FALSE.
}

// Helper: resolve target name string → body object
// Handles Kerbin system bodies. Extend as needed.
GLOBAL FUNCTION missionTargetBody {
    LOCAL t IS MISSION["target"]:TOUPPER.
    IF t = "MUN"    { RETURN MUN.    }
    IF t = "MINMUS" { RETURN MINMUS. }
    IF t = "KERBIN" { RETURN KERBIN. }
    IF t = "KERBOL" { RETURN SUN.    }
    // Fallback: try BODY() lookup
    RETURN BODY(MISSION["target"]).
}

mLog("MISSION: " + MISSION:KEYS:JOIN(", ")).

// ── Boot mode ──────────────────────────────────────────────
IF bootCount >= 2 {
    PRINT " ".
    PRINT "*** MANUAL / RECOVERY MODE ***".
    PRINT "Available helpers:".
    PRINT "  stateDump()                   show all state".
    PRINT "  setState('PHASE')              force phase".
    PRINT "  resetBootCount()              re-arm auto".
    PRINT "  patchAndRun('0:/FR2.ks')      hotpatch script".
    PRINT "  resumeMission()               resume from saved phase".
    PRINT "  printStorageStatus()          disk usage".
    PRINT " ".
    mLog("Manual mode. Boot #" + bootCount + ". Phase: " + stateGet("phase","NONE")).
    UNLOCK ALL.
    SET SAS TO TRUE.
} ELSE {
    PRINT "First boot — auto sequence.".
    mLog("Auto start.").
    RUNPATH("1:/" + vehicleName + ".ks").
    main().
}

// ── Manual mode helpers ────────────────────────────────────

GLOBAL FUNCTION resetBootCount {
    stateSetNum("boot_count", 0).
    PRINT "Boot count reset. Reboot to re-arm auto.".
    mLog("Boot count reset.").
}

GLOBAL FUNCTION setState {
    PARAMETER s.
    stateSet("phase", s).
    PRINT "Phase → " + s.
    mLog("Phase forced: " + s).
}

GLOBAL FUNCTION resumeMission {
    LOCAL v IS stateGet("vehicle", vehicleName).
    mLog("Resuming " + v + " from phase: " + stateGet("phase","NONE")).
    RUNPATH("1:/" + v + ".ks").
    main().
}

GLOBAL FUNCTION patchAndRun {
    PARAMETER archivePath.
    PRINT "Patching: " + archivePath.
    COPYPATH(archivePath, "1:/patched.ks").
    RUNPATH("1:/patched.ks").
    mLog("Patch loaded: " + archivePath).
}