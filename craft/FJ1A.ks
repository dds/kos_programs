// ============================================================
// FJ1A.ks  —  Juno trainer jet flight computer  (0:/craft/FJ1A.ks)
//
// Single/dual Juno trainer. Broad wings, low speed, fun to fly.
// Ship name:  FJ1A-TARGET-TYPE1-...-NN
// ============================================================

GLOBAL CFG IS LEXICON(
    "CRUISE_ALT",    5000,
    "CRUISE_SPEED",   140,
    "TOP_SPEED",      230,
    "FLAP_AG",          1
).

LOCAL flightSeq IS LIST("PREFLIGHT", "FLIGHT", "POST_FLIGHT", "DONE").

LOCAL FUNCTION _hasSciencePayload {
    LOCAL rawPayloads IS stateGet("payloads", "").
    IF rawPayloads = "" { RETURN FALSE. }
    FOR ptype IN rawPayloads:SPLIT(",") {
        IF ptype = "SCIENCE" { RETURN TRUE. }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _flightLibs {
    LOCAL libs IS missionLibsForPhases(flightSeq, LIST("orbit")).
    IF _hasSciencePayload() { libs:ADD("science"). }
    RETURN libs.
}

GLOBAL FUNCTION bootVehicleLibs {
    RETURN missionSequenceLibs(_flightLibs(), LIST("orbit")).
}

LOCAL hasSciencePayload IS FALSE.

LOCAL FUNCTION _printConfig {
    LOCAL seq IS flightSeq.
    flightPlanTitle("FJ1A FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("CRUISE").
    flightPlanRow("ALT", CFG["CRUISE_ALT"] + " m").
    flightPlanRow("SPEED", CFG["CRUISE_SPEED"] + " m/s").
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
}

GLOBAL FUNCTION main {
    LOCAL seq IS flightSeq.
    SET launchSeq TO seq.

    FOR ptype IN missionPayloads() {
        IF ptype = "SCIENCE" { SET hasSciencePayload TO TRUE. }
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

    planePreflightChecklist("FJ1A", LIST(
        "Control surfaces - check full deflection",
        "Altimeter - set to RADAR (right-click)",
        "Camera - chase view, raise above tail",
        "Brakes - HOLD until ready",
        "Stage - start engines",
        "Throttle - FULL",
        "Brakes - RELEASE at full thrust",
        "Rotate - pull up at 80 m/s",
        "Gear - retract on positive climb",
        "Climb - level off, accelerate to 120 m/s"
    )).

    WAIT UNTIL SHIP:STATUS = "FLYING".
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
