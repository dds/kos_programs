// ============================================================
// config.ks  —  Shared config and phase sequence utilities
// (0:/lib/config.ks)
//
// Generic utilities for any craft using persistent CFG state
// and comma-separated phase sequences.
// ============================================================

// --- Config management ---

GLOBAL FUNCTION missionNumericConfigKeys {
    RETURN LIST(
        "PARKING_ALT", "LAUNCH_INCLINATION", "LAUNCH_AZIMUTH",
        "FAIRING_ALT", "EXTEND_ALT",
        "RELAY_ALT", "CAPTURE_PE", "CAPTURE_INC", "CAPTURE_LAN",
        "CAPTURE_AOP", "TRANSFER_AOP_ERR_TOL", "TRANSFER_INC_ERR_TOL",
        "TRANSFER_SCAN_SAMPLES_PER_ORBIT",
        "MCC_MIN_DV", "MCC_LATE_MIN_DV",
        "TARGET_PE", "TARGET_AP", "TARGET_INCLINATION", "CIRC_ECC_TOL",
        "INCL_TOLERANCE", "MAX_INCL_CHANGE_DV", "LAN_ERR_TOL",
        "ELLIPTICAL_MAX_NODE_DV", "ELLIPTICAL_RECOVERY_MARGIN",
        "PROBE_TARGET_LAT", "PROBE_TARGET_LNG", "PROBE_ENTRY_PE",
        "PROBE_TARGET_TOL", "TARGET_DEORBIT_SCAN_ORBITS",
        "TARGET_DEORBIT_SCAN_SAMPLES", "TARGET_DEORBIT_PROCEED_ON_MISS",
        "TARGET_DEORBIT_COARSE_STOP_DIST", "TARGET_DEORBIT_REFINE_TOLERANCE",
        "TARGET_DEORBIT_SCAN_CENTER_MINUTES", "TARGET_DEORBIT_SCAN_WINDOW_MINUTES",
        "TARGET_DEORBIT_MIN_LEAD", "TARGET_DEORBIT_REFINE_MAX_START_DIST",
        "LANDING_SITE_SCAN_ENABLE", "LANDING_SITE_SCAN_RADIUS",
        "LANDING_SITE_SCAN_STEP", "LANDING_SITE_MAX_SLOPE",
        "ASTEROID_MAX_DEPART_ORBITS",
        "ASTEROID_DEPART_SAMPLES", "ASTEROID_TOF_SAMPLES",
        "ASTEROID_MIN_TOF", "ASTEROID_MAX_TOF",
        "ASTEROID_ARRIVAL_WEIGHT", "ASTEROID_REFINE_ITERS",
        "LANDING_TARGET_LAT", "LANDING_TARGET_LNG", "LANDING_TARGET_LOCK",
        "LANDING_AUTO_TARGET", "LANDING_AUTO_TARGET_MINUTES", "LANDING_SIM_MODE",
        "LANDING_SKIP_TARGET_SEARCH", "LANDING_DEORBIT_LEAD_MINUTES",
        "LANDING_DEORBIT_PE", "LANDING_DEORBIT_MIN_DV", "LANDING_DEORBIT_MAX_DV",
        "LANDING_TARGET_TOLERANCE",
        "LANDING_GUIDANCE_ALT", "LANDING_ASSIST_MAX_TILT",
        "LANDING_ASSIST_SURFACE_SETTLE_TIME",
        "LANDING_ASSIST_SURFACE_TIPOVER",
        "LANDING_ASSIST_SURFACE_TIP_TIME",
        "LANDING_ROVER_ORIENT", "LANDING_ROVER_ORIENT_TIME",
        "LANDING_ROVER_BRAKE",
        "LANDING_DEORBIT_OVERSHOOT",
        "LANDING_DEORBIT_OVERSHOOT_TOLERANCE",
        "LANDING_GUIDANCE_CORRECTION_THRESHOLD",
        "LANDING_GUIDANCE_MAX_DV",
        "RELOAD_AFTER_LAND_ASSIST", "RELOAD_AFTER_LAND",
        "SCANSAT_DISPOSE_CARRIER", "SCANSAT_DISPOSE_PE",
        "SCANSAT_DISPOSE_MAX_TIME", "SCANSAT_DISPOSE_BEFORE_RELEASE",
        "SCANSAT_STAGE_AFTER_RELEASE", "SCANSAT_RECOVERY_PE",
        "SCANSAT_RECOVERY_AP", "SCANSAT_RELEASE_AFTER_CAPTURE",
        "SCANSAT_MAX_NODE_DV", "SCANSAT_RECOVER_SAFE_PE",
        "SCANSAT_RECOVER_MAX_TIME", "SCANSAT_CLEARANCE_DV",
        "SCANSAT_CLEARANCE_THROTTLE", "SCANSAT_CLEARANCE_SETTLE",
        "PAYLOAD_DISPOSE_PE", "PAYLOAD_DISPOSE_MAX_TIME",
        "PAYLOAD_CLEARANCE_DV", "PAYLOAD_CLEARANCE_THROTTLE",
        "PAYLOAD_CLEARANCE_SETTLE", "PAYLOAD_RECOVERY_MARGIN",
        "MOLNIYA_PERIOD", "MOLNIYA_AOP", "MOLNIYA_ECC", "RECOVERY_PE"
    ).
}

GLOBAL FUNCTION missionStringConfigKeys {
    RETURN LIST(
        "SEQUENCE", "CAPTURE_DIR", "RENDEZVOUS_TARGET", "ASTEROID_TARGET",
        "INCL_MATCH_TARGET", "SCANSAT_DECOUPLER_TAG", "SCANSAT_CLEARANCE_DIR",
        "PAYLOAD_DECOUPLER_TAG", "PAYLOAD_LABEL", "PAYLOAD_CLEARANCE_DIR",
        "PROBE_TARGET_WAYPOINT", "LANDING_TARGET_WAYPOINT",
        "LANDING_ASSIST_DECOUPLER_TAG"
    ).
}

GLOBAL FUNCTION missionProfileConfigKeys {
    RETURN LIST(
        "MISSION_ID", "MISSION_NAME", "TARGET", "PAYLOADS",
        "LIBS", "LIBS_EXTRA"
    ).
}

GLOBAL FUNCTION missionConfigKeyTypes {
    RETURN LEXICON(
        "NUMERIC", missionNumericConfigKeys(),
        "STRING", missionStringConfigKeys(),
        "PROFILE", missionProfileConfigKeys()
    ).
}

GLOBAL FUNCTION missionConfigIsKnownKey {
    PARAMETER key.
    IF missionNumericConfigKeys():CONTAINS(key) { RETURN TRUE. }
    IF missionStringConfigKeys():CONTAINS(key) { RETURN TRUE. }
    IF missionProfileConfigKeys():CONTAINS(key) { RETURN TRUE. }
    RETURN FALSE.
}

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

GLOBAL FUNCTION applyKnownMissionState {
    applyMissionState(missionNumericConfigKeys(), missionStringConfigKeys()).
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
