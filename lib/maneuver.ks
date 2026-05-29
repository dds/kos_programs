// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
//
// kOS owns steering throughout via LOCK STEERING.
// No SAS mode dependency.
// ============================================================

// Threshold: maneuver considered complete when remaining
// dV drops below this fraction of original burn OR below
// ABS_CUTOFF m/s, whichever is larger.
LOCAL COMPLETE_FRAC   IS 0.001.  // 0.1% of original dV remaining
LOCAL ABS_CUTOFF      IS 0.1.    // m/s — hard floor
LOCAL ALIGN_TOLERANCE IS 2.0.    // degrees — begin burn within this
LOCAL G0 IS 9.80665. // standard gravity m/s^2  - ISP conversion constant

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

    // Dyanmic minimum throttle based on burn size.
    IF burnDV < 10 {_setThrustLimit(0.25). }.
    IF burnDV < 2 { _setThrustLimit(0.10). }.
    IF burnDV < 0.5 { _setThrustLimit(0.05). }.

    IF startTime < TIME:SECONDS {
        mLogWarn("Burn window already passed by " + ROUND(TIME:SECONDS - startTime, 0) + "s — removing node.").
        HUDTEXT("Burn window missed — replanning", 5, 2, 15, YELLOW, FALSE).
        REMOVE nd.
        RETURN FALSE.
    }

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
    LOCAL residual IS nd:DELTAV:MAG.

    // Post-burn residual correction
    IF residual > 0.1 AND residual < 5.0 {
        mLog("Residual correction: " + ROUND(residual,2) + " m/s").
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < 1.0.
        LOCAL corrAcc IS _safeMaxAcc().
        IF corrAcc > 0 {
            LOCK THROTTLE TO MIN(0.05, residual / corrAcc).
            WAIT UNTIL nd:DELTAV:MAG < 0.1 OR VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED) < 0.
            LOCK THROTTLE TO 0.
        }
    }

    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    REMOVE nd.
    SET SAS TO TRUE.
    _setThrustLimit(1.0).

    mLog("Burn complete. Residual dV ~" + ROUND(residual, 2) + " m/s.").
    HUDTEXT("Burn complete", 3, 2, 15, GREEN, FALSE).
    RETURN TRUE.
}

