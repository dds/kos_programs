// ============================================================
// FR3.ks  —  FR3 vehicle flight computer  (0:/craft/FR3.ks)
//
// Ship name:  FR3-TARGET-TYPE1-TYPE2-...-NN
// Payload tokens: RELAY, SCANSAT, SCISAT, LANDER, ASSISTLANDER,
//                 ROVER, ASSISTROVER, PROBE, CRASHPROBE
// ============================================================

GLOBAL CFG IS LEXICON(
    "PARKING_ALT",          80000,
    "LAUNCH_INCLINATION",       0,
    "LAUNCH_AZIMUTH",           0,
    "LAUNCH_STAGE_LIMIT",       0,
    "FAIRING_ALT",          71500,
    "EXTEND_ALT",           73000,
    "CAPTURE_PE",            15000,
    "CAPTURE_INC",              90,
    "CAPTURE_DIR",          "POLAR",
    "TARGET_PE",             15000,
    "CIRC_ECC_TOL",          0.005,
    "TARGET_INCLINATION",      90,
    "TARGET_AP",             20000,
    "INCL_MATCH_TARGET",       "",
    "INCL_TOLERANCE",         0.01,
    "MAX_INCL_CHANGE_DV",     200,
    "PROBE_ENTRY_PE",         5000,
    "PROBE_TARGET_TOL",        2500,
    "SCANSAT_DECOUPLER_TAG", "scansat_decoupler",
    "PROGRESSIVE_RELOAD",       1,
    "RELOAD_AFTER_PARK",        1
).

GLOBAL fr3Seq IS LIST().

GLOBAL FUNCTION cfgSet {
    PARAMETER key.
    PARAMETER value.
    IF CFG:HASKEY(key) { CFG:REMOVE(key). }
    CFG:ADD(key, value).
}

LOCAL FUNCTION _cfgFromState {
    PARAMETER key.
    PARAMETER asNumber IS TRUE.
    LOCAL raw IS stateGet("mission_cfg_" + key, "").
    IF raw = "" { RETURN. }
    IF asNumber {
        cfgSet(key, raw:TONUMBER(0)).
    } ELSE {
        cfgSet(key, raw).
    }
}

