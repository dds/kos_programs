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
    "PROBE_TARGET_LAT",       50,
    "PROBE_TARGET_LNG",        30, 
    "PROBE_ENTRY_PE",         5000,
    "PROBE_TARGET_TOL",        2500,
    "SCANSAT_DECOUPLER_TAG", "scansat_decoupler",
    "PROGRESSIVE_RELOAD",       1,
    "RELOAD_AFTER_PARK",        1
).

GLOBAL fr3Seq IS LIST().

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
        _cfgSet(key, raw:TONUMBER(0)).
    } ELSE {
        _cfgSet(key, raw).
    }
}

LOCAL FUNCTION _applyMissionState {
    FOR key IN LIST(
        "PARKING_ALT", "LAUNCH_INCLINATION", "LAUNCH_AZIMUTH",
        "LAUNCH_STAGE_LIMIT", "FAIRING_ALT", "EXTEND_ALT",
        "CAPTURE_PE", "CAPTURE_INC", "CAPTURE_LAN", "CAPTURE_AOP",
        "TARGET_PE", "TARGET_AP", "TARGET_INCLINATION", "CIRC_ECC_TOL",
        "INCL_TOLERANCE", "MAX_INCL_CHANGE_DV",
        "PROBE_TARGET_LAT", "PROBE_TARGET_LNG", "PROBE_ENTRY_PE",
        "PROBE_TARGET_TOL", "TARGET_DEORBIT_SCAN_ORBITS",
        "TARGET_DEORBIT_SCAN_SAMPLES", "ASTEROID_MAX_DEPART_ORBITS",
        "ASTEROID_DEPART_SAMPLES", "ASTEROID_TOF_SAMPLES",
        "ASTEROID_MIN_TOF", "ASTEROID_MAX_TOF",
        "ASTEROID_ARRIVAL_WEIGHT", "ASTEROID_REFINE_ITERS",
        "LANDING_TARGET_LAT", "LANDING_TARGET_LNG",
        "LANDING_DEORBIT_PE", "LANDING_TARGET_TOLERANCE",
        "LANDING_GUIDANCE_ALT", "LANDING_ASSIST_RELEASE_ALT",
        "LANDING_ASSIST_RELEASE_HSPEED", "LANDING_ASSIST_RELEASE_VSPEED",
        "PROGRESSIVE_RELOAD", "RELOAD_AFTER_PARK",
        "RELOAD_AFTER_LAND_ASSIST", "RELOAD_AFTER_LAND"
    ) {
        _cfgFromState(key, TRUE).
    }

    FOR key IN LIST(
        "SEQUENCE", "CAPTURE_DIR", "RENDEZVOUS_TARGET", "ASTEROID_TARGET",
        "INCL_MATCH_TARGET", "SCANSAT_DECOUPLER_TAG",
        "PROBE_TARGET_WAYPOINT", "LANDING_TARGET_WAYPOINT"
    ) {
        _cfgFromState(key, FALSE).
    }
}

_applyMissionState().

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

LOCAL FUNCTION _fr3PhaseBand {
    LOCAL phase IS stateGet("phase", ""):TOUPPER.
    IF phase = "" OR _phaseIn(phase, LIST("LUNCH", "FAIR", "ANTS", "PARK")) {
        RETURN "LAUNCH".
    }
    IF _phaseIn(phase, LIST("RDV", "XING", "MCC", "COAST", "CAPTURE",
            "CIRC", "RAISE", "INCLINE")) {
        RETURN "TRANSFER".
    }
    IF _phaseIn(phase, LIST("TARGETED_DEORBIT", "RELEASE_PROBE",
            "RELAY_OPS", "SCANSAT_OPS")) {
        RETURN "PAYLOAD_OPS".
    }
    IF _phaseIn(phase, LIST("LAND_DEORBIT", "LAND_ASSIST")) {
        RETURN "LAND_ASSIST".
    }
    IF phase = "LAND" { RETURN "LAND". }
    IF phase = "ROVER" { RETURN "ROVER". }
    RETURN "MISSION".
}