LOCAL FUNCTION _setThrustLimit {
    PARAMETER pct. // 0-1
    FOR eng IN SHIP:ENGINES {
        SET eng:THRUSTLIMIT TO pct * 100.
    }
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

// GLOBAL FUNCTION planTransfer {
//     PARAMETER targetBody.
//     PARAMETER targetPe.
// 
//     LOCAL r1 IS SHIP:ORBIT:SEMIMAJORAXIS.
//     LOCAL r2 IS targetBody:ORBIT:SEMIMAJORAXIS.
//     LOCAL mu IS BODY:MU.
// 
//     LOCAL targetRadius IS targetBody:RADIUS + targetPe.
//     LOCAL aTrans IS (r1 + r2 + targetRadius) / 2.
//     LOCAL v1 IS SQRT(mu / r1).
//     LOCAL vTrans IS SQRT(mu * ((2 / r1) - (1 / aTrans))).
//     LOCAL dv IS vTrans - v1.
// 
//     LOCAL tTrans IS CONSTANT:PI * SQRT((aTrans^3) / mu).
//     LOCAL targetOmega IS 360 / targetBody:ORBIT:PERIOD.
//     LOCAL idealPhase IS 180 - (targetOmega * tTrans).
// 
//     LOCAL shipPos IS SHIP:POSITION - BODY:POSITION.
//     LOCAL targetPos IS targetBody:POSITION - BODY:POSITION.
//     LOCAL currentPhase IS VANG(shipPos, targetPos).
//     LOCAL orbitNormal IS VCRS(shipPos, SHIP:VELOCITY:ORBIT).
//     LOCAL phaseSign IS VDOT(orbitNormal, VCRS(shipPos, targetPos)).
//     IF phaseSign < 0 { SET currentPhase TO 360 - currentPhase. }
// 
//     LOCAL shipOmega IS 360 / SHIP:ORBIT:PERIOD.
//     LOCAL phaseSpeed IS shipOmega - targetOmega.
//     LOCAL phaseDiff IS currentPhase - idealPhase.
//     IF phaseDiff < 0 { SET phaseDiff TO phaseDiff + 360. }
// 
//     // Clamp estimatedTimeToBurn to a positive value within one synodic period
//     LOCAL synodicPeriod IS ABS(360 / phaseSpeed).
//     LOCAL estimatedTimeToBurn IS phaseDiff / phaseSpeed.
//     UNTIL estimatedTimeToBurn > 0 { SET estimatedtimeToBurn TO estimatedTimeToBurn + synodicPeriod. }
//     UNTIL estimatedTimeToBurn < synodicPeriod { SET estimatedTimeToBurn TO estimatedTimeToBurn - synodicPeriod. }
// 
//     LOCAL bestUt IS TIME:SECONDS + estimatedTimeToBurn.
//     LOCAL testNode IS NODE(bestUt, 0, 0, dv).
//     ADD testNode.
//     mLog("DEBUG initial node: hasNext=" + testNode:ORBIT:HASNEXTPATCH
//     + "  body=" + testNode:ORBIT:BODY:NAME
//     + "  apoapsis=" + ROUND(testNode:ORBIT:APOAPSIS/1000,0) + "km").
//     WAIT 0.1.
// 
//     LOCAL bestPe IS 999999999.
//     LOCAL steps IS 10.
//     FROM { LOCAL pass IS 1. } UNTIL pass > 3 STEP { SET pass TO pass + 1. } DO {
//         mLog("DEBUG pass=" + pass + " steps=" + steps + " nodeTime=" + ROUND(testNode:TIME - TIME:SECONDS,0) + "s from now").
//         LOCAL scanning IS TRUE.
//         UNTIL NOT scanning {
//             SET testNode:TIME TO testNode:TIME - steps.
//             WAIT 0.02.
//             LOCAL hasNext IS testNode:ORBIT:HASNEXTPATCH.
//             mLog("DEBUG hasNext=" + hasNext + " nodeETA=" + ROUND(testNode:TIME - TIME:SECONDS,0)).
//             IF hasNext AND testNode:ORBIT:NEXTPATCH:BODY:NAME = targetBody:NAME {
//                 LOCAL currentPe IS testNode:ORBIT:NEXTPATCH:PERIAPSIS.
//                 mLog("DEBUG encounter Pe=" + ROUND(currentPe/1000,1) + "km").
//                 IF currentPe < bestPe AND currentPe > targetPe {
//                     SET bestPe TO currentPe.
//                     SET bestUt TO testNode:TIME.
//                 } ELSE {
//                     SET testNode:TIME TO testNode:TIME + steps.
//                     SET scanning TO FALSE.
//                 }
//             } ELSE {
//                 SET testNode:TIME TO testNode:TIME + steps.
//                 SET scanning TO FALSE.
//             }
//         }
//         SET steps TO steps / 5.
//     }
// 
//     REMOVE testNode.
//     LOCAL nd IS NODE(bestUt, 0, 0, dv).
//     ADD nd.
//     mLog("Transfer → " + targetBody:NAME + ": dV=" + ROUND(dv,1)
//         + " m/s  Pe=" + ROUND(bestPe/1000,1) + "km  ETA=" + ROUND(estimatedTimeToBurn,0) + "s").
//     RETURN nd.
// }

GLOBAL FUNCTION planTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.

    LOCAL r1 IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL r2 IS targetBody:ORBIT:SEMIMAJORAXIS.
    LOCAL mu IS BODY:MU.

    LOCAL targetRadius IS targetBody:RADIUS + targetPe.
    LOCAL aTrans IS (r1 + r2 + targetRadius) / 2.
    LOCAL v1     IS SQRT(mu / r1).
    LOCAL vTrans IS SQRT(mu * ((2 / r1) - (1 / aTrans))).
    LOCAL dv     IS vTrans - v1.

    LOCAL tTrans      IS CONSTANT:PI * SQRT((aTrans^3) / mu).
    LOCAL targetOmega IS 360 / targetBody:ORBIT:PERIOD.
    LOCAL idealPhase  IS 180 - (targetOmega * tTrans).

    LOCAL shipPos    IS SHIP:POSITION - BODY:POSITION.
    LOCAL targetPos  IS targetBody:POSITION - BODY:POSITION.
    LOCAL currentPhase IS VANG(shipPos, targetPos).
    LOCAL orbitNormal  IS VCRS(shipPos, SHIP:VELOCITY:ORBIT).
    LOCAL phaseSign    IS VDOT(orbitNormal, VCRS(shipPos, targetPos)).
    IF phaseSign < 0 { SET currentPhase TO 360 - currentPhase. }

    LOCAL shipOmega  IS 360 / SHIP:ORBIT:PERIOD.
    LOCAL phaseSpeed IS shipOmega - targetOmega.
    LOCAL phaseDiff  IS currentPhase - idealPhase.
    IF phaseDiff < 0 { SET phaseDiff TO phaseDiff + 360. }

    LOCAL synodicPeriod IS ABS(360 / phaseSpeed).
    LOCAL estimatedTimeToBurn IS phaseDiff / phaseSpeed.
    UNTIL estimatedTimeToBurn > 0 {
        SET estimatedTimeToBurn TO estimatedTimeToBurn + synodicPeriod.
    }
    UNTIL estimatedTimeToBurn < synodicPeriod {
        SET estimatedTimeToBurn TO estimatedTimeToBurn - synodicPeriod.
    }

    mLog("DEBUG transfer: idealPhase=" + ROUND(idealPhase,1)
        + " currentPhase=" + ROUND(currentPhase,1)
        + " phaseDiff=" + ROUND(phaseDiff,1)
        + " phaseSpeed=" + ROUND(phaseSpeed,4)
        + " dv=" + ROUND(dv,1)
        + " estimatedETA=" + ROUND(estimatedTimeToBurn,0) + "s").

    LOCAL testNode IS NODE(TIME:SECONDS + estimatedTimeToBurn, 0, 0, dv).
    ADD testNode.
    WAIT 0.1.

    // ── Coarse scan: find first node with Pe above surface ─
    LOCAL scanStep IS 60.
    LOCAL scanEnd  IS TIME:SECONDS + SHIP:ORBIT:PERIOD.
    LOCAL foundUt  IS -1.

    UNTIL testNode:TIME > scanEnd {
        WAIT 0.02.
        IF testNode:ORBIT:HASNEXTPATCH
                AND testNode:ORBIT:NEXTPATCH:BODY:NAME = targetBody:NAME
                AND testNode:ORBIT:NEXTPATCH:PERIAPSIS > 0 {
            SET foundUt TO testNode:TIME.
            mLog("DEBUG coarse found Pe="
                + ROUND(testNode:ORBIT:NEXTPATCH:PERIAPSIS/1000,1)
                + "km at T+" + ROUND(testNode:TIME - TIME:SECONDS,0) + "s").
            BREAK.
        }
        SET testNode:TIME TO testNode:TIME + scanStep.
    }

    IF foundUt < 0 {
        mLogError("planTransfer: no valid window found in one orbit. Check conic patches.").
        REMOVE testNode.
        // Return a placeholder node so caller gets something visible
        LOCAL nd IS NODE(TIME:SECONDS + 600, 0, 0, dv).
        ADD nd.
        RETURN nd.
    }

    // ── Fine tune: optimize toward targetPe ───────────────
    SET testNode:TIME TO foundUt.
    LOCAL bestPe IS testNode:ORBIT:NEXTPATCH:PERIAPSIS.
    LOCAL bestUt IS foundUt.
    LOCAL steps  IS 30.

    FROM { LOCAL pass IS 1. } UNTIL pass > 4 STEP { SET pass TO pass + 1. } DO {
        mLog("DEBUG fine pass=" + pass + " steps=" + steps
            + " Pe=" + ROUND(bestPe/1000,1) + "km"
            + " T+" + ROUND(bestUt - TIME:SECONDS,0) + "s").
        LOCAL scanning IS TRUE.
        UNTIL NOT scanning {
            SET testNode:TIME TO testNode:TIME - steps.
            WAIT 0.02.
            IF testNode:ORBIT:HASNEXTPATCH
                    AND testNode:ORBIT:NEXTPATCH:BODY:NAME = targetBody:NAME {
                LOCAL currentPe IS testNode:ORBIT:NEXTPATCH:PERIAPSIS.
                IF currentPe > 0
                        AND currentPe > targetPe
                        AND ABS(currentPe - targetPe) < ABS(bestPe - targetPe) {
                    SET bestPe TO currentPe.
                    SET bestUt TO testNode:TIME.
                } ELSE {
                    SET testNode:TIME TO testNode:TIME + steps.
                    SET scanning TO FALSE.
                }
            } ELSE {
                SET testNode:TIME TO testNode:TIME + steps.
                SET scanning TO FALSE.
            }
        }
        SET testNode:TIME TO bestUt.
        SET steps TO steps / 5.
    }

    REMOVE testNode.
    LOCAL nd IS NODE(bestUt, 0, 0, dv).
    ADD nd.
    mLog("Transfer → " + targetBody:NAME + ": dV=" + ROUND(dv,1)
        + " m/s  Pe=" + ROUND(bestPe/1000,1) + "km"
        + "  ETA=" + ROUND(bestUt - TIME:SECONDS,0) + "s").
    RETURN nd.
}