LOCAL FUNCTION _numericMissionKeys {
    RETURN LIST(
        "PARKING_ALT", "LAUNCH_INCLINATION", "LAUNCH_AZIMUTH",
        "LAUNCH_STAGE_LIMIT", "FAIRING_ALT", "EXTEND_ALT",
        "CAPTURE_PE", "CAPTURE_INC", "CAPTURE_LAN", "CAPTURE_AOP",
        "TARGET_PE", "TARGET_AP", "TARGET_INCLINATION", "CIRC_ECC_TOL",
        "INCL_TOLERANCE", "MAX_INCL_CHANGE_DV",
        "PROBE_TARGET_LAT", "PROBE_TARGET_LNG", "PROBE_ENTRY_PE",
        "PROBE_TARGET_TOL", "TARGET_DEORBIT_SCAN_ORBITS",
        "TARGET_DEORBIT_SCAN_SAMPLES", "TARGET_DEORBIT_PROCEED_ON_MISS",
        "TARGET_DEORBIT_COARSE_STOP_DIST", "TARGET_DEORBIT_REFINE_TOLERANCE",
        "LANDING_SITE_SCAN_ENABLE", "LANDING_SITE_SCAN_RADIUS",
        "LANDING_SITE_SCAN_STEP", "LANDING_SITE_MAX_SLOPE",
        "ASTEROID_MAX_DEPART_ORBITS",
        "ASTEROID_DEPART_SAMPLES", "ASTEROID_TOF_SAMPLES",
        "ASTEROID_MIN_TOF", "ASTEROID_MAX_TOF",
        "ASTEROID_ARRIVAL_WEIGHT", "ASTEROID_REFINE_ITERS",
        "LANDING_TARGET_LAT", "LANDING_TARGET_LNG",
        "LANDING_DEORBIT_PE", "LANDING_TARGET_TOLERANCE",
        "LANDING_GUIDANCE_ALT", "LANDING_ASSIST_RELEASE_ALT",
        "LANDING_ASSIST_RELEASE_HSPEED", "LANDING_ASSIST_RELEASE_VSPEED",
        "LANDING_ASSIST_RELEASE_ALT_TOL", "LANDING_ASSIST_RELEASE_H_TOL",
        "LANDING_ASSIST_RELEASE_V_TOL", "LANDING_ASSIST_RELEASE_HOLD",
        "LANDING_ASSIST_DESCENT_SPEED", "LANDING_ASSIST_MAX_TILT",
        "LANDING_ASSIST_THROTTLE",
        "LANDING_ASSIST_FLYAWAY", "LANDING_ASSIST_FLYAWAY_TIME",
        "LANDING_ASSIST_FLYAWAY_THROTTLE",
        "LANDING_ASSIST_RELEASE_ON_SURFACE",
        "LANDING_ASSIST_SURFACE_BRAKE_HSPEED",
        "LANDING_ASSIST_SURFACE_BRAKE_THROTTLE",
        "LANDING_ASSIST_SURFACE_BRAKE_LEAD",
        "LANDING_ASSIST_SURFACE_BRAKE_MARGIN",
        "LANDING_ASSIST_SURFACE_BRAKE_FACTOR",
        "LANDING_ASSIST_SURFACE_BRAKE_RELEASE_HSPEED",
        "LANDING_ASSIST_SURFACE_BRAKE_AOA",
        "LANDING_ASSIST_SURFACE_FINAL_SPEED",
        "LANDING_ASSIST_SURFACE_FINAL_HSPEED",
        "LANDING_ASSIST_SURFACE_SETTLE_TIME",
        "LANDING_ASSIST_SURFACE_TIPOVER",
        "LANDING_ASSIST_SURFACE_TIP_TIME",
        "LANDING_DEORBIT_OVERSHOOT",
        "LANDING_DEORBIT_OVERSHOOT_TOLERANCE",
        "LANDING_SITE_GRID_RADIUS", "LANDING_SITE_GRID_STEP",
        "LANDING_SITE_MAX_SLOPE",
        "PROGRESSIVE_RELOAD", "RELOAD_AFTER_PARK",
        "RELOAD_AFTER_LAND_ASSIST", "RELOAD_AFTER_LAND",
        "SCANSAT_DISPOSE_CARRIER", "SCANSAT_DISPOSE_PE",
        "SCANSAT_DISPOSE_MAX_TIME", "SCANSAT_DISPOSE_BEFORE_RELEASE",
        "SCANSAT_STAGE_AFTER_RELEASE", "SCANSAT_RECOVERY_PE",
        "SCANSAT_RECOVERY_AP", "SCANSAT_RELEASE_AFTER_CAPTURE",
        "SCANSAT_MAX_NODE_DV", "SCANSAT_RECOVER_SAFE_PE",
        "SCANSAT_RECOVER_MAX_TIME", "SCANSAT_CLEARANCE_DV",
        "SCANSAT_CLEARANCE_THROTTLE", "SCANSAT_CLEARANCE_SETTLE"
    ).
}

LOCAL FUNCTION _stringMissionKeys {
    RETURN LIST(
        "SEQUENCE", "CAPTURE_DIR", "RENDEZVOUS_TARGET", "ASTEROID_TARGET",
        "INCL_MATCH_TARGET", "SCANSAT_DECOUPLER_TAG", "SCANSAT_CLEARANCE_DIR",
        "PROBE_TARGET_WAYPOINT", "LANDING_TARGET_WAYPOINT",
        "LANDING_ASSIST_DECOUPLER_TAG"
    ).
}

LOCAL FUNCTION _applyMissionState {
    FOR key IN _numericMissionKeys() {
        _cfgFromState(key, TRUE).
    }

    FOR key IN _stringMissionKeys() {
        _cfgFromState(key, FALSE).
    }
}

