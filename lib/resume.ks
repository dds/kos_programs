// ============================================================
// resume.ks  —  MISSION lexicon + operator helpers
// (0:/lib/resume.ks)
// ============================================================

GLOBAL MISSION IS LEXICON(
    "vehicle",  stateGet("vehicle",  "UNKNOWN"),
    "target",   stateGet("target",   "UNKNOWN"),
    "payloads", stateGet("payloads", "")
).

mLog("MISSION vehicle=" + MISSION["vehicle"]
    + "  target=" + MISSION["target"]
    + "  payloads=" + MISSION["payloads"]).

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

GLOBAL FUNCTION resumeMission {
    LOCAL phase IS stateGet("phase", "none").
    mLog("Resuming " + MISSION["vehicle"] + " from phase: " + phase).
    PRINT "Resuming " + MISSION["vehicle"] + " — phase: " + phase.
    main().
}

GLOBAL FUNCTION setState {
    PARAMETER s.
    stateSet("phase", s).
    PRINT "Phase -> " + s.
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
