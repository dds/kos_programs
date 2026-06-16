// Landing descent phase wrappers.

GLOBAL FUNCTION phaseLandAssist {
    landingApplyMissionConfig().
    mLogWarn("STATS land-assist phase setup alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)).
    IF _redirectOrbitalLandingPhase("LAND_ASSIST") { RETURN. }
    IF CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH") AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0 {
        mLogWarn("STATS landing-impact skipped reason=sim-no-target-search").
    } ELSE IF NOT landingImpactAcceptableForAssist() {
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
    mLogWarn("STATS land-assist phase result ok=" + assistOk
        + " alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " status=" + SHIP:STATUS).
    IF NOT assistOk {
        mLogError("Landing assist failed; holding current phase for manual review.").
        stateSet("phase", "LAND_ASSIST").
        LOCK THROTTLE TO 0.
        PRINT " ".
        PRINT "  LANDING ASSIST FAILED".
        PRINT "  Review target, decoupler tag, attitude, fuel, and phase before resuming.".
        yieldToPrompt().
        RETURN.
    }
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseLand {
    landingApplyMissionConfig().
    mLogWarn("STATS land phase setup alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)
        + " status=" + SHIP:STATUS).

    IF _redirectOrbitalLandingPhase("LAND") { RETURN. }

    landExecute().
    mLogWarn("STATS land phase result alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)
        + " status=" + SHIP:STATUS).
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