GLOBAL FUNCTION planCapture {
    // Retrograde burn at periapsis to circularize into target body SOI.
    // Call after SOI entry.
    PARAMETER targetBody.
    PARAMETER targetAlt.

    LOCAL mu    IS targetBody:MU.
    LOCAL rPe   IS targetBody:RADIUS + SHIP:PERIAPSIS.
    LOCAL rAp   IS targetBody:RADIUS + targetAlt.  // target Ap = relay altitude
    LOCAL tSMA  IS (rPe + rAp) / 2.               // transfer ellipse SMA

    // Velocity at Pe of target capture ellipse
    LOCAL vCapture IS SQRT(mu * (2/rPe - 1/tSMA)).
    // Current hyperbolic velocity at Pe
    LOCAL vAtPe    IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG.
    LOCAL dv       IS vCapture - vAtPe.  // negative = retrograde

    LOCAL nd IS NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, dv).
    ADD nd.
    mLog("Capture at " + targetBody:NAME + ": dV=" + ROUND(dv,1)
        + " m/s  Pe=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + "km  targetAp=" + ROUND(targetAlt/1000,0) + "km").
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
    mLog("DEBUG calcStartTime: dv=" + ROUND(nd:DELTAV:MAG,1)
    + " maxThrust=" + ROUND(SHIP:MAXTHRUST,1)
    + " availableThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)
    + " possibleThrust=" + ROUND(_shipPossibleThrust())
    + " mass=" + ROUND(SHIP:MASS,2)
    + " isp=" + ROUND(_effectiveIsp(),1)
    + " burnDur=" + ROUND(burnDur,1)
    + " startOffset=" + ROUND(burnDur/2,1)).
    RETURN nd:TIME - (burnDur / 2).
}

