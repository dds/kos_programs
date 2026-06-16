// Landing descent phase wrappers.

GLOBAL FUNCTION phaseLandAssist {
    landingApplyMissionConfig().
    IF _redirectOrbitalLandingPhase("LAND_ASSIST") { RETURN. }
    IF NOT (CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH") AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0)
            AND NOT landingImpactAcceptableForAssist() {
        mLogError("Predicted landing impact is not within target tolerance; holding LAND_ASSIST.").
        stateSet("phase", "LAND_ASSIST").
        LOCK THROTTLE TO 0.
        PRINT " ".
        PRINT "  LANDING IMPACT CHECK FAILED".
        PRINT "  Replan deorbit or verify selected waypoint before descent.".
        yieldToPrompt().
        RETURN.
    }
    LOCAL assistOk IS landingAssistStage().
    IF NOT assistOk {
        mLogError("Landing assist failed; holding current phase for manual review.").
        stateSet("phase", "LAND_ASSIST").
        LOCK THROTTLE TO 0.
        PRINT " ".
        PRINT "  LANDING ASSIST FAILED".
        PRINT "  Review target, attitude, fuel, and phase before resuming.".
        yieldToPrompt().
        RETURN.
    }
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseLand {
    landingApplyMissionConfig().

    IF _redirectOrbitalLandingPhase("LAND") { RETURN. }

    landExecute().
    nextPhase(launchSeq).
}

LOCAL FUNCTION _redirectOrbitalLandingPhase {
    PARAMETER phaseName.
    IF (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "SUB_ORBITAL")
            AND SHIP:PERIAPSIS > LANDING_CFG["DEORBIT_PE"] {
        mLogWarn(phaseName + " requested while still in orbit; returning to LAND_DEORBIT.").
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  LANDING TARGET CHECK".
        PRINT "  Select the landing waypoint in map/navigation.".
        PRINT "  Phase reset to LAND_DEORBIT. Resume manually when ready.".
        yieldToPrompt().
        RETURN TRUE.
    }
    RETURN FALSE.
}

GLOBAL FUNCTION phaseRover {
    roverInit().
    roverHUD().
}
