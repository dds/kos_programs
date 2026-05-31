// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
// ============================================================

LOCAL COMPLETE_FRAC        IS 0.0.
LOCAL ABS_CUTOFF           IS 0.0001.
LOCAL ALIGN_TOLERANCE      IS 2.0.
LOCAL G0                   IS 9.80665.
LOCAL HIBERNATE_THRESHOLD  IS 300.
LOCAL HIBERNATE_WAKE_LEAD  IS 180.

GLOBAL FUNCTION executeManeuver {
    WAIT 0.1.
    IF NOT HASNODE {
        mLogError("executeManeuver: no node on flight plan.").
        HUDTEXT("ERROR: No maneuver node!", 5, 2, 18, RED, FALSE).
        RETURN FALSE.
    }

    LOCAL nd        IS NEXTNODE.
    LOCAL burnDV    IS nd:DELTAV:MAG.
    LOCAL startTime IS _calcStartTime(nd).

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

    SET SAS TO FALSE.
    WAIT 0.1.
    LOCK STEERING TO nd:BURNVECTOR.
    mLog("Aligning to burn vector...").

    LOCAL wakeTime IS startTime - HIBERNATE_WAKE_LEAD.
    IF TIME:SECONDS < wakeTime - HIBERNATE_THRESHOLD {
        mLog("Hibernating for coast (" + ROUND(wakeTime - TIME:SECONDS, 0) + "s).").
        HUDTEXT("Hibernated. Burn in " + ROUND(startTime - TIME:SECONDS, 0) + "s", 5, 2, 13, CYAN, FALSE).
        _hibernateCmd().
        WAIT MAX(0, wakeTime - TIME:SECONDS).
        _wakeCmd().
        mLog("Awake — " + ROUND(startTime - TIME:SECONDS, 0) + "s to burn.").
        HUDTEXT("Core awake — burn in " + ROUND(startTime - TIME:SECONDS, 0) + "s", 5, 2, 13, GREEN, FALSE).
    }

    WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ALIGN_TOLERANCE
            OR TIME:SECONDS >= (startTime - 30).

    IF VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) >= ALIGN_TOLERANCE {
        mLogWarn("Burn starting with " + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR),1) + "° misalignment.").
    } ELSE {
        mLog("Aligned. Waiting for burn window...").
    }

    WAIT UNTIL TIME:SECONDS >= (startTime - 10).
    HUDTEXT("Burn in T-10", 3, 2, 15, WHITE, FALSE).
    countdown(9).

    WAIT UNTIL TIME:SECONDS >= startTime.
    mLog("Burn start. dV=" + ROUND(burnDV,1) + " m/s").

    LOCAL origBurnVec IS nd:BURNVECTOR.

    UNTIL _isComplete(nd, burnDV) {
        LOCK STEERING TO nd:BURNVECTOR.

        IF _needsStage() {
            HUDTEXT("Staging!", 2, 2, 15, YELLOW, FALSE).
            mLog("Auto-stage triggered.").
            LOCK THROTTLE TO 0.
            WAIT 0.3.
            STAGE.
            WAIT 0.7.
        }

        LOCAL remaining IS nd:DELTAV:MAG.
        LOCAL maxAcc    IS _safeMaxAcc().
        LOCAL dotCheck IS VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED).

        IF dotCheck < 0 { LOCK THROTTLE TO 0. BREAK. }

        IF remaining > 5.0 {
            LOCK THROTTLE TO 1.0.
        } ELSE IF remaining > 0.5 {
            LOCAL timeToStop IS remaining / maxAcc.
            LOCK THROTTLE TO MAX(0.02, MIN(0.5, timeToStop)).
        } ELSE IF remaining >= 0.04 {
            LOCK THROTTLE TO 0.01.
        } ELSE {
            LOCK THROTTLE TO 0.
            BREAK.
        }

        WAIT 0.01.
    }

    LOCAL residual IS nd:DELTAV:MAG.
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
    PARAMETER pct.
    FOR eng IN SHIP:ENGINES {
        SET eng:THRUSTLIMIT TO pct * 100.
    }
}

