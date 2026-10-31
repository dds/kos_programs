// Compact deorbit node executor for storage-limited landing bands.

GLOBAL FUNCTION executeDeorbitNode {
    PARAMETER nd.
    PARAMETER targetLat IS 999.
    PARAMETER targetLng IS 999.
    PARAMETER beforeBurn IS 0.
    PARAMETER allowStage IS TRUE.
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
    IF NOT vesselLandingPrepareRoles() {
        vesselLandingCleanup().
        mLogError("Deorbit refused: invalid landing role tags. Node retained.").
        RETURN FALSE.
    }
    IF NOT HASNODE OR ABORT {
        vesselLandingCleanup().
        RETURN FALSE.
    }
    IF nd:TIME <= TIME:SECONDS+5 {
        vesselLandingCleanup().
        mLogError("Deorbit node is too close after preflight; no burn started.").
        RETURN FALSE.
    }
    IF NOT landingLightNodeAllowed(nd, targetLat, targetLng) {
        vesselLandingCleanup().
        mLogError("Deorbit refused: landing light/Kerbin-view check failed. Node retained; use cmd/landlight to review/reselect from orbit.").
        RETURN FALSE.
    }
    // Share the bounded next-engine staging policy with descent. Activating
    // every inactive engine can ignite reserved return/payload stages.
    LOCAL ctx IS LEXICON("STAGE_UNTIL", 0, "STAGE_ENGINE", -1,
        "STAGE_EVENTS", 0, "STAGE_ACTIVATED", FALSE,
        "STAGE_WARNED", FALSE, "TARGET_THROTTLE", 0).
    LOCAL stageDeadline IS TIME:SECONDS + 10.
    IF NOT allowStage AND vesselNeedsStage() {
        vesselLandingCleanup().
        mLogError("Deorbit requires the measured active engine; automatic staging disabled. Node retained.").
        RETURN FALSE.
    }
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
    LOCAL approachLead IS 90.
    IF beforeBurn <> 0 { SET approachLead TO 300. }
    LOCAL alignStartTime IS startTime - approachLead.
    LOCAL kacAlarmId IS maneuverEnsureBurnAlarm(startTime, burnDV, "Deorbit burn", approachLead).
    mLog("STATS deorbit-burn setup dv=" + ROUND(burnDV,1)
        + " eta=" + ROUND(startTime - TIME:SECONDS,1) + " revalidateLead=" + approachLead).

    LOCAL burnBody IS SHIP:BODY.
    LOCAL solarRef IS -1.
    LOCAL coasted IS TIME:SECONDS < alignStartTime.
    IF coasted {
        SET solarRef TO enterSolarCoast("Deorbit burn approach", TRUE, TRUE, alignStartTime).
        IF NOT ABORT AND kacAlarmId <> "" AND SHIP:BODY = burnBody AND HASNODE
                AND solarCoastCanWarp(solarRef,"Deorbit burn approach")
                AND coastHealthCheck("Deorbit burn pre-warp",alignStartTime) {
            coastAutoWarp(alignStartTime, "Deorbit burn approach", kacAlarmId).
        }
    }
    UNTIL TIME:SECONDS >= alignStartTime OR ABORT OR SHIP:BODY <> burnBody OR NOT HASNODE {
        SET solarRef TO trySolarHoldTick(solarRef,alignStartTime).
        WAIT MIN(10, MAX(0.5, alignStartTime - TIME:SECONDS)).
    }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF ABORT OR SHIP:BODY <> burnBody OR NOT HASNODE {
        vesselLandingCleanup().
        IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
        mLogWarn("Deorbit coast interrupted before alignment; no burn started.").
        RETURN FALSE.
    }

    IF coasted {
        LOCAL accepted IS landingLightNodeAllowed(nd,targetLat,targetLng).
        IF accepted AND beforeBurn <> 0 {
            SET accepted TO beforeBurn:CALL(nd,targetLat,targetLng).
        }
        IF NOT accepted OR ABORT OR nd:TIME <= TIME:SECONDS {
            vesselLandingCleanup().
            IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
            mLogError("Deorbit pre-burn revalidation failed; node retained, no burn started.").
            PRINT "Run RUNPATH('0:/cmd/deorbitretry.ks'). then REBOOT. to replan the saved target from orbit.".
            RETURN FALSE.
        }
    }

    // A successful pre-burn callback may refine the attached node in place.
    // Refresh every executor quantity that depends on its impulse.
    SET burnDV TO nd:DELTAV:MAG.
    SET burnTime TO burnDV / MAX(0.1,SHIP:AVAILABLETHRUST/SHIP:MASS).
    SET startTime TO nd:TIME-burnTime/2.
    // Preserve the original 90-second final validation after the earlier
    // refinement opportunity. A second change still cancels ignition.
    IF coasted AND beforeBurn <> 0 {
        LOCAL finalCheckTime IS startTime-90.
        UNTIL TIME:SECONDS >= finalCheckTime OR ABORT OR NOT HASNODE OR SHIP:BODY <> burnBody {
            SET solarRef TO trySolarHoldTick(solarRef,finalCheckTime).
            WAIT MIN(10,MAX(0.5,finalCheckTime-TIME:SECONDS)).
        }
        IF ABORT OR NOT HASNODE OR SHIP:BODY <> burnBody {
            vesselLandingCleanup().
            IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
            RETURN FALSE.
        }
        LOCAL accepted IS landingLightNodeAllowed(nd,targetLat,targetLng).
        IF accepted { SET accepted TO beforeBurn:CALL(nd,targetLat,targetLng). }
        IF NOT accepted OR ABORT OR NOT HASNODE {
            vesselLandingCleanup().
            IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
            mLogError("Deorbit final forecast changed; node retained, no burn started. Use cmd/deorbitretry then REBOOT to replan the saved target.").
            RETURN FALSE.
        }
        SET burnDV TO nd:DELTAV:MAG.
        SET burnTime TO burnDV/MAX(0.1,SHIP:AVAILABLETHRUST/SHIP:MASS).
        SET startTime TO nd:TIME-burnTime/2.
    }
    IF startTime <= TIME:SECONDS+5 {
        vesselLandingCleanup().
        IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
        mLogError("Deorbit pre-burn checks exhausted alignment time; node retained, no burn started.").
        RETURN FALSE.
    }

    SET SAS TO FALSE.
    // System locks are asynchronous callbacks. Never let one retain a node
    // suffix: successful cleanup removes the node before this file returns.
    LOCAL steerVec IS nd:BURNVECTOR.
    LOCK STEERING TO steerVec.
    UNTIL TIME:SECONDS >= startTime OR ABORT {
        SET steerVec TO nd:BURNVECTOR.
        WAIT 0.1.
    }
    IF ABORT OR VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) > 15 {
        mLogError("Refusing deorbit burn: off vector.").
        UNLOCK STEERING.
        vesselLandingCleanup().
        IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
        RETURN FALSE.
    }

    LOCAL burnStart IS TIME:SECONDS.
    // A reboot/failed burn must not authorize replacement from a still-bound
    // but partially flown orbit. Only successful cutoff clears this marker.
    stateSet("deorbit_burn_started", "true").
    LOCAL origVec IS nd:BURNVECTOR.
    LOCAL completeDV IS MAX(0.08, burnDV * 0.01).
    LOCAL appliedDV IS 0.
    LOCAL lastTime IS TIME:SECONDS.
    LOCAL lastAcc IS SHIP:THRUST / MAX(0.01, SHIP:MASS).
    LOCAL priorIpu IS CONFIG:IPU.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) {
        stateSet("burn_prior_ipu", priorIpu).
        SET CONFIG:IPU TO MIN(2000, LANDING_MIN_IPU).
    }
    LOCAL throttleCmd IS 0.
    LOCAL commandUntil IS TIME:SECONDS.
    // Cached commands must still expire if the publishing loop stalls.
    // This small scalar callback needs neither a node nor engine queries.
    LOCK THROTTLE TO throttleCmd
        * MAX(0, MIN(1, (commandUntil - TIME:SECONDS) / 0.02)).
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
        SET steerVec TO nd:BURNVECTOR.
        // No throttle floor: bound the requested tail impulse even for a
        // high-TWR lander rather than stepping through fixed 25%/5% burns.
        LOCAL nextThrottle IS MIN(1, nd:DELTAV:MAG
            / MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS)
            / MAX(1, 4 * (TIME:SECONDS - lastTime))).
        SET commandUntil TO TIME:SECONDS + 0.5.
        SET throttleCmd TO nextThrottle.
        WAIT 0.02.
    }

    LOCAL residual IS nd:DELTAV:MAG.
    SET throttleCmd TO 0.
    // Release the steering trigger in its owning compiled file. A different
    // library's UNLOCK need not know about this file's system-lock trigger.
    LOCK THROTTLE TO 0.
    UNLOCK STEERING.
    LOCAL stopped IS vesselLandingCleanup().
    SET CONFIG:IPU TO priorIpu.
    stateRemove("burn_prior_ipu").
    LOCAL success IS stopped AND NOT ABORT AND residual <= completeDV.
    IF success {
        REMOVE nd.
        stateRemove("deorbit_burn_started").
    }
    IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
    SET SAS TO TRUE.
    mLog("STATS deorbit-burn result dv=" + ROUND(burnDV,1)
        + " residual=" + ROUND(residual,2) + " appliedDv=" + ROUND(appliedDV,2)
        + " thrustStopped=" + stopped
        + " success=" + success).
    IF NOT success { mLogError("Deorbit incomplete; node retained for inspection."). }
    RETURN success.
}
