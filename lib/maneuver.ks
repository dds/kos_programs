// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
//
// kOS owns steering throughout via LOCK STEERING.
// No SAS mode dependency.
// ============================================================

// Threshold: maneuver considered complete when remaining
// dV drops below this fraction of original burn OR below
// ABS_CUTOFF m/s, whichever is larger.
LOCAL COMPLETE_FRAC   IS 0.015.  // 1.5% of original dV remaining
LOCAL ABS_CUTOFF      IS 0.3.    // m/s — hard floor
LOCAL ALIGN_TOLERANCE IS 2.0.    // degrees — begin burn within this

// ── Public entry point ─────────────────────────────────────

GLOBAL FUNCTION executeManeuver {
    // Execute the next maneuver node on the flight plan.
    // Handles alignment, throttle ramp, staging, and cleanup.

    IF NOT HASNODE {
        mLogError("executeManeuver: no node on flight plan.").
        HUDTEXT("ERROR: No maneuver node!", 5, 2, 18, RED, FALSE).
        RETURN FALSE.
    }

    LOCAL nd        IS NEXTNODE.
    LOCAL burnDV    IS nd:DELTAV:MAG.          // original magnitude
    LOCAL startTime IS _calcStartTime(nd).

    mLog("Maneuver: dV=" + ROUND(burnDV,1) + " m/s  ETA=" + ROUND(startTime - TIME:SECONDS,1) + "s").

    // ── Align early ───────────────────────────────────────
    LOCK STEERING TO nd:BURNVECTOR.
    mLog("Aligning to burn vector...").

    // Wait until aligned OR we're within 30s of start (don't miss the window)
    WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ALIGN_TOLERANCE
            OR TIME:SECONDS >= (startTime - 30).

    IF VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) >= ALIGN_TOLERANCE {
        mLogWarn("Burn starting with " + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR),1) + "° misalignment.").
    } ELSE {
        mLog("Aligned. Waiting for burn window...").
    }

    // ── Coast to T-10 ─────────────────────────────────────
    WAIT UNTIL TIME:SECONDS >= (startTime - 10).
    HUDTEXT("Burn in T-10", 3, 2, 15, WHITE, FALSE).
    countdown(9).

    WAIT UNTIL TIME:SECONDS >= startTime.
    mLog("Burn start. dV=" + ROUND(burnDV,1) + " m/s").

    // ── Burn loop ─────────────────────────────────────────
    LOCAL origBurnVec IS nd:BURNVECTOR.  // snapshot direction for completion check

    UNTIL _isComplete(nd, burnDV) {

        // Keep steering locked to live burn vector
        LOCK STEERING TO nd:BURNVECTOR.

        // Staging check
        IF _needsStage() {
            HUDTEXT("Staging!", 2, 2, 15, YELLOW, FALSE).
            mLog("Auto-stage triggered.").
            LOCK THROTTLE TO 0.
            WAIT 0.3.
            STAGE.
            WAIT 0.7.
        }

        // Throttle — ramp down in final approach to avoid overshoot
        LOCAL remaining IS nd:DELTAV:MAG.
        LOCAL maxAcc    IS _safeMaxAcc().

        IF maxAcc > 0 {
            LOCAL ratio IS remaining / maxAcc.
            IF ratio < 0.5 {
                // Fine control: throttle proportional, min 2%
                LOCK THROTTLE TO MAX(0.02, ratio).
            } ELSE {
                LOCK THROTTLE TO 1.0.
            }
        }

        WAIT 0.01.
    }

    // ── Shutdown ──────────────────────────────────────────
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    REMOVE nd.
    SET SAS TO TRUE.

    mLog("Burn complete. Residual dV ~" + ROUND(nd:DELTAV:MAG, 2) + " m/s (pre-remove).").
    HUDTEXT("Burn complete", 3, 2, 15, GREEN, FALSE).
    RETURN TRUE.
}

// ── Node planning helpers ──────────────────────────────────

GLOBAL FUNCTION planCircularize {
    // Plan a circularization node at current apoapsis.
    LOCAL etaApo IS ETA:APOAPSIS.
    LOCAL mu  IS SHIP:ORBIT:BODY:MU.

    // vis-viva for circular orbit at apoapsis radius
    LOCAL vCirc IS SQRT(mu / (SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS)).
    LOCAL vNow  IS VELOCITYAT(SHIP, TIME:SECONDS + etaApo):ORBIT:MAG.
    LOCAL dv    IS vCirc - vNow.

    LOCAL nd IS NODE(TIME:SECONDS + etaApo, 0, 0, dv).
    ADD nd.
    mLog("Circularize node: dV=" + ROUND(dv,1) + " m/s at Ap in " + ROUND(etaApo,0) + "s").
    RETURN nd.
}