GLOBAL FUNCTION planCircularize {
    LOCAL etaApo IS ETA:APOAPSIS.
    LOCAL mu  IS SHIP:ORBIT:BODY:MU.
    LOCAL vCirc IS SQRT(mu / (SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS)).
    LOCAL vNow  IS VELOCITYAT(SHIP, TIME:SECONDS + etaApo):ORBIT:MAG.
    LOCAL dv    IS vCirc - vNow.

    LOCAL nd IS NODE(TIME:SECONDS + etaApo, 0, 0, dv).
    ADD nd.
    mLog("Circularize node: dV=" + ROUND(dv,1) + " m/s at Ap in " + ROUND(etaApo,0) + "s").
    RETURN nd.
}

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

    LOCAL lanTarget IS -1.
    IF CFG:HASKEY("CAPTURE_LAN") { SET lanTarget TO CFG["CAPTURE_LAN"]. }

    LOCAL scanStep IS 60.
    LOCAL scanEnd  IS TIME:SECONDS + SHIP:ORBIT:PERIOD.
    IF lanTarget >= 0 {
        SET scanStep TO 300.
        SET scanEnd TO TIME:SECONDS + targetBody:ORBIT:PERIOD.
        mLog("LAN targeting: scanning " + ROUND(targetBody:ORBIT:PERIOD,0)
            + "s window in " + scanStep + "s steps.").
    }

    LOCAL foundUt IS -1.
    LOCAL bestLanErr IS 999.

    IF lanTarget >= 0 {
        UNTIL testNode:TIME > scanEnd {
            WAIT 0.02.
            IF testNode:ORBIT:HASNEXTPATCH
                    AND testNode:ORBIT:NEXTPATCH:BODY:NAME = targetBody:NAME
                    AND testNode:ORBIT:NEXTPATCH:PERIAPSIS > 0
                    AND testNode:ORBIT:NEXTPATCH:INCLINATION < 90 {
                LOCAL patchLAN IS testNode:ORBIT:NEXTPATCH:LAN.
                LOCAL lanErr IS ABS(patchLAN - lanTarget).
                IF lanErr > 180 { SET lanErr TO 360 - lanErr. }
                IF lanErr < bestLanErr {
                    SET bestLanErr TO lanErr.
                    SET foundUt TO testNode:TIME.
                }
            }
            SET testNode:TIME TO testNode:TIME + scanStep.
        }
        IF foundUt > 0 {
            mLog("LAN scan best: err=" + ROUND(bestLanErr,1)
                + "deg at T+" + ROUND(foundUt - TIME:SECONDS,0) + "s").
        }
    } ELSE {
        UNTIL testNode:TIME > scanEnd {
            WAIT 0.02.
            IF testNode:ORBIT:HASNEXTPATCH
                    AND testNode:ORBIT:NEXTPATCH:BODY:NAME = targetBody:NAME
                    AND testNode:ORBIT:NEXTPATCH:PERIAPSIS > 0
                    AND testNode:ORBIT:NEXTPATCH:INCLINATION < 90 {
                SET foundUt TO testNode:TIME.
                mLog("DEBUG coarse found Pe="
                    + ROUND(testNode:ORBIT:NEXTPATCH:PERIAPSIS/1000,1)
                    + "km at T+" + ROUND(testNode:TIME - TIME:SECONDS,0) + "s").
                BREAK.
            }
            SET testNode:TIME TO testNode:TIME + scanStep.
        }
    }

    IF foundUt < 0 {
        mLogError("planTransfer: no valid window found. Check conic patches.").
        REMOVE testNode.
        LOCAL nd IS NODE(TIME:SECONDS + 600, 0, 0, dv).
        ADD nd.
        RETURN nd.
    }

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
                        AND testNode:ORBIT:NEXTPATCH:INCLINATION < 90
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
    LOCAL logMsg IS "Transfer -> " + targetBody:NAME + ": dV=" + ROUND(dv,1)
        + " m/s  Pe=" + ROUND(bestPe/1000,1) + "km"
        + "  ETA=" + ROUND(bestUt - TIME:SECONDS,0) + "s".
    IF lanTarget >= 0 {
        SET logMsg TO logMsg + "  LAN_err=" + ROUND(bestLanErr,1) + "deg".
    }
    mLog(logMsg).
    RETURN nd.
}

GLOBAL FUNCTION planCapture {
    PARAMETER targetBody.
    PARAMETER targetAlt.

    LOCAL mu    IS targetBody:MU.
    LOCAL rPe   IS targetBody:RADIUS + SHIP:PERIAPSIS.
    LOCAL rAp   IS targetBody:RADIUS + targetAlt.
    LOCAL tSMA  IS (rPe + rAp) / 2.

    LOCAL vCapture IS SQRT(mu * (2/rPe - 1/tSMA)).
    LOCAL vAtPe    IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG.
    LOCAL dv       IS vCapture - vAtPe.

    LOCAL nd IS NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, dv).
    ADD nd.
    mLog("Capture at " + targetBody:NAME + ": dV=" + ROUND(dv,1)
        + " m/s  Pe=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + "km  targetAp=" + ROUND(targetAlt/1000,0) + "km").
    RETURN nd.
}

