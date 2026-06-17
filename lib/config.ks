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
