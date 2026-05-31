// ============================================================
// FR2.ks  —  FR2 vehicle flight computer  (0:/craft/FR2.ks)
//
// Ship name:  FR2-TARGET-TYPE1-TYPE2-...-NN
// e.g.  FR2-MUN-CRASHPROBE1-RELAY1
//       FR2-KERBIN-PROBE-RELAY-POLAR-02
//
// Recognized payload tokens: PROBE, CRASHPROBE, RELAY, SCANSAT, SCISAT, LANDER, MOLNIYA
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
    "RECOVERY_PE",           27500
).

GLOBAL LIBS IS LIST(
    "phases", "launch", "xfer", "mcc",
    "lib_navigation", "countdown", "maneuver", "inclination",
    "orbit", "targeting", "landing",
    "molniya", "payload_ops", "science", "observe", "utils"
).

LOCAL FUNCTION buildPhaseSequence {
    LOCAL hasMolniya IS FALSE.
    FOR ptype IN missionPayloads() {
        IF normalizePayloadType(ptype) = "MOLNIYA" { SET hasMolniya TO TRUE. }
    }

    LOCAL orbitPhases IS LIST().
    IF hasMolniya {
        orbitPhases:ADD("CIRC").
        orbitPhases:ADD("MOLNIYA_INSERT").
    } ELSE {
        orbitPhases:ADD("RAISE").
    }
    orbitPhases:ADD("INCLINE").

    LOCAL payloadPhases IS LEXICON(
        "CRASHPROBE", LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "PROBE",      LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "RELAY",      LIST("RELAY_OPS"),
        "SCANSAT",    LIST("RELAY_OPS"),
        "SCISAT",     LIST("RELAY_OPS"),
        "LANDER",     LIST("LAND_DEORBIT", "LAND")
    ).

    RETURN buildRocketSequence(orbitPhases, payloadPhases).
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

    PRINT "  ========================================".
    PRINT "    FR2 FLIGHT PLAN    " + SHIP:NAME.
    PRINT "  ========================================".
    PRINT " ".
    PRINT "  TARGET ..... " + MISSION["target"].
    PRINT "  PAYLOADS ... " + MISSION["payloads"].
    PRINT " ".
    PRINT "  -- ASCENT --".
    PRINT "  PARK ALT ... " + ROUND(CFG["PARKING_ALT"]/1000,0) + " km".
    LOCAL incStr IS CFG["LAUNCH_INCLINATION"] + " deg".
    IF CFG["LAUNCH_INCLINATION"] = 0 { SET incStr TO "0 deg  (equatorial)". }
    PRINT "  INCL ...... " + incStr.
    PRINT "  FAIRING ... " + ROUND(CFG["FAIRING_ALT"]/1000,0) + " km".
    IF CFG["LAUNCH_STAGE_LIMIT"] > 0 {
        PRINT "  MJ LIMIT .. stage " + CFG["LAUNCH_STAGE_LIMIT"].
    }
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        PRINT " ".
        PRINT "  -- TRANSFER --".
        PRINT "  CAPTURE PE . " + ROUND(CFG["CAPTURE_PE"]/1000,0) + " km".
        IF CFG:HASKEY("CAPTURE_LAN") {
            PRINT "  CAPTURE LAN  " + ROUND(CFG["CAPTURE_LAN"],1) + " deg".
        }
        IF CFG:HASKEY("CAPTURE_AOP") {
            PRINT "  CAPTURE AoP  " + ROUND(CFG["CAPTURE_AOP"],1) + " deg".
        }
        IF CFG:HASKEY("CAPTURE_INC") {
            PRINT "  CAPTURE INC  " + ROUND(CFG["CAPTURE_INC"],1) + " deg".
        }
    }
    PRINT " ".
    PRINT "  -- ORBIT --".
    PRINT "  FINAL ALT .. " + ROUND(CFG["RELAY_ALT"]/1000,0) + " km".
    LOCAL tincStr IS CFG["TARGET_INCLINATION"] + " deg".
    IF CFG["TARGET_INCLINATION"] = 0 { SET tincStr TO "0 deg  (equatorial)". }
    PRINT "  FINAL INCL . " + tincStr.
    PRINT "  CIRC TOL ... ecc < " + CFG["CIRC_ECC_TOL"].
    IF hasMolniya {
        printMolniyaSummary().
    }
    IF hasProbe {
        PRINT " ".
        PRINT "  -- PROBE --".
        PRINT "  IMPACT ..... " + ROUND(CFG["PROBE_TARGET_LAT"],1) + " lat  " + ROUND(CFG["PROBE_TARGET_LNG"],1) + " lng".
        PRINT "  ENTRY PE ... " + ROUND(CFG["PROBE_ENTRY_PE"]/1000,0) + " km".
        PRINT "  TOLERANCE .. " + ROUND(CFG["PROBE_TARGET_TOL"]/1000,0) + " km".
    }
    IF hasLander {
        PRINT " ".
        PRINT "  -- LANDING --".
        PRINT "  TARGET ..... " + ROUND(LANDING_CFG["TARGET_LAT"],4) + " lat  " + ROUND(LANDING_CFG["TARGET_LNG"],4) + " lng".
        PRINT "  DEORBIT PE . " + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + " km".
    }
    PRINT " ".
    PRINT "  -- SEQUENCE --".
    printSequence(seq).
    PRINT " ".
    PRINT "  ========================================".
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
        "XING",             phaseTransfer@,
        "MCC",              phaseMidCourse@,
        "COAST",            phaseCoast@,
        "CAPTURE",          phaseCapture@,
        "CIRC",             phaseCirc@,
        "RAISE",            phaseRaiseAlt@,
        "INCLINE",          phaseInclCorrect@,
        "MOLNIYA_INSERT",   phaseMolniyaInsert@,
        "TARGETED_DEORBIT", phaseTargetedDeorbit@,
        "RELEASE_PROBE",    phaseReleaseProbe@,
        "RECIRC",           _phaseRecirc@,
        "RELAY_OPS",        phaseRelayOps@,
        "DEPLOY_SAT",       _phaseDeploySat@,
        "LAND_DEORBIT",     phaseLandDeorbit@,
        "LAND",             phaseLand@
    ).

    runPhases(phaseMap).
}