GLOBAL FUNCTION planLowerPe {
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

GLOBAL FUNCTION planRaisePeNow {
    PARAMETER targetPe.

    LOCAL mu   IS SHIP:ORBIT:BODY:MU.
    LOCAL rNow IS SHIP:ORBIT:BODY:RADIUS + SHIP:ALTITUDE.
    LOCAL rPe  IS SHIP:ORBIT:BODY:RADIUS + targetPe.

    LOCAL vNow IS SHIP:VELOCITY:ORBIT:MAG.
    LOCAL tSMA IS (rNow + rPe) / 2.
    LOCAL vNew IS SQRT(mu * (2/rNow - 1/tSMA)).
    LOCAL dv   IS vNew - vNow.

    LOCAL lead IS 60.
    IF ABS(dv) > 100 { SET lead TO 90. }
    IF ABS(dv) > 300 { SET lead TO 120. }
    LOCAL nd IS NODE(TIME:SECONDS + lead, 0, 0, dv).
    ADD nd.
    mLog("Raise Pe now: dV=" + ROUND(dv,1)
        + " m/s  currentAlt=" + ROUND(SHIP:ALTITUDE/1000,1)
        + "km  targetPe=" + ROUND(targetPe/1000,0)
        + "km  lead=" + lead + "s").
    RETURN nd.
}

GLOBAL FUNCTION planAoPChange {
    PARAMETER targetAoP.

    LOCAL currentAoP IS SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    LOCAL deltaAoP IS targetAoP - currentAoP.
    IF deltaAoP > 180  { SET deltaAoP TO deltaAoP - 360. }
    IF deltaAoP < -180 { SET deltaAoP TO deltaAoP + 360. }

    IF ABS(deltaAoP) < 2 {
        mLog("AoP already within 2deg — skipping.").
        RETURN 0.
    }

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL a  IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL e  IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL h  IS SQRT(mu * a * (1 - e^2)).

    LOCAL dvMag IS 2 * (mu / h) * e * SIN(ABS(deltaAoP) / 2).

    LOCAL ta1 IS deltaAoP / 2.
    LOCAL ta2 IS ta1 + 180.
    LOCAL eta1 IS etaToTrueAnomaly(ta1).
    LOCAL eta2 IS etaToTrueAnomaly(ta2).

    LOCAL burnETA IS eta1.
    LOCAL dvSign IS -1.
    IF eta2 < eta1 {
        SET burnETA TO eta2.
        SET dvSign TO 1.
    }

    LOCAL dvRadial IS dvSign * dvMag.
    LOCAL burnUT IS TIME:SECONDS + burnETA.

    LOCAL nd IS NODE(burnUT, dvRadial, 0, 0).
    ADD nd.
    mLog("AoP change: " + ROUND(currentAoP,1) + " -> " + ROUND(targetAoP,1)
        + "deg  delta=" + ROUND(deltaAoP,1)
        + "  dV=" + ROUND(dvMag,1) + " m/s"
        + "  ETA=" + ROUND(burnETA,0) + "s").
    RETURN nd.
}

LOCAL FUNCTION _calcStartTime {
    PARAMETER nd.
    LOCAL halfBurn IS 0.
    IF ADDONS:KE:AVAILABLE {
        SET halfBurn TO ADDONS:KE:NODEHALFBURNTIME.
    } ELSE {
        SET halfBurn TO nd:BURNTIME / 2.
    }
    LOCAL lead IS MIN(2.0, halfBurn * 0.02).
    RETURN nd:TIME - halfBurn - lead.
}

LOCAL FUNCTION _safeMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

LOCAL FUNCTION _isComplete {
    PARAMETER nd.
    PARAMETER origDV.
    LOCAL remaining IS nd:DELTAV:MAG.
    LOCAL threshold IS MAX(ABS_CUTOFF, origDV * COMPLETE_FRAC).
    LOCAL dotCheck IS VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED).
    IF remaining < 1.0 {
        RETURN remaining < threshold OR dotCheck < COS(ALIGN_TOLERANCE).
    }
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
    PARAMETER myVessel.
    PARAMETER target.
    LOCAL vPos IS myVessel:ORBIT:BODY:POSITION - myVessel:POSITION.
    LOCAL tPos IS myVessel:ORBIT:BODY:POSITION - target:POSITION.
    LOCAL angle IS VANG(vPos, tPos).
    LOCAL cross IS VCRS(vPos, tPos).
    IF VDOT(cross, myVessel:ORBIT:BODY:ANGULARVEL) < 0 { SET angle TO 360 - angle. }
    RETURN angle.
}

LOCAL FUNCTION _findCmdModule {
    IF CORE:PART:HASMODULE("ModuleCommand") {
        RETURN CORE:PART:GETMODULE("ModuleCommand").
    }
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleCommand") {
            RETURN p:GETMODULE("ModuleCommand").
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _hibernateCmd {
    LOCAL cm IS _findCmdModule().
    IF cm = 0 { RETURN. }
    IF cm:HASFIELD("hibernation") { cm:SETFIELD("hibernation", TRUE). }
}

LOCAL FUNCTION _wakeCmd {
    LOCAL cm IS _findCmdModule().
    IF cm = 0 { RETURN. }
    IF cm:HASFIELD("hibernation") { cm:SETFIELD("hibernation", FALSE). }
}