LOCAL FUNCTION _fr3BandForPhase {
    PARAMETER phaseName.
    LOCAL phaseUp IS phaseName:TOUPPER.
    IF phaseUp = "" OR _phaseIn(phaseUp, LIST("LUNCH", "FAIR", "ANTS", "PARK")) {
        RETURN "LAUNCH".
    }
    IF _phaseIn(phaseUp, LIST("RDV", "XING", "MCC", "COAST", "CAPTURE",
            "CIRC", "RAISE", "INCLINE")) {
        RETURN "TRANSFER".
    }
    IF _phaseIn(phaseUp, LIST("TARGETED_DEORBIT", "RELEASE_PROBE",
            "RELAY_OPS", "SCANSAT_OPS")) {
        RETURN "PAYLOAD_OPS".
    }
    IF _phaseIn(phaseUp, LIST("LAND_DEORBIT", "LAND_ASSIST")) {
        RETURN "LAND_ASSIST".
    }
    IF phaseUp = "LAND" { RETURN "LAND". }
    IF phaseUp = "ROVER" { RETURN "ROVER". }
    RETURN "MISSION".
}

LOCAL FUNCTION _saveReloadState {
    PARAMETER reason.
    PARAMETER nextPhaseName.
    stateSet("reload_required", "true").
    stateSet("reload_reason", reason).
    stateSet("reload_next_phase", nextPhaseName).
    stateSet("reload_next_band", _fr3BandForPhase(nextPhaseName)).
}

