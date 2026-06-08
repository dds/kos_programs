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

// Load-time config application (runs before LIBS are loaded,
// so boot loads config.ks as part of its core library set).
LOCAL FUNCTION _cfgSet {
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
        IF raw:ISTYPE("Scalar") { _cfgSet(key, raw). }
        ELSE { _cfgSet(key, raw:TONUMBER(0)). }
    } ELSE {
        _cfgSet(key, raw).
    }
}

LOCAL FUNCTION _sanitizeAscentConfig {
    IF CFG["FAIRING_ALT"] < 10000 {
        _cfgSet("FAIRING_ALT", 71500).
    }
    IF CFG["EXTEND_ALT"] < 10000 {
        _cfgSet("EXTEND_ALT", 73000).
    }
    IF CFG["EXTEND_ALT"] < CFG["FAIRING_ALT"] {
        _cfgSet("EXTEND_ALT", CFG["FAIRING_ALT"] + 1500).
    }
}

FOR key IN missionNumericConfigKeys() { _cfgFromState(key, TRUE). }
FOR key IN missionStringConfigKeys() { _cfgFromState(key, FALSE). }
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
// Sequence: LUNCH -> FAIR -> ANTS -> PARK -> RDV -> XING -> MCC ->
//           COAST -> CAPTURE -> CIRC -> RAISE -> INCLINE ->
//           LAND_DEORBIT -> LAND -> DONE
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
    IF _phaseIn(phase, LIST("RDV", "XING")) {
        RETURN "XFER_PLAN".
    }
    IF phase = "MCC" {
        RETURN "XFER_MCC".
    }
    IF _phaseIn(phase, LIST("COAST", "CAPTURE")) {
        RETURN "XFER_ARRIVE".
    }
    IF _phaseIn(phase, LIST("CIRC", "RAISE", "INCLINE",
            "SCANSAT_IMPACT_RELEASE", "PAYLOAD_IMPACT_RELEASE", "ELLIPTICAL")) {
        RETURN "XFER_ORBIT".
    }
    IF _phaseIn(phase, LIST("TARGETED_DEORBIT", "RELEASE_PROBE",
            "RELAY_OPS", "SCANSAT_OPS")) {
        RETURN "PAYLOAD_OPS".
    }
    IF phase = "LAND_DEORBIT" { RETURN "LAND_DEORBIT". }
    IF phase = "LAND_ASSIST" { RETURN "LAND_ASSIST". }
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

LOCAL FUNCTION _fr3AddLib {
    PARAMETER libs.
    PARAMETER libName.
    IF NOT libs:CONTAINS(libName) {
        libs:ADD(libName).
    }
}

LOCAL FUNCTION _fr3AddLibWithDeps {
    PARAMETER libs.
    PARAMETER libName.
    _fr3AddLib(libs, libName).

    IF libName = "maneuver_orbit" {
        _fr3AddLib(libs, "maneuver").
        _fr3AddLib(libs, "maneuver_targeting").
        _fr3AddLib(libs, "countdown").
        _fr3AddLib(libs, "inclination").
        _fr3AddLib(libs, "orbit").
    }
}

