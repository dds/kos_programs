// ============================================================
// FR2.ks  —  FR2 vehicle flight computer  (0:/craft/FR2.ks)
//
// Ship name:  FR2-TARGET-TYPE1-TYPE2-...-NN
// e.g.  FR2-MUN-CRASHPROBE1-RELAY1
//       FR2-KERBIN-PROBE-RELAY-POLAR-02
//
// Recognized payload tokens: PROBE, CRASHPROBE, RELAY, SCANSAT, SCISAT, LANDER, ASSISTLANDER, MOLNIYA
// Anything else (POLAR, 02, etc.) is ignored.
// ============================================================

GLOBAL CFG IS LEXICON(
    "PARKING_ALT",         100000,
    "LAUNCH_INCLINATION",       0,
    "LAUNCH_AZIMUTH",           0,
    "LAUNCH_STAGE_LIMIT",       0,
    "FAIRING_ALT",          68000,
    "EXTEND_ALT",           72000,
    "RELAY_ALT",                0,
    "CAPTURE_PE",            12500,
    "CAPTURE_INC",              90,
    "CAPTURE_LAN",              25,
    "CAPTURE_AOP",            93.2,
    "CIRC_ECC_TOL",          0.005,
    "TARGET_INCLINATION",       90,
    "TARGET_PE",              326391,
    "TARGET_AP",             979623,
    "INCL_MATCH_TARGET",       "",
    "INCL_TOLERANCE",          0.1,
    "MAX_INCL_CHANGE_DV",     800,
    "PROBE_TARGET_LAT",       90.0,
    "PROBE_TARGET_LNG",         0.0,
    "PROBE_ENTRY_PE",         30000,
    "PROBE_TARGET_TOL",        2500,
    "MOLNIYA_PERIOD",         21549,
    "MOLNIYA_AOP",               90,
    "MOLNIYA_ECC",               0.3,
    "RECOVERY_PE",            27500
).

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
        "RELAY_ALT", "CAPTURE_PE", "CAPTURE_INC", "CAPTURE_LAN",
        "CAPTURE_AOP", "TARGET_PE", "TARGET_AP",
        "TARGET_INCLINATION", "CIRC_ECC_TOL", "INCL_TOLERANCE",
        "MAX_INCL_CHANGE_DV", "PROBE_TARGET_LAT", "PROBE_TARGET_LNG",
        "PROBE_ENTRY_PE", "PROBE_TARGET_TOL", "MOLNIYA_PERIOD",
        "MOLNIYA_AOP", "MOLNIYA_ECC", "RECOVERY_PE",
        "PROGRESSIVE_RELOAD", "RELOAD_AFTER_PARK",
        "SCANSAT_DISPOSE_CARRIER", "SCANSAT_DISPOSE_PE",
        "SCANSAT_DISPOSE_MAX_TIME", "SCANSAT_DISPOSE_BEFORE_RELEASE",
        "SCANSAT_STAGE_AFTER_RELEASE", "SCANSAT_RECOVERY_PE",
        "SCANSAT_RECOVERY_AP", "SCANSAT_RELEASE_AFTER_CAPTURE"
    ) {
        _cfgFromState(key, TRUE).
    }

    FOR key IN LIST(
        "SEQUENCE", "CAPTURE_DIR", "INCL_MATCH_TARGET",
        "SCANSAT_DECOUPLER_TAG", "PROBE_TARGET_WAYPOINT",
        "LANDING_TARGET_WAYPOINT"
    ) {
        _cfgFromState(key, FALSE).
    }
}

_applyMissionState().

GLOBAL LIBS IS LIST(
    "phases", "flightplan", "launch", "xfer",
    "lib_navigation", "countdown", "maneuver", "inclination",
    "orbit", "targeting", "landing",
    "lambert", "maneuver_intersystem", "maneuver_rendezvous",
    "molniya", "payload_ops", "science", "observe", "utils"
).

