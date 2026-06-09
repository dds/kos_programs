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
    "FLAP_AG",          1
).

GLOBAL FBIJ_SEQ IS LIST("PREFLIGHT", "FLIGHT", "POST_FLIGHT", "DONE").
IF stateGet("phase", "") = "" {
    stateSet("phase", FBIJ_SEQ[0]).
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
    LOCAL libs IS missionLibsForPhases(FBIJ_SEQ, LIST("orbit")).
    IF _hasSciencePayload() { libs:ADD("science"). }
    RETURN libs.
}

GLOBAL FUNCTION bootVehicleLibs {
    RETURN missionSequenceLibs(_flightLibs(), LIST("orbit")).
}

LOCAL hasSciencePayload IS FALSE.

LOCAL FUNCTION _printConfig {
    LOCAL seq IS FBIJ_SEQ.
    flightPlanTitle("FBIJ FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("BUSINESS JET").
    flightPlanRow("ALT", CFG["CRUISE_ALT"] + " m").
    flightPlanRow("SPEED", CFG["CRUISE_SPEED"] + " m/s").
    flightPlanRow("NAV", "Select waypoint, AG8 to fly").
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
}

GLOBAL FUNCTION main {
    LOCAL seq IS FBIJ_SEQ.
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
        "POST_FLIGHT", _phasePostFlight@
    ).
    runPhases(phaseMap).
}

GLOBAL vehicleMain IS main@.

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

    WAIT UNTIL SHIP:STATUS = "FLYING" OR SHIP:AIRSPEED > 50.
    mLog("Airborne.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseFlight {
    mLogPhase("FLIGHT").
    IF hasSciencePayload { scienceInit(). }

    mLog("Flight active. Select a waypoint and press AG8 for business jet nav.").
    WAIT UNTIL SHIP:STATUS = "FLYING" OR SHIP:STATUS = "SUB_ORBITAL"
        OR SHIP:STATUS = "ORBITING".

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
    mLog("Passengers delivered. FBIJ flight complete.").
    nextPhase(launchSeq).
}
