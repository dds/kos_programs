// ============================================================
// FJ1A.ks  —  Juno trainer jet flight computer  (0:/craft/FJ1A.ks)
//
// Single/dual Juno trainer. Broad wings, low speed, fun to fly.
// Ship name:  FJ1A-TARGET-TYPE1-...-NN
// ============================================================

GLOBAL CFG IS LEXICON(
    "CRUISE_ALT",    5000,
    "CRUISE_SPEED",   150,
    "FLAP_AG",          1
).

GLOBAL LIBS IS LIST("phases", "plane", "science", "orbit", "observe").

LOCAL hasSciencePayload IS FALSE.

LOCAL FUNCTION _printConfig {
    LOCAL seq IS LIST("PREFLIGHT", "FLIGHT", "POST_FLIGHT", "DONE").
    CLEARSCREEN.
    PRINT "  ========================================".
    PRINT "    FJ1A FLIGHT PLAN    " + SHIP:NAME.
    PRINT "  ========================================".
    PRINT " ".
    PRINT "  TARGET ..... " + MISSION["target"].
    PRINT "  PAYLOADS ... " + MISSION["payloads"].
    PRINT " ".
    PRINT "  -- CRUISE --".
    PRINT "  ALT ........ " + CFG["CRUISE_ALT"] + " m".
    PRINT "  SPEED ...... " + CFG["CRUISE_SPEED"] + " m/s".
    PRINT " ".
    PRINT "  -- SEQUENCE --".
    PRINT "  " + seq:JOIN(" > ").
    PRINT " ".
    PRINT "  ========================================".
}

GLOBAL FUNCTION main {
    LOCAL seq IS LIST("PREFLIGHT", "FLIGHT", "POST_FLIGHT", "DONE").
    SET launchSeq TO seq.

    FOR ptype IN missionPayloads() {
        IF ptype:TOUPPER = "SCIENCE" { SET hasSciencePayload TO TRUE. }
    }

    mLogPhase("FJ1A MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    _printConfig().

    LOCAL phaseMap IS LEXICON(
        "PREFLIGHT",   _phasePreflight@,
        "FLIGHT",      _phaseFlight@,
        "POST_FLIGHT", _phasePostFlight@
    ).
    runPhases(phaseMap).
}

LOCAL FUNCTION _phasePreflight {
    mLogPhase("PREFLIGHT").
    planeInit().
    observeStart().

    CLEARSCREEN.
    PRINT "  ========================================".
    PRINT "    FJ1A PREFLIGHT CHECKLIST".
    PRINT "  ========================================".
    PRINT " ".
    PRINT "  [ ] Control surfaces — check full deflection".
    PRINT "  [ ] Altimeter — set to RADAR (right-click)".
    PRINT "  [ ] Camera — chase view, raise above tail".
    PRINT "  [ ] Brakes — HOLD until ready".
    PRINT "  [ ] Stage — start engines".
    PRINT "  [ ] Throttle — FULL".
    PRINT "  [ ] Brakes — RELEASE at full thrust".
    PRINT "  [ ] Rotate — pull up at 80 m/s".
    PRINT "  [ ] Gear — retract on positive climb".
    PRINT "  [ ] Climb — level off, accelerate to 120 m/s".
    PRINT " ".
    PRINT "  -- ENVIRONMENT --".
    PRINT "  Airspeed .... " + ROUND(SHIP:AIRSPEED,1) + " m/s".
    PRINT "  Heading ..... " + ROUND(SHIP:FACING:YAW,1) + " deg".
    PRINT "  Stall speed . " + PLANE_CFG["STALL_SPEED"] + " m/s".
    PRINT "  Storage ..... " + CORE:VOLUME:FREESPACE + " bytes free".
    PRINT " ".
    PRINT "  >> Press any key when ready for takeoff".

    TERMINAL:INPUT:GETCHAR().
    PRINT " ".
    PRINT "  Takeoff clearance given.".
    mLog("Takeoff clearance given.").

    WAIT UNTIL SHIP:STATUS = "FLYING" OR SHIP:AIRSPEED > 30.
    mLog("Airborne.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseFlight {
    mLogPhase("FLIGHT").
    IF hasSciencePayload { scienceInit(). }
    mLog("Flight active. Monitoring until landing.").
    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        planeUpdate().
        IF hasSciencePayload { scienceRunAll(). }
        WAIT 0.1.
    }
    mLog("Touchdown detected.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phasePostFlight {
    mLogPhase("POST_FLIGHT").
    IF hasSciencePayload { scienceTransmitAll(). }
    planeLandingAssist().
    planeShutdown().
    mLog("Post-flight complete.").
    nextPhase(launchSeq).
}