LOCAL FUNCTION _sanitizeAscentConfig {
    IF CFG["FAIRING_ALT"] < 10000 {
        cfgSet("FAIRING_ALT", 71500).
    }
    IF CFG["EXTEND_ALT"] < 10000 {
        cfgSet("EXTEND_ALT", 73000).
    }
    IF CFG["EXTEND_ALT"] < CFG["FAIRING_ALT"] {
        cfgSet("EXTEND_ALT", CFG["FAIRING_ALT"] + 1500).
    }
}

_applyMissionState().
_sanitizeAscentConfig().

// --- Example: rendezvous + Duna rover lander ---
// Ship name: FR3-DUNA-LANDER-01
// Mission: launch to LKO, rendezvous with Jeb's wreck in Kerbin
// orbit (e.g. to pick up crew or recover parts), then transfer
// to Duna and land a rover probe.
//
// CFG overrides:
//   SET CFG["PARKING_ALT"]       TO 100000.
//   SET CFG["CAPTURE_PE"]        TO 30000.
//   SET CFG["CAPTURE_DIR"]       TO "POLAR".
//   SET CFG["TARGET_PE"]         TO 30000.
//   SET CFG["TARGET_AP"]         TO 30000.
//   SET CFG["TARGET_INCLINATION"] TO 90.
//   SET CFG["RENDEZVOUS_TARGET"] TO "Jeb's Wreck".
//
// Sequence: LUNCH → FAIR → ANTS → PARK → RDV → XING → MCC →
//           COAST → CAPTURE → CIRC → RAISE → INCLINE →
//           LAND_DEORBIT → LAND → DONE
//
// The RDV phase runs planRendezvous() + executeManeuver() when
// RENDEZVOUS_TARGET or ASTEROID_TARGET is configured.

LOCAL FUNCTION _bootPayloads {
    LOCAL raw IS stateGet("payloads", "").
    IF raw = "" { RETURN LIST(). }
    RETURN raw:SPLIT(",").
}

