// ============================================================
// science_surface.ks — bounded landed science/transmission session
// (0:/lib/science_surface.ks). No attitude search, ascent or return.
// Uses the existing typed API; queue submission is not R&D confirmation.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL SCIENCE_SURFACE_DWELL IS 600.
GLOBAL SCIENCE_SURFACE_MIN_EC IS 0.05.

GLOBAL FUNCTION phaseSurfaceScience {
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF ABORT { RETURN. }
    LOCAL groundBody IS SHIP:BODY.
    LOCAL groundStatus IS SHIP:STATUS.
    IF (groundStatus <> "LANDED" AND groundStatus <> "SPLASHED") OR groundBody <> missionTargetBody()
            OR NOT (ABS(SHIP:VERTICALSPEED) <= 0.5 AND SHIP:GROUNDSPEED <= 0.5)
            OR NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
                AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0)
            OR NOT (SCIENCE_SURFACE_DWELL > 0 AND SCIENCE_SURFACE_DWELL <= 3600)
            OR NOT (SCIENCE_SURFACE_MIN_EC >= 0 AND SCIENCE_SURFACE_MIN_EC < 1) {
        mLogError("Surface science requires settled touchdown, idle controls and valid session settings.").
        yieldToPrompt(). RETURN.
    }
    IF NOT thrustCutoffOk() { RETURN. }
    UNLOCK STEERING.
    SAS OFF.
    BRAKES ON.
    LOCAL context IS stateGet("mission_id","")+":"+groundBody:NAME+":"+groundStatus.
    LOCAL flightId IS context+":"+stateGetNum("launch_time",0).
    IF stateGet("surface_science_id","") <> flightId {
        stateSet("surface_science_deadline",TIME:SECONDS+SCIENCE_SURFACE_DWELL).
        stateSet("surface_science_id",flightId).
    }
    LOCAL deadline IS stateGetNum("surface_science_deadline",0).
    IF NOT (deadline > 0 AND deadline < 1e30) {
        mLogError("Saved surface science deadline is invalid; review before resuming.").
        yieldToPrompt(). RETURN.
    }
    LOCAL alarm IS "".
    IF deadline > TIME:SECONDS {
        SET alarm TO kacEnsureAlarm("Surface science review: " + groundBody:NAME,deadline,
            "Landed science session; review stored/transmitted science. No automatic ascent.",1).
    }
    mLog("STATS surface-science setup body=" + groundBody:NAME
        + " deadline=" + deadline + " alarm=" + alarm + " resident=True").
    UNTIL ABORT OR TIME:SECONDS >= deadline OR SHIP:BODY <> groundBody OR SHIP:STATUS <> groundStatus {
        // Remain at1x so native data gathering and transmission can progress.
        // Never turn the landed probe to search for solar power.
        scienceFlightPulse(context,shipPowerFraction() >= SCIENCE_SURFACE_MIN_EC).
        WAIT MIN(1,MAX(0.1,deadline-TIME:SECONDS)).
    }
    SET WARP TO 0.
    IF alarm <> "" { DELETEALARM(alarm). }
    IF ABORT { RETURN. }
    IF SHIP:BODY <> groundBody OR SHIP:STATUS <> groundStatus {
        mLogError("Surface science interrupted: craft left its settled surface state.").
        yieldToPrompt(). RETURN.
    }
    mLog("STATS surface-science result=session-ended homeLink=" + HOMECONNECTION:ISCONNECTED
        + " deliveryConfirmed=False").
    PRINT "Surface science session ended. Review received science and retained data; no automatic ascent.".
    nextPhase(launchSeq).
}