LOCAL FUNCTION _fr3Libs {
    LOCAL band IS _fr3PhaseBand().
    LOCAL phase IS stateGet("phase", ""):TOUPPER.
    stateSet("lib_band", band).
    stateSet("lib_band_phase", phase).
    stateSet("reload_required", "false").
    LOCAL libs IS LIST("phases", "utils").

    IF band = "LAUNCH" {
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
        libs:ADD("maneuver").
        libs:ADD("inclination").
        libs:ADD("orbit").
    } ELSE IF band = "PAYLOAD_OPS" {
        libs:ADD("payload_ops").
        libs:ADD("orbit").
        IF _phaseIn(stateGet("phase", ""):TOUPPER, LIST("TARGETED_DEORBIT")) {
            libs:ADD("targeting").
            libs:ADD("maneuver").
        }
    } ELSE IF band = "LAND_ASSIST" {
        libs:ADD("payload_landing").
        libs:ADD("targeting").
        libs:ADD("maneuver").
        libs:ADD("landing_assist").
    } ELSE IF band = "LAND" {
        libs:ADD("payload_landing").
        libs:ADD("targeting").
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
    IF (band = "TRANSFER" OR band = "PAYLOAD_OPS")
            AND (_bootHasPayload("SCANSAT") OR _bootHasPayload("SCISAT")) {
        libs:ADD("science").
    }
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

GLOBAL LIBS IS _fr3Libs().

LOCAL FUNCTION _hasLandingPayload {
    FOR ptype IN missionPayloads() {
        LOCAL t IS normalizePayloadType(ptype).
        IF t = "LANDER" OR t = "ASSISTLANDER"
                OR t = "ROVER" OR t = "ASSISTROVER" {
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _hasPayload {
    PARAMETER payloadName.
    FOR ptype IN missionPayloads() {
        IF normalizePayloadType(ptype) = payloadName:TOUPPER { RETURN TRUE. }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _phaseListFromString {
    PARAMETER raw.
    LOCAL seq IS LIST().
    FOR phaseRaw IN raw:SPLIT(",") {
        LOCAL phaseName IS phaseRaw:TRIM:TOUPPER.
        IF phaseName <> "" { seq:ADD(phaseName). }
    }
    IF seq:LENGTH = 0 { seq:ADD("DONE"). }
    RETURN seq.
}

LOCAL FUNCTION _applyMissionProfile {
    IF MISSION["target"]:TOUPPER = "MUN" AND _hasLandingPayload() {
        IF DEFINED LANDING_CFG {
            SET LANDING_CFG["DEORBIT_PE"] TO 5000.
            SET LANDING_CFG["TARGET_TOLERANCE"] TO 2500.
            SET LANDING_CFG["GUIDANCE_ALT"] TO 5000.
        }

        IF _hasPayload("ASSISTROVER") OR _hasPayload("ASSISTLANDER") {
            IF DEFINED LANDING_CFG {
                SET LANDING_CFG["ASSIST_RELEASE_ALT"] TO 100.
                SET LANDING_CFG["ASSIST_RELEASE_HSPEED"] TO 0.5.
                SET LANDING_CFG["ASSIST_RELEASE_VSPEED"] TO 0.
            }
            _cfgSet("RELOAD_AFTER_LAND_ASSIST", 1).
        }
        IF _hasPayload("ROVER") OR _hasPayload("ASSISTROVER") {
            _cfgSet("RELOAD_AFTER_LAND", 1).
        }
    }

    IF DEFINED LANDING_CFG {
        IF CFG:HASKEY("LANDING_TARGET_LAT") {
            SET LANDING_CFG["TARGET_LAT"] TO CFG["LANDING_TARGET_LAT"].
        }
        IF CFG:HASKEY("LANDING_TARGET_LNG") {
            SET LANDING_CFG["TARGET_LNG"] TO CFG["LANDING_TARGET_LNG"].
        }
        IF CFG:HASKEY("LANDING_TARGET_WAYPOINT") {
            SET LANDING_CFG["TARGET_WAYPOINT"] TO CFG["LANDING_TARGET_WAYPOINT"].
        }
        IF CFG:HASKEY("LANDING_DEORBIT_PE") {
            SET LANDING_CFG["DEORBIT_PE"] TO CFG["LANDING_DEORBIT_PE"].
        }
        IF CFG:HASKEY("LANDING_TARGET_TOLERANCE") {
            SET LANDING_CFG["TARGET_TOLERANCE"] TO CFG["LANDING_TARGET_TOLERANCE"].
        }
        IF CFG:HASKEY("LANDING_GUIDANCE_ALT") {
            SET LANDING_CFG["GUIDANCE_ALT"] TO CFG["LANDING_GUIDANCE_ALT"].
        }
        IF CFG:HASKEY("LANDING_ASSIST_RELEASE_ALT") {
            SET LANDING_CFG["ASSIST_RELEASE_ALT"] TO CFG["LANDING_ASSIST_RELEASE_ALT"].
        }
        IF CFG:HASKEY("LANDING_ASSIST_RELEASE_HSPEED") {
            SET LANDING_CFG["ASSIST_RELEASE_HSPEED"] TO CFG["LANDING_ASSIST_RELEASE_HSPEED"].
        }
        IF CFG:HASKEY("LANDING_ASSIST_RELEASE_VSPEED") {
            SET LANDING_CFG["ASSIST_RELEASE_VSPEED"] TO CFG["LANDING_ASSIST_RELEASE_VSPEED"].
        }
    }

    IF MISSION["target"]:TOUPPER = "MUN"
            AND _hasPayload("SCANSAT")
            AND _hasLandingPayload() {
        // Mun mapper + rover stack: deploy mapper in a useful polar orbit,
        // then spend the remaining vehicle on targeted rover landing.
        SET CFG["CAPTURE_PE"] TO 20000.
        SET CFG["CAPTURE_INC"] TO 90.
        SET CFG["TARGET_PE"] TO 250000.
        SET CFG["TARGET_AP"] TO 250000.
        SET CFG["TARGET_INCLINATION"] TO 90.
        SET CFG["MAX_INCL_CHANGE_DV"] TO 300.

    }
}

LOCAL FUNCTION _phaseParkingReload {
    phaseParking().
    IF CFG:HASKEY("RELOAD_AFTER_PARK") AND CFG["RELOAD_AFTER_PARK"] > 0 {
        _saveReloadState("PARKING_ORBIT", stateGet("phase", "")).
        mLog("Reload point after parking orbit. Reboot to load transfer libraries.").
        PRINT " ".
        PRINT "  PARKING ORBIT READY".
        PRINT "  Reboot this CPU to load transfer code.".
        WAIT UNTIL FALSE.
    }
}

LOCAL FUNCTION buildPhaseSequence {
    IF CFG:HASKEY("SEQUENCE") {
        RETURN _phaseListFromString(CFG["SEQUENCE"]).
    }

    // Orbit phases prepare the shared carrier in the orbit required by the
    // first payload. For mapper-rover Mun missions, _applyMissionProfile()
    // changes this to a 250 km polar SCANsat orbit before landing begins.
    LOCAL orbitPhases IS LIST("CIRC", "RAISE", "INCLINE").

    LOCAL payloadPhases IS LEXICON(
        "CRASHPROBE", LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "PROBE",      LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "RELAY",      LIST("RELAY_OPS"),
        "SCANSAT",    LIST("SCANSAT_OPS"),
        "SCISAT",     LIST("RELAY_OPS"),
        "ASSISTLANDER", LIST("LAND_DEORBIT", "LAND_ASSIST", "LAND"),
        "LANDER",     LIST("LAND_DEORBIT", "LAND"),
        "ASSISTROVER", LIST("LAND_DEORBIT", "LAND_ASSIST", "LAND", "ROVER"),
        "ROVER",      LIST("LAND_DEORBIT", "LAND", "ROVER")
    ).

    RETURN buildRocketSequence(orbitPhases, payloadPhases).
}

LOCAL FUNCTION _buildPhaseMap {
    LOCAL band IS _fr3PhaseBand().
    LOCAL phaseMap IS LEXICON().

    IF band = "LAUNCH" {
        phaseMap:ADD("LUNCH", phaseLaunch@).
        phaseMap:ADD("FAIR", phaseFairing@).
        phaseMap:ADD("ANTS", phaseExtendAnts@).
        phaseMap:ADD("PARK", _phaseParkingReload@).
    }

    IF band = "TRANSFER" {
        phaseMap:ADD("RDV", phaseRendezvous@).
        phaseMap:ADD("XING", phaseTransfer@).
        phaseMap:ADD("MCC", phaseMidCourse@).
        phaseMap:ADD("COAST", phaseCoast@).
        phaseMap:ADD("CAPTURE", phaseCapture@).
        phaseMap:ADD("CIRC", phaseCirc@).
        phaseMap:ADD("RAISE", phaseRaiseAlt@).
        phaseMap:ADD("INCLINE", phaseInclCorrect@).
    }

    IF band = "PAYLOAD_OPS" AND (_hasPayload("PROBE") OR _hasPayload("CRASHPROBE")) {
        phaseMap:ADD("TARGETED_DEORBIT", phaseTargetedDeorbit@).
        phaseMap:ADD("RELEASE_PROBE", phaseReleaseProbe@).
    }
    IF band = "PAYLOAD_OPS" AND (_hasPayload("RELAY") OR _hasPayload("SCISAT")) {
        phaseMap:ADD("RELAY_OPS", phaseRelayOps@).
    }
    IF band = "PAYLOAD_OPS" AND _hasPayload("SCANSAT") {
        phaseMap:ADD("SCANSAT_OPS", phaseScanSatOps@).
    }
    IF band = "LAND_ASSIST" {
        phaseMap:ADD("LAND_DEORBIT", phaseLandDeorbit@).
        phaseMap:ADD("LAND_ASSIST", phaseLandAssist@).
    }
    IF band = "LAND" {
        phaseMap:ADD("LAND", phaseLand@).
    }
    IF band = "ROVER" {
        phaseMap:ADD("ROVER", phaseRover@).
    }

    RETURN phaseMap.
}

LOCAL FUNCTION _printConfig {
    LOCAL seq IS buildPhaseSequence().
    LOCAL hasScanSat IS _hasPayload("SCANSAT").
    LOCAL hasLander IS _hasLandingPayload().

    PRINT "  ========================================".
    PRINT "    FR3 FLIGHT PLAN    " + SHIP:NAME.
    PRINT "  ========================================".
    PRINT " ".
    IF stateGet("mission_id", "") <> "" {
        PRINT "  MISSION .... " + stateGet("mission_name", stateGet("mission_id", "")).
        PRINT "  PROFILE .... " + stateGet("mission_id", "").
    }
    PRINT "  TARGET ..... " + MISSION["target"].
    PRINT "  PAYLOADS ... " + MISSION["payloads"].
    PRINT " ".
    PRINT "  -- ASCENT --".
    PRINT "  PARK ALT ... " + ROUND(CFG["PARKING_ALT"]/1000,0) + " km".
    LOCAL incStr IS CFG["LAUNCH_INCLINATION"] + " deg".
    IF CFG["LAUNCH_INCLINATION"] = 0 { SET incStr TO "0 deg  (equatorial)". }
    PRINT "  INCL ...... " + incStr.
    PRINT "  FAIRING ... " + ROUND(CFG["FAIRING_ALT"]/1000,0) + " km".
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        PRINT " ".
        PRINT "  -- TRANSFER --".
        PRINT "  CAPTURE PE . " + ROUND(CFG["CAPTURE_PE"]/1000,0) + " km".
        IF CFG:HASKEY("CAPTURE_INC") {
            PRINT "  CAPTURE INC  " + ROUND(CFG["CAPTURE_INC"],1) + " deg".
        }
        IF CFG:HASKEY("CAPTURE_LAN") {
            PRINT "  CAPTURE LAN  " + ROUND(CFG["CAPTURE_LAN"],1) + " deg".
        }
        IF CFG:HASKEY("CAPTURE_AOP") {
            PRINT "  CAPTURE AoP  " + ROUND(CFG["CAPTURE_AOP"],1) + " deg".
        }
    }
    PRINT " ".
    PRINT "  -- ORBIT --".
    PRINT "  FINAL ALT .. " + ROUND(CFG["TARGET_AP"]/1000,0) + " km".
    LOCAL tincStr IS CFG["TARGET_INCLINATION"] + " deg".
    IF CFG["TARGET_INCLINATION"] = 0 { SET tincStr TO "0 deg  (equatorial)". }
    PRINT "  FINAL INCL . " + tincStr.
    PRINT "  CIRC TOL ... ecc < " + CFG["CIRC_ECC_TOL"].
    IF hasScanSat {
        PRINT " ".
        PRINT "  -- SCANSAT --".
        PRINT "  DEPLOY TAG . " + CFG["SCANSAT_DECOUPLER_TAG"].
    }
    IF hasLander {
        PRINT " ".
        PRINT "  -- LANDING --".
        LOCAL targetText IS "map-selected waypoint".
        IF LANDING_CFG["TARGET_LAT"] <> 0 OR LANDING_CFG["TARGET_LNG"] <> 0 {
            SET targetText TO ROUND(LANDING_CFG["TARGET_LAT"],4)
                + " lat  " + ROUND(LANDING_CFG["TARGET_LNG"],4) + " lng".
        } ELSE IF LANDING_CFG["TARGET_WAYPOINT"] <> "" {
            SET targetText TO "waypoint " + LANDING_CFG["TARGET_WAYPOINT"].
        }
        PRINT "  TARGET ..... " + targetText.
        PRINT "  DEORBIT PE . " + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + " km".
        PRINT "  TOLERANCE .. " + ROUND(LANDING_CFG["TARGET_TOLERANCE"]/1000,1) + " km".
    }
    PRINT " ".
    PRINT "  -- SEQUENCE --".
    printSequence(seq).
    PRINT " ".
    PRINT "  ========================================".
}

GLOBAL FUNCTION main {
    _applyMissionProfile().
    LOCAL seq IS buildPhaseSequence().
    SET fr3Seq TO seq.
    IF DEFINED launchSeq { SET launchSeq TO seq. }
    IF DEFINED xferSeq { SET xferSeq TO seq. }

    mLogPhase("FR3 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    IF _fr3PhaseBand() = "LAUNCH" {
        confirmLaunch(_printConfig@).
    }

    runPhases(_buildPhaseMap()).
}