LOCAL FUNCTION _bootHasPayload {
    PARAMETER payloadName.
    LOCAL targetName IS payloadName:TOUPPER.
    FOR raw IN _bootPayloads() {
        LOCAL result IS raw:TOUPPER.
        UNTIL result:LENGTH = 0 {
            LOCAL last IS result:SUBSTRING(result:LENGTH - 1, 1).
            IF last:MATCHESPATTERN("[0-9]") OR last = "-" {
                SET result TO result:SUBSTRING(0, result:LENGTH - 1).
            } ELSE {
                BREAK.
            }
        }
        IF result = targetName { RETURN TRUE. }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _phaseIn {
    PARAMETER phase.
    PARAMETER phaseList.
    FOR p IN phaseList {
        IF phase = p { RETURN TRUE. }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _bandForPhase {
    PARAMETER phaseName.
    LOCAL phase IS phaseName:TOUPPER.
    IF phase = "" OR _phaseIn(phase, LIST("LUNCH", "FAIR", "ANTS", "PARK")) {
        RETURN "LAUNCH".
    }
    IF _phaseIn(phase, LIST("RDV", "XING", "MCC", "COAST", "CAPTURE",
            "CIRC", "RAISE", "INCLINE", "SCANSAT_IMPACT_RELEASE")) {
        RETURN "TRANSFER".
    }
    IF _phaseIn(phase, LIST("TARGETED_DEORBIT", "RELEASE_PROBE",
            "RELAY_OPS", "SCANSAT_OPS")) {
        RETURN "PAYLOAD_OPS".
    }
    IF phase = "LAND_DEORBIT" {
        RETURN "LAND_DEORBIT".
    }
    IF phase = "LAND_ASSIST" {
        RETURN "LAND_ASSIST".
    }
    IF phase = "LAND" { RETURN "LAND". }
    IF phase = "ROVER" { RETURN "ROVER". }
    RETURN "MISSION".
}

GLOBAL FUNCTION fr3PhaseBand {
    RETURN _bandForPhase(stateGet("phase", "")).
}

GLOBAL FUNCTION fr3BandForPhase {
    PARAMETER phaseName.
    RETURN _bandForPhase(phaseName).
}

GLOBAL FUNCTION fr3SaveReloadState {
    PARAMETER reason.
    PARAMETER nextPhaseName.
    stateSet("reload_required", "true").
    stateSet("reload_reason", reason).
    stateSet("reload_next_phase", nextPhaseName).
    stateSet("reload_next_band", fr3BandForPhase(nextPhaseName)).
}

LOCAL FUNCTION _fr3Libs {
    LOCAL band IS fr3PhaseBand().
    LOCAL phase IS stateGet("phase", ""):TOUPPER.
    stateSet("lib_band", band).
    stateSet("lib_band_phase", phase).
    stateSet("reload_required", "false").
    LOCAL libs IS LIST("phases", "utils", "ui", "fr3_payload", "fr3_profile", "fr3_sequence").

    IF band = "LAUNCH" {
        libs:ADD("flightplan").
        libs:ADD("fr3_ui").
        libs:ADD("launch").
        libs:ADD("countdown").
        libs:ADD("orbit").
        IF _bootHasPayload("LANDER") OR _bootHasPayload("ASSISTLANDER")
                OR _bootHasPayload("ROVER") OR _bootHasPayload("ASSISTROVER") {
            libs:ADD("landing_assist").
        }
    } ELSE IF band = "TRANSFER" {
        libs:ADD("xfer").
        libs:ADD("lib_navigation").
        libs:ADD("countdown").
        libs:ADD("maneuver").
        libs:ADD("inclination").
        libs:ADD("orbit").
    } ELSE IF band = "PAYLOAD_OPS" {
        libs:ADD("payload_ops").
        libs:ADD("orbit").
        IF _phaseIn(stateGet("phase", ""):TOUPPER, LIST("TARGETED_DEORBIT")) {
            libs:ADD("targeting").
            libs:ADD("countdown").
            libs:ADD("maneuver").
        }
        IF _bootHasPayload("SCANSAT") {
            IF NOT libs:CONTAINS("countdown") { libs:ADD("countdown"). }
            IF NOT libs:CONTAINS("maneuver") { libs:ADD("maneuver"). }
        }
    } ELSE IF band = "LAND_DEORBIT" {
        libs:ADD("payload_landing").
        libs:ADD("targeting").
        libs:ADD("countdown").
        libs:ADD("maneuver").
        libs:ADD("landing_assist").
    } ELSE IF band = "LAND_ASSIST" {
        libs:ADD("payload_landing").
        libs:ADD("landing_assist").
    } ELSE IF band = "LAND" {
        libs:ADD("payload_landing").
        libs:ADD("targeting").
        libs:ADD("countdown").
        libs:ADD("maneuver").
        libs:ADD("landing").
    } ELSE IF band = "ROVER" {
        libs:ADD("payload_landing").
        libs:ADD("rover").
    } ELSE {
        libs:ADD("orbit").
    }

    IF band = "LAUNCH" {
        // Launch-only reboots should stay small. Payload operation libraries
        // are pulled in after parking orbit if the sequence actually needs them.
    }
    IF band = "TRANSFER" AND stateGet("target", "KERBIN"):TOUPPER <> "MUN" {
        libs:ADD("lambert").
        libs:ADD("maneuver_intersystem").
    }
    IF band = "TRANSFER" AND (CFG:HASKEY("RENDEZVOUS_TARGET") OR CFG:HASKEY("ASTEROID_TARGET")) {
        IF NOT libs:CONTAINS("lambert") { libs:ADD("lambert"). }
        libs:ADD("maneuver_rendezvous").
    }
    IF band = "PAYLOAD_OPS"
            AND (_bootHasPayload("SCANSAT") OR _bootHasPayload("SCISAT")) {
        libs:ADD("science").
    }
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

GLOBAL LIBS IS _fr3Libs().

GLOBAL FUNCTION main {
    fr3ApplyMissionProfile().
    LOCAL seq IS fr3BuildPhaseSequence().
    SET fr3Seq TO seq.
    IF DEFINED launchSeq { SET launchSeq TO seq. }
    IF DEFINED xferSeq { SET xferSeq TO seq. }

    mLogPhase("FR3 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    IF fr3PhaseBand() = "LAUNCH" {
        confirmLaunch(fr3PrintConfig@).
    }

    runPhases(fr3BuildPhaseMap()).
}
