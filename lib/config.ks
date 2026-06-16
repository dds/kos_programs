// ============================================================
// config.ks  —  Mission override and phase sequence utilities
// (0:/lib/config.ks)
//
// Config is executable KerboScript: mission profiles and craft
// scripts SET global variables, and libraries read those globals
// directly. Defaults live in the files that own the behavior.
// ============================================================
GLOBAL FUNCTION applyKnownMissionState {
    LOCAL overridePath IS "1:/run/mission_cfg_overrides.ks".
    IF EXISTS(overridePath) { DELETEPATH(overridePath). }
    LOCAL wrote IS FALSE.
    FOR sk IN stateKeys() {
        IF sk:LENGTH > 12 AND sk:SUBSTRING(0, 12) = "mission_cfg_" {
            LOCAL bare IS sk:SUBSTRING(12, sk:LENGTH - 12).
            LOCAL raw IS stateGet(sk, "").
            LOCAL line IS "".
            IF raw:ISTYPE("Scalar") {
                SET line TO "SET " + bare + " TO " + raw + ".".
            } ELSE {
                SET line TO "SET " + bare + " TO " + CHAR(34) + raw + CHAR(34) + ".".
            }
            LOG line TO overridePath.
            SET wrote TO TRUE.
        }
    }
    IF wrote { RUNPATH(overridePath). }
}

GLOBAL FUNCTION phaseListFromString {
    PARAMETER raw.
    LOCAL seq IS LIST().
    FOR phaseRaw IN raw:SPLIT(",") {
        LOCAL phaseName IS phaseRaw:TRIM.
        IF phaseName <> "" { seq:ADD(phaseName). }
    }
    IF seq:LENGTH = 0 { seq:ADD("DONE"). }
    RETURN seq.
}
