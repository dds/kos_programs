// Deliberate operator stop in a safe orbit, before any target/deorbit choice.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION landingReviewOrbitSafe {
    LOCAL floorAlt IS 0.
    IF SHIP:BODY:ATM:EXISTS { SET floorAlt TO SHIP:BODY:ATM:HEIGHT+5000. }
    RETURN SHIP = KUNIVERSE:ACTIVEVESSEL AND NOT ABORT AND WARP = 0
        AND SHIP:BODY:NAME = getTarget() AND SHIP:STATUS = "ORBITING"
        AND NOT SHIP:ORBIT:HASNEXTPATCH
        AND SHIP:PERIAPSIS > floorAlt AND SHIP:PERIAPSIS < 1e30
        AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0
        AND NOT (stateGet("burn_pending","false") = "true" AND stateGet("burn_started","false") = "true")
        AND stateGet("deorbit_burn_started","false") <> "true".
}

GLOBAL FUNCTION phaseLandingReview {
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF NOT landingReviewOrbitSafe() OR HASNODE {
        mLogError("Landing review requires a safe idle parking orbit. Existing nodes and mission retained.").
        yieldToPrompt(). RETURN.
    }
    IF NOT thrustCutoffOk() { RETURN. }
    orbitSummary().
    // No known operator deadline: no fictitious timer or periodic wake.
    orientForSolar(FALSE,TRUE,FALSE,TIME:SECONDS+60).
    PRINT "PARKED FOR SURVEY: choose a landing site when the maps are ready.".
    PRINT "No deorbit will start until you explicitly select the site.".
    PRINT "Select a waypoint on this body, then run:".
    PRINT "RUNPATH(" + CHAR(34) + "0:/cmd/landsite.ks" + CHAR(34) + ").".
    PRINT "Or pass LEXICON(lat,latitude,lng,longitude) with quoted keys and numeric degrees.".
    PRINT "Then REBOOT. The command preserves the mission and checks orbital reachability.".
    mLogSummary("STATS landing-review body=" + SHIP:BODY:NAME + " automaticResume=False"
        + " inc=" + SHIP:ORBIT:INCLINATION + " remainingDv=" + SHIP:DELTAV:VACUUM).
    yieldToPrompt().
}
