// ============================================================
// FR3.ks  —  FR3 vehicle flight computer  (0:/craft/FR3.ks)
//
// Ship name:  FR3-TARGET-TYPE1-TYPE2-...-NN
// Payload tokens: RELAY, SCANSAT, SCISAT, LANDER, PROBE, CRASHPROBE
// ============================================================

GLOBAL CFG IS LEXICON(
    "PARKING_ALT",         120000,
    "LAUNCH_INCLINATION",       90,
    "LAUNCH_AZIMUTH",           0,
    "LAUNCH_STAGE_LIMIT",       0,
    "FAIRING_ALT",          68000,
    "EXTEND_ALT",           72000,
    "RELAY_ALT",           1000000,
    "CAPTURE_PE",            20000,
    "CIRC_ECC_TOL",          0.005,
    "TARGET_INCLINATION",      90,
    "INCL_MATCH_TARGET",       "",
    "INCL_TOLERANCE",         0.01,
    "MAX_INCL_CHANGE_DV",     200,
    "PROBE_TARGET_LAT",       90.0,
    "PROBE_TARGET_LNG",         0.0,
    "PROBE_ENTRY_PE",         30000,
    "PROBE_TARGET_TOL",        2500,
    "RECOVERY_PE",           32000
).

GLOBAL LIBS IS LIST(
    "phases", "launch", "xfer", "mcc",
    "lib_navigation", "countdown", "maneuver", "inclination",
    "orbit", "targeting", 
    "payload_ops", "utils", "rsvp"
).

LOCAL FUNCTION buildPhaseSequence {
    LOCAL orbitPhases IS LIST("CIRC", "RAISE", "INCLINE").

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
    PRINT "  ========================================".
    PRINT "    FR3 FLIGHT PLAN    " + SHIP:NAME.
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
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        PRINT " ".
        PRINT "  -- TRANSFER --".
        PRINT "  CAPTURE PE . " + ROUND(CFG["CAPTURE_PE"]/1000,0) + " km".
    }
    PRINT " ".
    PRINT "  -- ORBIT --".
    PRINT "  FINAL ALT .. " + ROUND(CFG["RELAY_ALT"]/1000,0) + " km".
    LOCAL tincStr IS CFG["TARGET_INCLINATION"] + " deg".
    IF CFG["TARGET_INCLINATION"] = 0 { SET tincStr TO "0 deg  (equatorial)". }
    PRINT "  FINAL INCL . " + tincStr.
    PRINT "  CIRC TOL ... ecc < " + CFG["CIRC_ECC_TOL"].
    PRINT " ".
    PRINT "  -- SEQUENCE --".
    printSequence(seq).
    PRINT " ".
    PRINT "  ========================================".
}

GLOBAL FUNCTION main {
    LOCAL seq IS buildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FR3 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    confirmLaunch(_printConfig@).

    LOCAL phaseMap IS LEXICON(
        "LUNCH", phaseLaunch@,
        "FAIR", phaseFairing@,
        "ANTS",             phaseExtendAnts@,
        "PARK",          phaseParking@,
        "XING",         phaseTransfer@,
        "MCC",              phaseMidCourse@,
        "COAST",            phaseCoast@,
        "CAPTURE",          phaseCapture@,
        "CIRC",             phaseCirc@,
        "RAISE",        phaseRaiseAlt@,
        "INCLINE",     phaseInclCorrect@,
        "TARGETED_DEORBIT", phaseTargetedDeorbit@,
        "RELEASE_PROBE",    phaseReleaseProbe@,
        "RELAY_OPS",        phaseRelayOps@,
        "LAND_DEORBIT",     phaseLandDeorbit@,
        "LAND",             phaseLand@
    ).

    runPhases(phaseMap).
}
