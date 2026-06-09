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
        IF p = typeStr { RETURN TRUE. }
    }
    RETURN FALSE.
}

GLOBAL FUNCTION missionTargetBody {
    LOCAL t IS MISSION["target"].
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
    IF DEFINED vehicleMain {
        vehicleMain:CALL().
        RETURN.
    }
    IF DEFINED main {
        main().
        RETURN.
    }
    mLogError("Cannot resume: vehicle main() is not loaded. Check craft name, CORE:TAG, and archive sync.").
    PRINT " ".
    PRINT "  RESUME HOLD".
    PRINT "  Vehicle main() is not loaded.".
    PRINT "  Check craft name, CORE:TAG, and archive sync.".
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

GLOBAL FUNCTION normalizePayloadType {
    PARAMETER raw.
    LOCAL result IS raw.
    UNTIL result:LENGTH = 0 {
        LOCAL last IS result:SUBSTRING(result:LENGTH - 1, 1).
        IF last:MATCHESPATTERN("[0-9]") OR last = "-" {
            SET result TO result:SUBSTRING(0, result:LENGTH - 1).
        } ELSE {
            BREAK.
        }
    }
    RETURN result.
}

GLOBAL FUNCTION buildRocketSequence {
    PARAMETER orbitPhases.
    PARAMETER payloadPhases.
    LOCAL seq IS LIST("LAUNCH", "FAIR", "ANTS", "PARK").
    LOCAL needsRdv IS FALSE.
    IF CFG:HASKEY("RENDEZVOUS_TARGET") { SET needsRdv TO TRUE. }
    IF CFG:HASKEY("ASTEROID_TARGET") { SET needsRdv TO TRUE. }
    IF needsRdv { seq:ADD("RDV"). }
    IF MISSION["target"] <> "KERBIN" {
        seq:ADD("XING").
        seq:ADD("MCC").
        seq:ADD("COAST").
        seq:ADD("CAPTURE").
    }
    FOR p IN orbitPhases { seq:ADD(p). }
    FOR ptype IN missionPayloads() {
        LOCAL t IS normalizePayloadType(ptype).
        IF payloadPhases:HASKEY(t) {
            FOR phaseName IN payloadPhases[t] { seq:ADD(phaseName). }
        }
    }
    seq:ADD("DONE").
    RETURN seq.
}

GLOBAL FUNCTION patchAndRun {
    PARAMETER archivePath.
    PRINT "Patching: " + archivePath.
    COPYPATH(archivePath, "1:/patched.ks").
    RUNPATH("1:/patched.ks").
    mLog("Patch loaded: " + archivePath).
}
