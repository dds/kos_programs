// ============================================================
// FJ4B.ks  —  Supersonic jet flight computer  (0:/craft/FJ4B.ks)
//
// Manually-flown jet with autopilot assists.
// Ship name:  FJ4B-TARGET-TYPE1-...-NN
// ============================================================

GLOBAL CFG IS LEXICON(
    "CRUISE_ALT",    5000,
    "CRUISE_SPEED",   300,
    "FLAP_AG",          1
).

GLOBAL LIBS IS LIST("phases", "plane", "science", "orbit", "observe").

LOCAL hasSciencePayload IS FALSE.

LOCAL FUNCTION _printConfig {
    LOCAL seq IS LIST("PREFLIGHT", "FLIGHT", "POST_FLIGHT", "DONE").
    CLEARSCREEN.
    PRINT "  ========================================".
    PRINT "    FJ4B FLIGHT PLAN    " + SHIP:NAME.
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

    mLogPhase("FJ4B MAIN").
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

    planePreflightChecklist("FJ4B", LIST(
        "Control surfaces — check full deflection",
        "Altimeter — set to RADAR (right-click)",
        "Camera — chase view, raise above tail",
        "Brakes — HOLD until ready",
        "Stage — start engines",
        "Throttle — FULL",
        "Brakes — RELEASE at full thrust",
        "Rotate — pull up at 120 m/s",
        "Gear — retract on positive climb",
        "Climb — level off, accelerate to 200 m/s"
    )).

    WAIT UNTIL SHIP:STATUS = "FLYING" OR SHIP:AIRSPEED > 50.
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
