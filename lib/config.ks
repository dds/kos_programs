// ============================================================
// config.ks  —  Shared config and phase sequence utilities
// (0:/lib/config.ks)
//
// Generic utilities for any craft using persistent CFG state
// and comma-separated phase sequences.
// ============================================================

// --- Config management ---

// Set or overwrite a CFG key. Remove-then-add pattern required
// because kOS LEXICON:ADD throws on duplicate keys.
GLOBAL FUNCTION cfgSet {
    PARAMETER key.
    PARAMETER value.
    IF CFG:HASKEY(key) { CFG:REMOVE(key). }
    CFG:ADD(key, value).
}

// Load a single config key from persistent state. If the state
// key is empty/missing, leaves CFG unchanged (keeps the default).
// Uses ISTYPE guard to handle values already deserialized as Scalar.
GLOBAL FUNCTION cfgFromState {
    PARAMETER key.
    PARAMETER asNumber IS TRUE.
    LOCAL raw IS stateGet("mission_cfg_" + key, "").
    IF raw = "" { RETURN. }
    IF asNumber {
        IF raw:ISTYPE("Scalar") {
            cfgSet(key, raw).
        } ELSE {
            cfgSet(key, raw:TONUMBER(0)).
        }
    } ELSE {
        cfgSet(key, raw).
    }
}

// Apply mission state overrides to CFG. Takes two LISTs of key
// names: numeric keys (parsed as numbers) and string keys (kept
// as-is). Call at script load time after defining CFG defaults.
GLOBAL FUNCTION applyMissionState {
    PARAMETER numericKeys.
    PARAMETER stringKeys.
    FOR key IN numericKeys {
        cfgFromState(key, TRUE).
    }
    FOR key IN stringKeys {
        cfgFromState(key, FALSE).
    }
}

// --- Phase sequence utilities ---

// Parse a comma-separated phase string into a LIST of uppercase
// phase names. Returns LIST("DONE") if the input is empty.
GLOBAL FUNCTION phaseListFromString {
    PARAMETER raw.
    LOCAL seq IS LIST().
    FOR phaseRaw IN raw:SPLIT(",") {
        LOCAL phaseName IS phaseRaw:TRIM:TOUPPER.
        IF phaseName <> "" { seq:ADD(phaseName). }
    }
    IF seq:LENGTH = 0 { seq:ADD("DONE"). }
    RETURN seq.
}