LOCAL FUNCTION buildPhaseSequence {
    IF CFG:HASKEY("SEQUENCE") {
        RETURN _phaseListFromString(CFG["SEQUENCE"]).
    }

    LOCAL hasMolniya IS FALSE.
    FOR ptype IN missionPayloads() {
        IF normalizePayloadType(ptype) = "MOLNIYA" { SET hasMolniya TO TRUE. }
    }

    LOCAL orbitPhases IS LIST().
    // IF hasMolniya {
    //     orbitPhases:ADD("CIRC").
    //     orbitPhases:ADD("MOLNIYA_INSERT").
    // } ELSE {
    //     orbitPhases:ADD("RAISE").
    // }
    // orbitPhases:ADD("INCLINE").

    orbitPhases:ADD("CIRC").
    orbitPhases:ADD("RAISE").
    orbitPhases:ADD("INCLINE").
    IF CFG:HASKEY("SCANSAT_RELEASE_AFTER_CAPTURE")
            AND CFG["SCANSAT_RELEASE_AFTER_CAPTURE"] > 0 {
        SET orbitPhases TO LIST("SCANSAT_IMPACT_RELEASE").
    }

    LOCAL payloadPhases IS LEXICON(
        "CRASHPROBE", LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "PROBE",      LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "RELAY",      LIST("RELAY_OPS"),
        "SCANSAT",    LIST("SCANSAT_OPS"),
        "SCISAT",     LIST("RELAY_OPS"),
        "ASSISTLANDER", LIST("LAND_DEORBIT", "LAND_ASSIST", "LAND"),
        "LANDER",     LIST("LAND_DEORBIT", "LAND")
    ).

    RETURN buildRocketSequence(orbitPhases, payloadPhases).
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

LOCAL FUNCTION _printConfig {
    LOCAL seq IS buildPhaseSequence().
    LOCAL hasProbe IS FALSE.
    LOCAL hasLander IS FALSE.
    LOCAL hasMolniya IS FALSE.
    FOR ptype IN missionPayloads() {
        LOCAL t IS normalizePayloadType(ptype).
        IF t = "CRASHPROBE" OR t = "PROBE" { SET hasProbe TO TRUE. }
        IF t = "LANDER" { SET hasLander TO TRUE. }
        IF t = "MOLNIYA" { SET hasMolniya TO TRUE. }
    }

    flightPlanTitle("FR2 FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("ASCENT").
    flightPlanRow("PARK ALT", ROUND(CFG["PARKING_ALT"]/1000,0) + " km").
    LOCAL incStr IS CFG["LAUNCH_INCLINATION"] + " deg".
    IF CFG["LAUNCH_INCLINATION"] = 0 { SET incStr TO "0 deg  (equatorial)". }
    flightPlanRow("INCL", incStr).
    flightPlanRow("FAIRING", ROUND(CFG["FAIRING_ALT"]/1000,0) + " km").
    IF CFG["LAUNCH_STAGE_LIMIT"] > 0 {
        flightPlanRow("MJ LIMIT", "stage " + CFG["LAUNCH_STAGE_LIMIT"]).
    }
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        flightPlanSection("TRANSFER").
        flightPlanRow("CAPTURE PE", ROUND(CFG["CAPTURE_PE"]/1000,0) + " km").
        IF CFG:HASKEY("CAPTURE_LAN") {
            flightPlanRow("CAPTURE LAN", ROUND(CFG["CAPTURE_LAN"],1) + " deg").
        }
        IF CFG:HASKEY("CAPTURE_AOP") {
            flightPlanRow("CAPTURE AOP", ROUND(CFG["CAPTURE_AOP"],1) + " deg").
        }
        IF CFG:HASKEY("CAPTURE_INC") {
            flightPlanRow("CAPTURE INC", ROUND(CFG["CAPTURE_INC"],1) + " deg").
        }
    }
    flightPlanSection("ORBIT").
    IF CFG:HASKEY("TARGET_PE") AND CFG:HASKEY("TARGET_AP") {
        flightPlanRow("FINAL PE", ROUND(CFG["TARGET_PE"]/1000,0) + " km").
        flightPlanRow("FINAL AP", ROUND(CFG["TARGET_AP"]/1000,0) + " km").
    } ELSE {
        flightPlanRow("FINAL ALT", ROUND(CFG["RELAY_ALT"]/1000,0) + " km").
    }
    LOCAL tincStr IS CFG["TARGET_INCLINATION"] + " deg".
    IF CFG["TARGET_INCLINATION"] = 0 { SET tincStr TO "0 deg  (equatorial)". }
    flightPlanRow("FINAL INCL", tincStr).
    flightPlanRow("CIRC TOL", "ecc < " + CFG["CIRC_ECC_TOL"]).
    IF hasMolniya {
        printMolniyaSummary().
    }
    IF hasProbe {
        flightPlanSection("PROBE").
        flightPlanRow("IMPACT", ROUND(CFG["PROBE_TARGET_LAT"],1) + " lat  " + ROUND(CFG["PROBE_TARGET_LNG"],1) + " lng").
        flightPlanRow("ENTRY PE", ROUND(CFG["PROBE_ENTRY_PE"]/1000,0) + " km").
        flightPlanRow("TOLERANCE", ROUND(CFG["PROBE_TARGET_TOL"]/1000,0) + " km").
    }
    IF hasLander {
        flightPlanSection("LANDING").
        flightPlanRow("TARGET", ROUND(LANDING_CFG["TARGET_LAT"],4) + " lat  " + ROUND(LANDING_CFG["TARGET_LNG"],4) + " lng").
        flightPlanRow("DEORBIT PE", ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + " km").
    }
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
    flightPlanLine().
}

LOCAL FUNCTION _phaseRecirc {
    mLog("Re-circularizing relay at " + ROUND(CFG["RELAY_ALT"]/1000,0) + "km.").
    planRecircularize(CFG["RELAY_ALT"]).
    executeManeuver().
    orbitSummary().
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseDeploySat {
    mLog("DEPLOY_SAT: not yet implemented.").
    nextPhase(launchSeq).
}

GLOBAL FUNCTION main {
    LOCAL seq IS buildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FR2 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    confirmLaunch(_printConfig@).

    LOCAL phaseMap IS LEXICON(
        "LUNCH",            phaseLaunch@,
        "FAIR",             phaseFairing@,
        "ANTS",             phaseExtendAnts@,
        "PARK",             phaseParking@,
        "RDV",              phaseRendezvous@,
        "XING",             phaseTransfer@,
        "MCC",              phaseMidCourse@,
        "COAST",            phaseCoast@,
        "CAPTURE",          phaseCapture@,
        "CIRC",             phaseCirc@,
        "RAISE",            phaseRaiseAlt@,
        "INCLINE",          phaseInclCorrect@,
        "ELLIPTICAL",       phaseElliptical@,
        // "MOLNIYA_INSERT",   phaseMolniyaInsert@,
        "TARGETED_DEORBIT", phaseTargetedDeorbit@,
        "RELEASE_PROBE",    phaseReleaseProbe@,
        "RECIRC",           _phaseRecirc@,
        "RELAY_OPS",        phaseRelayOps@,
        "SCANSAT_IMPACT_RELEASE", phaseScanSatImpactRelease@,
        "SCANSAT_OPS",      phaseScanSatOps@,
        "DEPLOY_SAT",       _phaseDeploySat@,
        "LAND_DEORBIT",     phaseLandDeorbit@,
        "LAND_ASSIST",      phaseLandAssist@,
        "LAND",             phaseLand@
    ).

    runPhases(phaseMap).
}
