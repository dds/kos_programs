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

// --- Config defaults owned by this file ---
GLOBAL PROBE_ENTRY_PE IS 30000.
GLOBAL PROBE_TARGET_TOL IS 2500.

SET PARKING_ALT TO 100000.
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_AZIMUTH TO 0.
SET LAUNCH_STAGE_LIMIT TO 0.
SET FAIRING_ALT TO 68000.
SET EXTEND_ALT TO 72000.
SET RELAY_ALT TO 0.
SET CAPTURE_PE TO 12500.
SET CAPTURE_INC TO 90.
SET CAPTURE_LAN TO 25.
SET CAPTURE_AOP TO 93.2.
SET CIRC_ECC_TOL TO 0.005.
SET TARGET_INCLINATION TO 90.
SET TARGET_PE TO 326391.
SET TARGET_AP TO 979623.
SET INCL_MATCH_TARGET TO "".
SET INCL_TOLERANCE TO 0.1.
SET MAX_INCL_CHANGE_DV TO 800.
SET PROBE_TARGET_LAT TO 90.0.
SET PROBE_TARGET_LNG TO 0.0.
SET PROBE_ENTRY_PE TO 30000.
SET PROBE_TARGET_TOL TO 2500.
SET MOLNIYA_PERIOD TO 21549.
SET MOLNIYA_AOP TO 90.
SET MOLNIYA_ECC TO 0.3.
SET RECOVERY_PE TO 27500.

applyKnownMissionState().

LOCAL FUNCTION _fallbackLibs {
    RETURN LIST(
        "phases", "flightplan", "launch", "xfer_plan", "capture", "maneuver_orbit",
        "lib_navigation", "countdown", "maneuver", "maneuver_transfer", "inclination",
        "orbit", "deorbit_targeting", "landing",
        "lambert", "maneuver_intersystem", "maneuver_rendezvous",
        "molniya", "payload_ops", "science", "observe", "utils", "config"
    ).
}

GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs().
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    RETURN missionSequenceLibs(_fallbackLibs(), LIST("utils", "config")).
}

LOCAL FUNCTION _buildSequence {
    IF SEQUENCE <> "" {
        RETURN phaseListFromString(SEQUENCE).
    }

    LOCAL orbitPhases IS LIST().
    orbitPhases:ADD("CIRC").
    orbitPhases:ADD("RAISE").
    orbitPhases:ADD("INCLINE").
    IF SCANSAT_RELEASE_AFTER_CAPTURE > 0 {
        SET orbitPhases TO LIST("DROP_FOR_IMPACT_AND_RAISE_PE").
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

LOCAL FUNCTION _printConfig {
    LOCAL seq IS _buildSequence().
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
    flightPlanRow("PARK ALT", ROUND(PARKING_ALT/1000,0) + " km").
    LOCAL incStr IS LAUNCH_INCLINATION + " deg".
    IF LAUNCH_INCLINATION = 0 { SET incStr TO "0 deg  (equatorial)". }
    flightPlanRow("INCL", incStr).
    flightPlanRow("FAIRING", ROUND(FAIRING_ALT/1000,0) + " km").
    IF LAUNCH_STAGE_LIMIT > 0 {
        flightPlanRow("MJ LIMIT", "stage " + LAUNCH_STAGE_LIMIT).
    }
    IF TARGET_ <> "KERBIN" {
        flightPlanSection("TRANSFER").
        flightPlanRow("CAPTURE PE", ROUND(CAPTURE_PE/1000,0) + " km").
        IF CAPTURE_LAN >= 0 {
            flightPlanRow("CAPTURE LAN", ROUND(CAPTURE_LAN,1) + " deg").
        }
        IF CAPTURE_AOP >= 0 {
            flightPlanRow("CAPTURE AOP", ROUND(CAPTURE_AOP,1) + " deg").
        }
        IF CAPTURE_INC >= 0 {
            flightPlanRow("CAPTURE INC", ROUND(CAPTURE_INC,1) + " deg").
        }
    }
    flightPlanSection("ORBIT").
    IF TARGET_PE >= 0 AND TARGET_AP >= 0 {
        flightPlanRow("FINAL PE", ROUND(TARGET_PE/1000,0) + " km").
        flightPlanRow("FINAL AP", ROUND(TARGET_AP/1000,0) + " km").
    } ELSE {
        flightPlanRow("FINAL ALT", ROUND(RELAY_ALT/1000,0) + " km").
    }
    LOCAL tincStr IS TARGET_INCLINATION + " deg".
    IF TARGET_INCLINATION = 0 { SET tincStr TO "0 deg  (equatorial)". }
    flightPlanRow("FINAL INCL", tincStr).
    flightPlanRow("CIRC TOL", "ecc < " + CIRC_ECC_TOL).
    IF hasMolniya {
        printMolniyaSummary().
    }
    IF hasProbe {
        flightPlanSection("PROBE").
        flightPlanRow("IMPACT", ROUND(PROBE_TARGET_LAT,1) + " lat  " + ROUND(PROBE_TARGET_LNG,1) + " lng").
        flightPlanRow("ENTRY PE", ROUND(PROBE_ENTRY_PE/1000,0) + " km").
        flightPlanRow("TOLERANCE", ROUND(PROBE_TARGET_TOL/1000,0) + " km").
    }
    IF hasLander {
        flightPlanSection("LANDING").
        flightPlanRow("TARGET", ROUND(TARGET_LAT,4) + " lat  " + ROUND(TARGET_LNG,4) + " lng").
        flightPlanRow("DEORBIT PE", ROUND(REENTRY_PE/1000,1) + " km").
    }
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
}

LOCAL FUNCTION _phaseRecirc {
    mLog("Re-circularizing relay at " + ROUND(RELAY_ALT/1000,0) + "km.").
    planRecircularize(RELAY_ALT).
    executeManeuver().
    orbitSummary().
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseDeploySat {
    mLog("DEPLOY_SAT: not yet implemented.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _buildPhaseMap {
    LOCAL phaseMap IS LEXICON().
    phaseMapSet(phaseMap, "RECIRC", _phaseRecirc@).
    phaseMapSet(phaseMap, "DEPLOY_SAT", _phaseDeploySat@).
    RETURN phaseMap.
}

GLOBAL FUNCTION main {
    rocketMain("FR2", _buildSequence@, _printConfig@, _buildPhaseMap@).
}
