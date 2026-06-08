// ============================================================
// rocket.ks  —  Shared rocket config and sequence utilities
// (0:/lib/rocket.ks)
//
// Provides common infrastructure used by FR2, FR3, and other
// rocket craft scripts: config management, phase sequence
// parsing, and the main() boilerplate skeleton.
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

// --- Main skeleton ---

// Shared main() boilerplate for rocket craft scripts.
//   vehicleName   - string for logging (e.g. "FR2")
//   seqBuilder    - delegate that returns the phase sequence LIST
//   configPrinter - delegate for flight plan display (passed to confirmLaunch)
//   phaseMapBuilder - delegate that returns the phase LEXICON
//   options       - optional LEXICON:
//     "skipConfirmCheck" - delegate returning TRUE to skip confirmLaunch
//     "preRun"          - delegate called after seq setup, before runPhases
GLOBAL FUNCTION rocketMain {
    PARAMETER vehicleName.
    PARAMETER seqBuilder.
    PARAMETER configPrinter.
    PARAMETER phaseMapBuilder.
    PARAMETER options IS LEXICON().

    LOCAL seq IS seqBuilder:CALL().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase(vehicleName + " MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    IF options:HASKEY("preRun") {
        options["preRun"]:CALL().
    }

    LOCAL skipConfirm IS FALSE.
    IF options:HASKEY("skipConfirmCheck") {
        SET skipConfirm TO options["skipConfirmCheck"]:CALL().
    }
    IF NOT skipConfirm {
        confirmLaunch(configPrinter).
    }

    runPhases(phaseMapBuilder:CALL()).
}