LOCAL FUNCTION _shipPossibleThrust {
    LOCAL total IS 0.
    FOR eng IN SHIP:ENGINES {
        IF NOT eng:FLAMEOUT AND eng:ISP > 0 {
            SET total TO total + eng:POSSIBLETHRUST.
        }
    }
    RETURN total.
}

LOCAL FUNCTION _estimateBurnDuration {
    PARAMETER dv.
    LOCAL isp IS _effectiveIsp().
    IF isp <= 0 { RETURN dv / _safeMaxAcc(). }
    LOCAL ve IS isp * G0.
    LOCAL dm IS SHIP:MASS * (1 - CONSTANT:E^(-dv/ve)). // propellant mass
    LOCAL mdot IS _shipPossibleThrust() / ve. // mass flow rate
    IF mdot <= 0 { RETURN 60. }
    RETURN dm / mdot.
}

LOCAL FUNCTION _effectiveIsp {
    LOCAL totalThrust IS 0.
    LOCAL totalFlow IS 0.
    FOR eng in SHIP:ENGINES {
        IF NOT eng:FLAMEOUT AND eng:POSSIBLETHRUST > 0 AND eng:ISP > 0 {
            LOCAL flow IS eng:POSSIBLETHRUST / (eng:ISP * G0).
            SET totalFlow TO totalFlow + flow.
            SET totalThrust TO totalThrust + eng:POSSIBLETHRUST.
        }
    }
    IF totalFlow <= 0 { RETURN 0. }
    RETURN totalThrust / (totalFlow * G0).
}

LOCAL FUNCTION _safeMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN _shipPossibleThrust() / SHIP:MASS.
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