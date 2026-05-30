// ============================================================
// FSP1.ks  —  Seaplane/submersible flight computer  (0:/craft/FSP1.ks)
//
// Ship name:  FSP1-TARGET-TYPE1-...-NN
// ============================================================

GLOBAL CFG IS LEXICON(
    "CRUISE_ALT",       2000,
    "CRUISE_SPEED",      120,
    "TOP_SPEED",         180,
    "FLAP_AG",             1,
    "SPLASHDOWN_SPEED",   40
).

GLOBAL LIBS IS LIST("phases", "plane", "science", "orbit", "observe").

LOCAL hasSciencePayload IS FALSE.

LOCAL FUNCTION _printConfig {
    LOCAL seq IS LIST("PREFLIGHT", "FLIGHT", "SPLASHDOWN", "SURFACE_OPS", "DONE").
    CLEARSCREEN.
    PRINT "  ========================================".
    PRINT "    FSP1 FLIGHT PLAN    " + SHIP:NAME.
    PRINT "  ========================================".
    PRINT " ".
    PRINT "  TARGET ..... " + MISSION["target"].
    PRINT "  PAYLOADS ... " + MISSION["payloads"].
    PRINT " ".
    PRINT "  -- CRUISE --".
    PRINT "  ALT ........ " + CFG["CRUISE_ALT"] + " m".
    PRINT "  SPEED ...... " + CFG["CRUISE_SPEED"] + " m/s".
    PRINT "  SPLASH SPD . " + CFG["SPLASHDOWN_SPEED"] + " m/s".
    PRINT " ".
    PRINT "  -- SEQUENCE --".
    PRINT "  " + seq:JOIN(" > ").
    PRINT " ".
    PRINT "  ========================================".
}

GLOBAL FUNCTION main {
    LOCAL seq IS LIST("PREFLIGHT", "FLIGHT", "SPLASHDOWN", "SURFACE_OPS", "DONE").
    SET launchSeq TO seq.

    FOR ptype IN missionPayloads() {
        IF ptype:TOUPPER = "SCIENCE" { SET hasSciencePayload TO TRUE. }
    }

    mLogPhase("FSP1 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    _printConfig().

    LOCAL phaseMap IS LEXICON(
        "PREFLIGHT",   _phasePreflight@,
        "FLIGHT",      _phaseFlight@,
        "SPLASHDOWN",  _phaseSplashdown@,
        "SURFACE_OPS", _phaseSurfaceOps@
    ).
    runPhases(phaseMap).
}

LOCAL FUNCTION _phasePreflight {
    mLogPhase("PREFLIGHT").
    planeInit().
    observeStart().

    planePreflightChecklist("FSP1", LIST(
        "Control surfaces — check full deflection",
        "Altimeter — set to RADAR (right-click)",
        "Camera — chase view, raise above tail",
        "Brakes — HOLD until ready",
        "Stage — start engines",
        "Throttle — FULL",
        "Brakes — RELEASE at full thrust",
        "Rotate — pull up at 80 m/s",
        "Gear — retract on positive climb",
        "Splashdown target — " + CFG["SPLASHDOWN_SPEED"] + " m/s"
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
    mLog("Contact detected.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseSplashdown {
    mLogPhase("SPLASHDOWN").
    planeShutdown().
    mLog("Water landing complete.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseSurfaceOps {
    mLogPhase("SURFACE_OPS").
    IF hasSciencePayload {
        scienceRunAll().
        scienceTransmitAll().
        mLog("Water surface science collected.").
    }
    mLog("Dive ops not yet implemented (needs marine.ks).").
    nextPhase(launchSeq).
}
