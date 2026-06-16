// ============================================================
// config.ks  —  Shared config and phase sequence utilities
// (0:/lib/config.ks)
//
// Generic utilities for any craft using persistent CFG state
// and comma-separated phase sequences.
// ============================================================

// --- Config management ---

// Read a CFG key with a default — the shared form of the per-lib
// _cfg helpers (config is preamble, so it is always available).
GLOBAL FUNCTION cfgNum {
    PARAMETER key.
    PARAMETER defaultValue.
    IF CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

// Set or overwrite a CFG key. Remove-then-add pattern required
// because kOS LEXICON:ADD throws on duplicate keys.
GLOBAL FUNCTION cfgSet {
    PARAMETER key.
    PARAMETER value.
    IF CFG:HASKEY(key) { CFG:REMOVE(key). }
    CFG:ADD(key, value).
}

GLOBAL FUNCTION applyKnownMissionState {
    FOR sk IN stateKeys() {
        IF sk:LENGTH > 12 AND sk:SUBSTRING(0, 12) = "mission_cfg_" {
            LOCAL bare IS sk:SUBSTRING(12, sk:LENGTH - 12).
            LOCAL raw IS stateGet(sk, "").
            IF raw <> "" { cfgSet(bare, raw). }
        }
    }
}

// --- Phase sequence utilities ---

// Parse a comma-separated phase string into a LIST.
// Returns LIST("DONE") if the input is empty.
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
