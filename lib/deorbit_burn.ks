// Compact deorbit node executor for storage-limited landing bands.

GLOBAL FUNCTION executeDeorbitNode {
    PARAMETER nd.
    LOCAL burnDV IS nd:DELTAV:MAG.
    LOCK THROTTLE TO 0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF ABORT OR nd:TIME <= TIME:SECONDS OR SHIP:MASS <= 0 {
        vesselLandingCleanup().
        mLogError("Deorbit burn refused: abort, expired node or invalid mass. Node retained.").
        RETURN FALSE.
    }
    // Share the bounded next-engine staging policy with descent. Activating
    // every inactive engine can ignite reserved return/payload stages.
    LOCAL ctx IS LEXICON("STAGE_UNTIL", 0, "STAGE_ENGINE", -1,
        "STAGE_EVENTS", 0, "STAGE_ACTIVATED", FALSE,
        "STAGE_WARNED", FALSE, "TARGET_THROTTLE", 0).
    LOCAL stageDeadline IS TIME:SECONDS + 10.
    UNTIL NOT vesselNeedsStage() OR ABORT OR TIME:SECONDS >= stageDeadline {
        vesselStageForLanding(ctx).
        WAIT 0.05.
    }
    IF vesselNeedsStage() OR ABORT {
        vesselLandingCleanup().
        mLogError("Deorbit burn failed: no thrust or abort. Node retained.").
        RETURN FALSE.
    }

    LOCAL burnTime IS burnDV / MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS).
    LOCAL startTime IS nd:TIME - burnTime / 2.
    IF startTime < TIME:SECONDS + 5 { SET startTime TO TIME:SECONDS + 5. }
    LOCAL alignStartTime IS startTime - 90.
    LOCAL kacAlarmId IS maneuverEnsureBurnAlarm(startTime, burnDV, "Deorbit burn", 90).
    mLog("STATS deorbit-burn setup dv=" + ROUND(burnDV,1)
        + " eta=" + ROUND(startTime - TIME:SECONDS,1)).

    IF TIME:SECONDS < alignStartTime {
        coastAutoWarp(alignStartTime, "Deorbit burn approach", kacAlarmId).
    }
    UNTIL TIME:SECONDS >= alignStartTime OR ABORT {
        WAIT MIN(10, MAX(0.5, alignStartTime - TIME:SECONDS)).
    }

    SET SAS TO FALSE.
    LOCK STEERING TO nd:BURNVECTOR.
    UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < 5
            OR TIME:SECONDS >= startTime - 2 OR ABORT {
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT 0.1.
    }

    WAIT UNTIL TIME:SECONDS >= startTime OR ABORT.
    IF ABORT OR VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) > 15 {
        mLogError("Refusing deorbit burn: off vector.").
        vesselLandingCleanup().
        IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
        RETURN FALSE.
    }

    LOCAL burnStart IS TIME:SECONDS.
    LOCAL origVec IS nd:BURNVECTOR.
    LOCAL completeDV IS MAX(0.08, burnDV * 0.01).
    LOCAL appliedDV IS 0.
    LOCAL lastTime IS TIME:SECONDS.
    LOCAL lastAcc IS SHIP:THRUST / MAX(0.01, SHIP:MASS).
    UNTIL nd:DELTAV:MAG <= completeDV OR ABORT
            OR vesselNeedsStage()
            OR TIME:SECONDS - burnStart > burnTime * 2 + 8 {
        LOCAL nowTime IS TIME:SECONDS.
        LOCAL actualAcc IS SHIP:THRUST / MAX(0.01, SHIP:MASS).
        SET appliedDV TO appliedDV + MAX(0, nowTime - lastTime) * (lastAcc + actualAcc) / 2.
        SET lastTime TO nowTime.
        SET lastAcc TO actualAcc.
        // A stale node must not keep thrusting until the time limit.
        IF appliedDV >= burnDV + completeDV { BREAK. }
        IF nd:DELTAV:MAG > 0.1
                AND VDOT(origVec:NORMALIZED, nd:BURNVECTOR:NORMALIZED) < 0 {
            BREAK.
        }
        LOCK STEERING TO nd:BURNVECTOR.
        // No throttle floor: bound the requested tail impulse even for a
        // high-TWR lander rather than stepping through fixed 25%/5% burns.
        LOCK THROTTLE TO MIN(1, nd:DELTAV:MAG
            / MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS)
            / MAX(1, 4 * (TIME:SECONDS - lastTime))).
        WAIT 0.02.
    }

    LOCAL residual IS nd:DELTAV:MAG.
    LOCAL stopped IS vesselLandingCleanup().
    LOCAL success IS stopped AND NOT ABORT AND residual <= completeDV.
    IF success { REMOVE nd. }
    IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
    SET SAS TO TRUE.
    mLog("STATS deorbit-burn result dv=" + ROUND(burnDV,1)
        + " residual=" + ROUND(residual,2) + " appliedDv=" + ROUND(appliedDV,2)
        + " thrustStopped=" + stopped
        + " success=" + success).
    IF NOT success { mLogError("Deorbit incomplete; node retained for inspection."). }
    RETURN success.
}
