// ============================================================
// resume.ks  —  Mission resume + manual mode  (0:/lib/resume.ks)
//
// Loaded at end of every boot. Owns:
//   - MISSION lexicon + helpers
//   - Auto-resume vs manual mode decision
//   - All operator-facing helper functions
//
// Patchable mid-mission via:
//   COPYPATH("0:/lib/resume.ks", "1:/lib/resume.ks").
//   RUNPATH("1:/lib/resume.ks").
// ============================================================

// ── MISSION lexicon ────────────────────────────────────────
// Rebuilt from state every boot — always consistent.
GLOBAL MISSION IS LEXICON(
    "vehicle",  stateGet("vehicle",  "UNKNOWN"),
    "target",   stateGet("target",   "UNKNOWN"),
    "payloads", stateGet("payloads", "")
).

mLog("MISSION vehicle=" + MISSION["vehicle"]
    + "  target=" + MISSION["target"]
    + "  payloads=" + MISSION["payloads"]).

// ── MISSION helpers ────────────────────────────────────────

GLOBAL FUNCTION missionPayloads {
    IF MISSION["payloads"] = "" { RETURN LIST(). }
    RETURN MISSION["payloads"]:SPLIT(",").
}

GLOBAL FUNCTION missionHas {
    PARAMETER typeStr.
    FOR p IN missionPayloads() {
        IF p:TOUPPER = typeStr:TOUPPER { RETURN TRUE. }
    }
    RETURN FALSE.
}

GLOBAL FUNCTION missionTargetBody {
    LOCAL t IS MISSION["target"]:TOUPPER.
    IF t = "MUN"    { RETURN MUN.    }
    IF t = "MINMUS" { RETURN MINMUS. }
    IF t = "KERBIN" { RETURN KERBIN. }
    IF t = "KERBOL" { RETURN SUN.    }
    RETURN BODY(MISSION["target"]).
}

// ── Operator helpers ───────────────────────────────────────

GLOBAL FUNCTION resumeMission {
    LOCAL vName IS stateGet("vehicle", "FR2").
    LOCAL phase IS stateGet("phase", "none").
    mLog("Resuming " + vName + " from phase: " + phase).
    PRINT "Resuming " + vName + " — phase: " + phase.
    RUNPATH("1:/" + vName + ".ks").
    main().
}

GLOBAL FUNCTION setState {
    PARAMETER s.
    stateSet("phase", s).
    PRINT "Phase → " + s.
    mLog("Phase forced: " + s).
}

GLOBAL FUNCTION resetBootCount {
    stateSetNum("boot_count", 0).
    PRINT "Boot count reset. Reboot to re-arm auto.".
    mLog("Boot count reset.").
}

GLOBAL FUNCTION patchAndRun {
    PARAMETER archivePath.
    PRINT "Patching: " + archivePath.
    COPYPATH(archivePath, "1:/patched.ks").
    RUNPATH("1:/patched.ks").
    mLog("Patch loaded: " + archivePath).
}

// ── Auto-resume vs manual mode ─────────────────────────────

LOCAL bootCount IS stateGetNum("boot_count", 1).
LOCAL phase     IS stateGet("phase", "").

IF phase = "" {
    // No phase saved — something wrong, drop to manual
    PRINT " ".
    PRINT "*** MANUAL MODE — no saved phase ***".
    PRINT "Check stateDump() and setState() to recover.".
    mLog("Manual mode — no phase in state.").
    UNLOCK ALL.
    SET SAS TO TRUE.
} ELSE IF phase = "DONE" {
    // Mission complete
    PRINT " ".
    PRINT "Mission already complete. Manual mode.".
    mLog("Reboot after DONE — manual mode.").
    UNLOCK ALL.
    SET SAS TO TRUE.
} ELSE {
    mLog("Resuming mission from phase: " + phase).
    resumeMission().
}
