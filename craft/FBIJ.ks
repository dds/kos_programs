// ============================================================
// FBIJ.ks  -  Fast business jet flight computer  (0:/craft/FBIJ.ks)
//
// Citation-style executive jet. Select the contract waypoint in
// Waypoint Manager, then press AG8 after takeoff to load and fly it.
// Ship name:  FBIJ-TARGET-TYPE1-...-NN
// ============================================================

GLOBAL CFG IS LEXICON(
    "CRUISE_ALT",    9000,
    "CRUISE_SPEED",   280,
    "TOP_SPEED",      360,
    "FLAP_AG",          1,
    "AIRBORNE_RADAR_ALT", 8,
    "FINAL_LANDING_SPEED", 35,
    "MIN_FLIGHT_TIME", 60
).

GLOBAL FBIJ_SEQ IS LIST("PREFLIGHT", "FLIGHT", "POSTFLIGHT", "DONE").

GLOBAL FUNCTION fbijSequence {
    LOCAL rawSeq IS stateGet("mission_cfg_SEQUENCE", "").
    IF rawSeq <> "" { RETURN phaseListFromString(rawSeq). }
    RETURN FBIJ_SEQ.
}

IF stateGet("phase", "") = "" {
    LOCAL startupSeq IS fbijSequence().
    stateSet("phase", startupSeq[0]).
}

LOCAL FUNCTION _hasSciencePayload {
    LOCAL rawPayloads IS stateGet("payloads", "").
    IF rawPayloads = "" { RETURN FALSE. }
    FOR ptype IN rawPayloads:SPLIT(",") {
        IF ptype = "SCIENCE" { RETURN TRUE. }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _flightLibs {
    LOCAL libs IS missionLibsForPhases(fbijSequence(), LIST("orbit", "airplane")).
    IF _hasSciencePayload() { libs:ADD("science"). }
    RETURN libs.
}

GLOBAL FUNCTION bootVehicleLibs {
    LOCAL libs IS missionSequenceLibs(_flightLibs(), LIST("orbit", "airplane")).
    stateSet("lib_band", "PREFLIGHT").
    stateSet("lib_band_phase", stateGet("phase", "PREFLIGHT")).
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

LOCAL hasSciencePayload IS FALSE.

LOCAL FUNCTION _fbijCfgNum {
    PARAMETER key.
    PARAMETER defaultValue.
    IF CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _fbijAirborne {
    IF SHIP:STATUS = "SUB_ORBITAL" OR SHIP:STATUS = "ORBITING" { RETURN TRUE. }
    RETURN SHIP:STATUS = "FLYING"
        AND ALT:RADAR > _fbijCfgNum("AIRBORNE_RADAR_ALT", 8).
}

LOCAL FUNCTION _fbijFinalLanding {
    PARAMETER airborneTime.
    LOCAL onGround IS SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    IF NOT onGround { RETURN FALSE. }
    IF TIME:SECONDS - airborneTime < _fbijCfgNum("MIN_FLIGHT_TIME", 60) { RETURN FALSE. }
    RETURN SHIP:AIRSPEED <= _fbijCfgNum("FINAL_LANDING_SPEED", 35).
}

LOCAL FUNCTION _printConfig {
    LOCAL seq IS fbijSequence().
    flightPlanTitle("FBIJ FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("BUSINESS JET").
    flightPlanRow("ALT", CFG["CRUISE_ALT"] + " m").
    flightPlanRow("SPEED", CFG["CRUISE_SPEED"] + " m/s").
    flightPlanRow("FINAL STOP", CFG["FINAL_LANDING_SPEED"] + " m/s").
    flightPlanRow("NAV", "Select waypoint, AG8 to fly").
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
}

GLOBAL FUNCTION main {
    LOCAL seq IS fbijSequence().
    SET launchSeq TO seq.

    FOR ptype IN missionPayloads() {
        IF ptype = "SCIENCE" { SET hasSciencePayload TO TRUE. }
    }

    mLogPhase("FBIJ MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    _printConfig().

    LOCAL phaseMap IS LEXICON(
        "PREFLIGHT",   _phasePreflight@,
        "FLIGHT",      _phaseFlight@,
        "POSTFLIGHT",  _phasePostFlight@,
        "POST_FLIGHT", _phasePostFlight@
    ).
    runPhases(phaseMap).
}

LOCAL FUNCTION _phasePreflight {
    mLogPhase("PREFLIGHT").
    planeInit().
    observeStart().

    planePreflightChecklist("FBIJ", LIST(
        "Passengers - seated and emotionally prepared",
        "Waypoint Manager - select destination",
        "Control surfaces - check full deflection",
        "Flaps - takeoff setting",
        "Brakes - HOLD until ready",
        "Stage - start engines",
        "Throttle - FULL",
        "Brakes - RELEASE at full thrust",
        "Rotate - pull up at 105 m/s",
        "Gear - retract on positive climb",
        "Navigation - press AG8 after stable climb"
    )).

    WAIT UNTIL _fbijAirborne().
    mLog("Airborne.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseFlight {
    mLogPhase("FLIGHT").
    IF hasSciencePayload { scienceInit(). }

    mLog("Flight active. Select a waypoint and press AG8 for business jet nav.").
    WAIT UNTIL _fbijAirborne().
    LOCAL airborneTime IS TIME:SECONDS.
    mLog("Airborne confirmed; monitoring until final slow landing.").

    UNTIL _fbijFinalLanding(airborneTime) {
        planeUpdate().
        IF hasSciencePayload { scienceRunAll(). }
        WAIT 0.1.
    }
    mLog("Final landing detected.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phasePostFlight {
    mLogPhase("POSTFLIGHT").
    IF hasSciencePayload { scienceTransmitAll(). }
    planeLandingAssist().
    planeShutdown().
    mLog("Passengers delivered. FBIJ flight complete.").
    nextPhase(launchSeq).
}