GLOBAL FUNCTION planTransfer {
    // Hohmann TMI to any body orbiting the same parent as SHIP.
    // e.g. ship in Kerbin orbit → MUN or MINMUS
    PARAMETER targetBody.

    LOCAL parentBody  IS SHIP:ORBIT:BODY.
    LOCAL mu          IS parentBody:MU.
    LOCAL r1          IS parentBody:RADIUS + SHIP:ORBIT:APOAPSIS.
    LOCAL targetSMA   IS targetBody:ORBIT:SEMIMAJORAXIS.
    LOCAL tSMA        IS (r1 + targetSMA) / 2.
    LOCAL vTrans      IS SQRT(mu * (2/r1 - 1/tSMA)).
    LOCAL vCirc       IS SQRT(mu / r1).
    LOCAL dv          IS vTrans - vCirc.

    LOCAL targetPeriod IS targetBody:ORBIT:PERIOD.
    LOCAL transPeriod  IS 2 * CONSTANT:PI * SQRT(tSMA^3 / mu).
    LOCAL tofHalf      IS transPeriod / 2.

    LOCAL phaseNeeded IS 180 - (360 * (tofHalf / targetPeriod)).
    UNTIL phaseNeeded < 0   { SET phaseNeeded TO phaseNeeded - 360. }
    UNTIL phaseNeeded >= 0  { SET phaseNeeded TO phaseNeeded + 360. }

    LOCAL currentPhase IS _phaseAngle(SHIP, targetBody).
    LOCAL phaseDiff    IS phaseNeeded - currentPhase.
    UNTIL phaseDiff < 0   { SET phaseDiff TO phaseDiff - 360. }
    UNTIL phaseDiff >= 0  { SET phaseDiff TO phaseDiff + 360. }

    LOCAL targetAngV IS 360 / targetPeriod.
    LOCAL waitTime   IS phaseDiff / targetAngV.

    LOCAL nd IS NODE(TIME:SECONDS + waitTime, 0, 0, dv).
    ADD nd.
    mLog("Transfer → " + targetBody:NAME + ": dV=" + ROUND(dv,1) + " m/s  wait=" + ROUND(waitTime,0) + "s").
    RETURN nd.
}

GLOBAL FUNCTION planCapture {
    // Retrograde burn at periapsis to circularize into target body SOI.
    // Call after SOI entry.
    PARAMETER targetBody.
    PARAMETER targetAlt.

    LOCAL mu    IS targetBody:MU.
    LOCAL rPe   IS targetBody:RADIUS + SHIP:PERIAPSIS.
    LOCAL vAtPe IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG.
    LOCAL vCirc IS SQRT(mu / rPe).
    LOCAL dv    IS vCirc - vAtPe.

    LOCAL nd IS NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, dv).
    ADD nd.
    mLog("Capture at " + targetBody:NAME + ": dV=" + ROUND(dv,1) + " m/s  Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km").
    RETURN nd.
}

GLOBAL FUNCTION planLowerPe {
    // At apoapsis, retrograde burn to drop periapsis to targetPe.
    // Body is inferred from SHIP:ORBIT:BODY.
    PARAMETER targetPe.

    LOCAL mu    IS SHIP:ORBIT:BODY:MU.
    LOCAL rAp   IS SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS.
    LOCAL rPe   IS SHIP:ORBIT:BODY:RADIUS + targetPe.
    LOCAL tSMA  IS (rAp + rPe) / 2.
    LOCAL vNew  IS SQRT(mu * (2/rAp - 1/tSMA)).
    LOCAL vNow  IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:APOAPSIS):ORBIT:MAG.
    LOCAL dv    IS vNew - vNow.

    LOCAL nd IS NODE(TIME:SECONDS + ETA:APOAPSIS, 0, 0, dv).
    ADD nd.
    mLog("Lower Pe: dV=" + ROUND(dv,1) + " m/s  targetPe=" + ROUND(targetPe/1000,1) + "km").
    RETURN nd.
}

GLOBAL FUNCTION planRecircularize {
    // At apoapsis, prograde burn to re-raise periapsis to targetPe.
    PARAMETER targetPe.

    LOCAL mu   IS SHIP:ORBIT:BODY:MU.
    LOCAL rAp  IS SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS.
    LOCAL rPe  IS SHIP:ORBIT:BODY:RADIUS + targetPe.
    LOCAL tSMA IS (rAp + rPe) / 2.
    LOCAL vNew IS SQRT(mu * (2/rAp - 1/tSMA)).
    LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:APOAPSIS):ORBIT:MAG.
    LOCAL dv   IS vNew - vNow.

    LOCAL nd IS NODE(TIME:SECONDS + ETA:APOAPSIS, 0, 0, dv).
    ADD nd.
    mLog("Recircularize: dV=" + ROUND(dv,1) + " m/s  targetPe=" + ROUND(targetPe/1000,1) + "km").
    RETURN nd.
}

// ── Private helpers ────────────────────────────────────────

LOCAL FUNCTION _calcStartTime {
    PARAMETER nd.
    LOCAL burnDur IS _estimateBurnDuration(nd:DELTAV:MAG).
    RETURN nd:TIME - (burnDur / 2).
}

LOCAL FUNCTION _estimateBurnDuration {
    PARAMETER dv.
    LOCAL maxAcc IS _safeMaxAcc().
    IF maxAcc <= 0 { RETURN 60. }
    RETURN dv / maxAcc.
}

LOCAL FUNCTION _safeMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:MAXTHRUST / SHIP:MASS.
}

LOCAL FUNCTION _isComplete {
    PARAMETER nd.
    PARAMETER origDV.
    LOCAL remaining IS nd:DELTAV:MAG.
    LOCAL threshold IS MAX(ABS_CUTOFF, origDV * COMPLETE_FRAC).
    // Also stop if we've overshot (dot product flips negative)
    LOCAL dotCheck IS VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED).
    RETURN remaining < threshold OR dotCheck < 0.
}

LOCAL FUNCTION _needsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _phaseAngle {
    // Angle from vessel to target body in orbital plane
    PARAMETER myVessel.
    PARAMETER target.
    LOCAL vPos IS myVessel:ORBIT:BODY:POSITION - myVessel:POSITION.
    LOCAL tPos IS myVessel:ORBIT:BODY:POSITION - target:POSITION.
    LOCAL angle IS VANG(vPos, tPos).
    // Determine sign via cross product
    LOCAL cross IS VCRS(vPos, tPos).
    IF VDOT(cross, myVessel:ORBIT:BODY:ANGULARVEL) < 0 { SET angle TO 360 - angle. }
    RETURN angle.
}