LOCAL FUNCTION _fr3Libs {
    LOCAL band IS fr3PhaseBand().
    LOCAL phase IS stateGet("phase", ""):TOUPPER.
    stateSet("lib_band", band).
    stateSet("lib_band_phase", phase).
    stateSet("reload_required", "false").
    LOCAL libs IS LIST("phases", "utils", "ui", "config", "fr3_payload", "fr3_profile", "fr3_sequence").

    IF band = "LAUNCH" {
        libs:ADD("flightplan").
        libs:ADD("fr3_ui").
        libs:ADD("launch").
        libs:ADD("countdown").
        libs:ADD("orbit").
        IF _bootHasPayload("LANDER") OR _bootHasPayload("ASSISTLANDER")
                OR _bootHasPayload("ROVER") OR _bootHasPayload("ASSISTROVER") {
            libs:ADD("landing").
        }
    } ELSE IF band = "XFER_PLAN" {
        libs:ADD("xfer_plan").
        libs:ADD("maneuver").
        libs:ADD("maneuver_targeting").
        libs:ADD("lib_navigation").
        libs:ADD("countdown").
        libs:ADD("orbit").
    } ELSE IF band = "XFER_MCC" {
        libs:ADD("maneuver").
        libs:ADD("maneuver_targeting").
        libs:ADD("countdown").
        libs:ADD("orbit").
    } ELSE IF band = "XFER_ARRIVE" {
        libs:ADD("capture").
        libs:ADD("maneuver").
        libs:ADD("maneuver_targeting").
        libs:ADD("countdown").
        libs:ADD("orbit").
    } ELSE IF band = "XFER_ORBIT" {
        _fr3AddLibWithDeps(libs, "maneuver_orbit").
    } ELSE IF band = "PAYLOAD_OPS" {
        libs:ADD("payload_ops").
        libs:ADD("orbit").
        IF _phaseIn(stateGet("phase", ""):TOUPPER, LIST("TARGETED_DEORBIT")) {
            libs:ADD("deorbit_targeting").
            libs:ADD("countdown").
            libs:ADD("maneuver_targeting").
            libs:ADD("maneuver").
        }
        IF _bootHasPayload("SCANSAT") {
            IF NOT libs:CONTAINS("countdown") { libs:ADD("countdown"). }
            IF NOT libs:CONTAINS("maneuver_targeting") { libs:ADD("maneuver_targeting"). }
            IF NOT libs:CONTAINS("maneuver") { libs:ADD("maneuver"). }
        }
    } ELSE IF band = "LAND_DEORBIT" {
        libs:ADD("payload_landing").
        IF CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH")
                AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0 {
            libs:ADD("landing").
        } ELSE {
            libs:ADD("deorbit_targeting").
            libs:ADD("landing").
        }
    } ELSE IF band = "LAND_ASSIST" {
        libs:ADD("payload_landing").
        libs:ADD("landing").
    } ELSE IF band = "LAND" {
        libs:ADD("payload_landing").
        libs:ADD("deorbit_targeting").
        libs:ADD("countdown").
        libs:ADD("maneuver_targeting").
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
    IF band = "XFER_PLAN" AND stateGet("target", "KERBIN"):TOUPPER <> "MUN" {
        libs:ADD("lambert").
        libs:ADD("maneuver_intersystem").
    }
    IF band = "XFER_PLAN" AND (CFG:HASKEY("RENDEZVOUS_TARGET") OR CFG:HASKEY("ASTEROID_TARGET")) {
        IF NOT libs:CONTAINS("lambert") { libs:ADD("lambert"). }
        libs:ADD("maneuver_rendezvous").
    }
    IF band = "PAYLOAD_OPS"
            AND (_bootHasPayload("SCANSAT") OR _bootHasPayload("SCISAT")) {
        libs:ADD("science").
    }
    IF DEFINED missionAppendUnique {
        missionAppendUnique(libs, missionListFromCsv(stateGet("mission_cfg_LIBS_EXTRA", ""))).
    }
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

GLOBAL LIBS IS _fr3Libs().

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "FR3",
    "keepCmds", LIST(
        "CLEANUP", "DUMP", "FILES", "LANDASSIST", "LANDINGCHECK",
        "LANDINGRESCUE", "LANDMIN", "SETLANDASSIST", "SETLANDINGDEORBIT",
        "SETLANDINGTAG", "SETSTATE", "SETUP_MUN_ROVER_LANDING_REAL",
        "SETUP_MUN_ROVER_LANDING_SIM", "SIMLANDHERE"
    )
).

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
        IF NOT confirmLaunch(fr3PrintConfig@) { RETURN. }
    }

    runPhases(fr3BuildPhaseMap()).
}
