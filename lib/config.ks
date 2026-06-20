// ============================================================
// config.ks  —  Mission override and phase sequence utilities
// (0:/lib/config.ks)
//
// Config is executable KerboScript: mission profiles and craft
// scripts SET global variables, and libraries read those globals
// directly. Defaults live in the files that own the behavior.
// ============================================================
GLOBAL FUNCTION configLiteral {
    PARAMETER raw.
    IF raw:ISTYPE("Scalar") { RETURN raw. }
    IF raw:ISTYPE("List") {
        LOCAL parts IS LIST().
        FOR item IN raw {
            parts:ADD(configLiteral(item)).
        }
        RETURN "LIST(" + parts:JOIN(", ") + ")".
    }
    RETURN CHAR(34) + raw + CHAR(34).
}

GLOBAL FUNCTION applyKnownMissionState {
    LOCAL overridePath IS "1:/run/mission_cfg_overrides.ks".
    IF EXISTS(overridePath) { DELETEPATH(overridePath). }
    LOCAL wrote IS FALSE.
    FOR sk IN stateKeys() {
        IF sk:LENGTH > 12 AND sk:SUBSTRING(0, 12) = "mission_cfg_" {
            LOCAL bare IS sk:SUBSTRING(12, sk:LENGTH - 12).
            LOCAL raw IS stateGet(sk, "").
            LOCAL line IS "SET " + bare + " TO " + configLiteral(raw) + ".".
            LOG line TO overridePath.
            SET wrote TO TRUE.
        }
    }
    IF wrote { RUNPATH(overridePath). }
}

// Write a mission profile (a LEXICON of NAME -> value) to the vessel's
// local mission dir as compact `SET NAME TO value.` lines. In-flight
// setup (surface/return) uses this instead of persisting dozens of
// mission_cfg_* keys in state.json: boot already RUNPATHs
// 1:/missions/<vehicle>/<id>.ks for the selected mission_id, then
// layers runtime mission_cfg_* on top. Returns the path written.
GLOBAL FUNCTION missionProfileWrite {
    PARAMETER cn.
    PARAMETER mid.
    PARAMETER cfg.
    IF NOT EXISTS("1:/missions") { CREATEDIR("1:/missions"). }
    LOCAL dir IS "1:/missions/" + cn.
    IF NOT EXISTS(dir) { CREATEDIR(dir). }
    LOCAL path IS dir + "/" + mid + ".ks".
    IF EXISTS(path) { DELETEPATH(path). }
    FOR key IN cfg:KEYS {
        LOG "SET " + key + " TO " + configLiteral(cfg[key]) + "." TO path.
    }
    RETURN path.
}

GLOBAL FUNCTION phaseList {
    PARAMETER seq.
    IF seq:LENGTH = 0 { RETURN LIST("DONE"). }
    RETURN phaseSequenceEnsurePrelaunch(seq).
}

GLOBAL FUNCTION phaseNeedsPrelaunch {
    PARAMETER phaseName.
    RETURN phaseName = "LAUNCH" OR phaseName = "HOP".
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
