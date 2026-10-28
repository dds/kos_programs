// ============================================================
// config.ks  —  Mission override and phase sequence utilities
// (0:/lib/config.ks)
//
// Config is executable KerboScript: mission profiles and craft
// scripts SET global variables, and libraries read those globals
// directly. Defaults live in the files that own the behavior.

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

// ============================================================
GLOBAL FUNCTION configLiteral {
    PARAMETER raw.
    IF raw:ISTYPE("Scalar") { RETURN raw. }
    IF raw:ISTYPE("Boolean") {
        IF raw { RETURN "TRUE". }
        RETURN "FALSE".
    }
    IF raw:ISTYPE("List") {
        LOCAL parts IS LIST().
        FOR item IN raw {
            parts:ADD(configLiteral(item)).
        }
        RETURN "LIST(" + parts:JOIN(", ") + ")".
    }
    RETURN CHAR(34) + raw + CHAR(34).
}

GLOBAL FUNCTION missionOverridePath {
    IF NOT EXISTS("1:/run") { CREATEDIR("1:/run"). }
    RETURN "1:/run/mission_overrides.ks".
}

GLOBAL FUNCTION missionOverrideClear {
    LOCAL overridePath IS "1:/run/mission_overrides.ks".
    IF EXISTS(overridePath) { DELETEPATH(overridePath). }
}

// Rewrite the current override set, replacing only supplied SET keys.
// Stage the whole file first so unrelated mission/return intent survives.
GLOBAL FUNCTION missionOverrideUpdate {
    PARAMETER values.
    LOCAL previous IS LIST().
    LOCAL path IS missionOverridePath().
    IF EXISTS(path) { SET previous TO OPEN(path):READALL:STRING:SPLIT(CHAR(10)). }
    LOCAL rewritten IS "1:/run/updated_overrides.ks".
    IF EXISTS(rewritten) { DELETEPATH(rewritten). }
    FOR line IN previous {
        LOCAL keep IS TRUE.
        FOR key IN values:KEYS {
            IF line:TRIM:STARTSWITH("SET " + key + " TO ") { SET keep TO FALSE. }
        }
        IF keep AND line:TRIM <> "" { LOG line TO rewritten. }
    }
    FOR key IN values:KEYS {
        LOG "SET " + key + " TO " + configLiteral(values[key]) + "." TO rewritten.
    }
    COPYPATH(rewritten, path).
    DELETEPATH(rewritten).
}

GLOBAL FUNCTION applyMissionOverrides {
    LOCAL overridePath IS missionOverridePath().
    IF EXISTS(overridePath) { RUNPATH(overridePath). }
}

GLOBAL FUNCTION applyKnownMissionState {
    applyMissionOverrides().
}

GLOBAL FUNCTION missionProfilePath {
    PARAMETER cn.
    PARAMETER mid.
    IF cn = "" {
        mLogError("missionProfilePath: empty vehicle name — refusing to "
            + "write " + mid + " profile to the missions root.").
        RETURN "".
    }
    IF NOT EXISTS("1:/missions") { CREATEDIR("1:/missions"). }
    LOCAL dir IS "1:/missions/" + cn.
    IF NOT EXISTS(dir) { CREATEDIR(dir). }
    RETURN dir + "/" + mid + ".ks".
}

GLOBAL FUNCTION missionProfileBegin {
    PARAMETER cn.
    PARAMETER mid.
    LOCAL path IS missionProfilePath(cn, mid).
    IF path = "" { RETURN "". }
    // A newly generated source profile supersedes any old cached bytecode.
    LOCAL compiled IS path:SUBSTRING(0,path:LENGTH-3) + ".ksm".
    IF EXISTS(compiled) { DELETEPATH(compiled). }
    IF EXISTS(path) { DELETEPATH(path). }
    RETURN path.
}

GLOBAL FUNCTION phaseList {
    PARAMETER seq.
    IF seq:LENGTH = 0 { RETURN LIST("DONE"). }
    RETURN phaseSequenceEnsurePrelaunch(seq).
}

GLOBAL FUNCTION phaseNeedsPrelaunch {
    PARAMETER phaseName.
    // HOP owns its own settled-surface, budget, attitude and cutoff checks;
    // it must not inherit a departure-plane setup from the original flight.
    RETURN phaseName = "LAUNCH".
}

GLOBAL FUNCTION phaseSequenceEnsurePrelaunch {
    PARAMETER seq.
    LOCAL out IS LIST().
    FOR phaseName IN seq {
        IF phaseNeedsPrelaunch(phaseName) {
            LOCAL previous IS "".
            IF out:LENGTH > 0 { SET previous TO out[out:LENGTH - 1]. }
            IF previous <> "PRELAUNCH" { out:ADD("PRELAUNCH"). }
        }
        out:ADD(phaseName).
    }
    RETURN out.
}
