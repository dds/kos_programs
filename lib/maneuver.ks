// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
// ============================================================

LOCAL COMPLETE_FRAC        IS 0.0.
LOCAL ABS_CUTOFF           IS 0.0001.
LOCAL ALIGN_TOLERANCE      IS 2.0.
LOCAL HIBERNATE_THRESHOLD  IS 300.
LOCAL HIBERNATE_WAKE_LEAD  IS 180.

GLOBAL FUNCTION executeManeuver {
    WAIT 0.1.
    IF NOT HASNODE {
        mLogError("executeManeuver: no node on flight plan.").
        HUDTEXT("ERROR: No maneuver node!", 5, 2, 18, RED, FALSE).
        RETURN FALSE.
    }

    LOCAL nd    IS NEXTNODE.
    LOCAL burnDV  IS nd:DELTAV:MAG.
    LOCAL startTime IS _calcStartTime(nd).

    IF burnDV < 10 { _setThrustLimit(0.25). }
    IF burnDV < 2  { _setThrustLimit(0.10). }
    IF burnDV < 0.5 { _setThrustLimit(0.05). }

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

LOCAL FUNCTION _findEncounter {
    PARAMETER testNode.
    PARAMETER targetBody.
    PARAMETER centerTime.
    PARAMETER searchRadius.
    PARAMETER step.

    LOCAL offset IS 0.
    UNTIL offset > searchRadius {
        LOCAL tryTimes IS LIST(centerTime + offset).
        IF offset > 0 { tryTimes:ADD(centerTime - offset). }
        FOR t IN tryTimes {
            IF t > TIME:SECONDS + 30 {
                SET testNode:TIME TO t.
                WAIT 0.02.
                LOCAL patch IS _getTargetPatch(testNode, targetBody).
                IF patch <> 0 AND patch:PERIAPSIS > 0 {
                    RETURN t.
                }
            }
        }
        SET offset TO offset + step.
    }
    RETURN -1.
}

GLOBAL FUNCTION planTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER lanTarget IS -1.
    PARAMETER aopTarget IS -1.

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

    SET TARGET TO targetBody.
    LOCAL currentPhase IS phaseAngle().
    IF currentPhase < 0 { SET currentPhase TO currentPhase + 360. }

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

    mLog("Hohmann: dV=" + ROUND(dv,1) + " phase=" + ROUND(currentPhase,1)
        + " ideal=" + ROUND(idealPhase,1) + " ETA=" + ROUND(estimatedTimeToBurn,0) + "s").

    LOCAL testNode IS NODE(TIME:SECONDS + estimatedTimeToBurn, 0, 0, dv).
    ADD testNode.
    WAIT 0.1.

    LOCAL foundUt IS _findEncounter(testNode, targetBody,
        TIME:SECONDS + estimatedTimeToBurn, SHIP:ORBIT:PERIOD, 120).
    IF foundUt < 0 {
        SET foundUt TO _findEncounter(testNode, targetBody,
            TIME:SECONDS + estimatedTimeToBurn, targetBody:ORBIT:PERIOD, 300).
    }

    IF foundUt < 0 {
        mLogError("planTransfer: no encounter found.").
        REMOVE testNode.
        LOCAL nd IS NODE(TIME:SECONDS + 600, 0, 0, dv).
        ADD nd.
        RETURN nd.
    }

    SET testNode:TIME TO foundUt.
    SET testNode:PROGRADE TO dv.
    WAIT 0.05.

    IF lanTarget >= 0 {
        LOCAL shipPeriod IS SHIP:ORBIT:PERIOD.
        LOCAL nOrbits IS 10.
        LOCAL nSlices IS 60.
        LOCAL sliceStep IS shipPeriod / nSlices.
        LOCAL bestLanErr IS 999.
        LOCAL bestTime IS foundUt.
        LOCAL baseUt IS foundUt.

        LOCAL lanTol IS 0.5.
        IF CFG:HASKEY("LAN_ERR_TOL") { SET lanTol TO CFG["LAN_ERR_TOL"]. }

        mLog("LAN scan: " + nOrbits + " orbits x " + nSlices
            + " slices, target=" + ROUND(lanTarget,1) + " tol=" + ROUND(lanTol,2)).

        FROM { LOCAL i IS 0. } UNTIL i >= nOrbits STEP { SET i TO i + 1. } DO {
            IF ABS(bestLanErr) <= lanTol { BREAK. }
            LOCAL orbitStart IS baseUt + i * shipPeriod.
            IF orbitStart < TIME:SECONDS + 60 { }
            ELSE {
                LOCAL orbitBestErr IS 999.
                LOCAL orbitBestLan IS 0.
                LOCAL orbitBestTime IS 0.
                FROM { LOCAL j IS 0. } UNTIL j >= nSlices STEP { SET j TO j + 1. } DO {
                    LOCAL t IS orbitStart + j * sliceStep.
                    IF t > TIME:SECONDS + 30 {
                        SET testNode:TIME TO t.
                        SET testNode:PROGRADE TO dv.
                        WAIT 0.02.
                        LOCAL p IS _getTargetPatch(testNode, targetBody).
                        IF p <> 0 AND p:PERIAPSIS > 0 {
                            LOCAL lanNow IS p:LAN.
                            LOCAL lanErr IS lanTarget - lanNow.
                            IF lanErr > 180  { SET lanErr TO lanErr - 360. }
                            IF lanErr < -180 { SET lanErr TO lanErr + 360. }
                            IF ABS(lanErr) < ABS(orbitBestErr) {
                                SET orbitBestErr TO lanErr.
                                SET orbitBestLan TO lanNow.
                                SET orbitBestTime TO t.
                            }
                        }
                    }
                }
                IF orbitBestTime > 0 {
                    mLog("LAN orbit[" + i + "] t+" + ROUND(orbitBestTime - TIME:SECONDS,0)
                        + "s LAN=" + ROUND(orbitBestLan,1)
                        + " err=" + ROUND(orbitBestErr,1)
                        + " dV=" + ROUND(dv,1)).
                    IF ABS(orbitBestErr) < ABS(bestLanErr) {
                        SET bestLanErr TO orbitBestErr.
                        SET bestTime TO orbitBestTime.
                    }
                }
            }
        }

        SET testNode:TIME TO bestTime.
        SET testNode:PROGRADE TO dv.
        WAIT 0.05.
        mLog("LAN best: t+" + ROUND(bestTime - TIME:SECONDS,0)
            + "s err=" + ROUND(bestLanErr,1)).
    }

    LOCAL foundDv IS testNode:PROGRADE.
    LOCAL dvMax IS foundDv * 1.15.
    LOCAL dvMin IS foundDv * 0.85.
    LOCAL lastGoodDv IS foundDv.

    LOCAL preCheck IS _getTargetPatch(testNode, targetBody).
    IF preCheck = 0 {
        mLog("PE: no encounter at selected time — skipping convergence.").
    } ELSE IF preCheck:PERIAPSIS < 0 {
        mLog("PE: impact trajectory (pe=" + ROUND(preCheck:PERIAPSIS/1000,1) + "km) — skipping convergence.").
    } ELSE {
        mLog("PE: starting convergence, current Pe=" + ROUND(preCheck:PERIAPSIS/1000,1) + "km target=" + ROUND(targetPe/1000,1) + "km.").
    }

    FROM { LOCAL i IS 0. } UNTIL i >= 12 STEP { SET i TO i + 1. } DO {
        LOCAL p IS _getTargetPatch(testNode, targetBody).
        IF p = 0 OR p:PERIAPSIS < 0 {
            SET testNode:PROGRADE TO lastGoodDv.
            BREAK.
        }
        SET lastGoodDv TO testNode:PROGRADE.
        LOCAL peErr IS targetPe - p:PERIAPSIS.
        IF ABS(peErr) < 200 {
            mLog("PE[" + i + "] converged: " + ROUND(p:PERIAPSIS/1000,1)
                + "km err=" + ROUND(peErr/1000,1) + "km").
            BREAK.
        }
        LOCAL basePe IS p:PERIAPSIS.
        LOCAL oldDv IS testNode:PROGRADE.
        SET testNode:PROGRADE TO oldDv + 0.5.
        WAIT 0.02.
        LOCAL p2 IS _getTargetPatch(testNode, targetBody).
        SET testNode:PROGRADE TO oldDv.
        IF p2 = 0 { BREAK. }
        LOCAL sens IS (p2:PERIAPSIS - basePe) / 0.5.
        IF ABS(sens) < 1 { BREAK. }
        LOCAL correction IS peErr / sens * 0.7.
        LOCAL newDv IS MAX(dvMin, MIN(dvMax, oldDv + correction)).
        mLog("PE[" + i + "] pe=" + ROUND(basePe/1000,1) + "km err=" + ROUND(peErr/1000,1)
            + "km sens=" + ROUND(sens,1) + " dv=" + ROUND(oldDv,1) + "->" + ROUND(newDv,1)).
        SET testNode:PROGRADE TO newDv.
        WAIT 0.05.
    }

    LOCAL finalPatch IS _getTargetPatch(testNode, targetBody).
    LOCAL bestPe IS targetPe.
    LOCAL bestAoP IS 0.
    LOCAL bestLan IS 0.
    IF finalPatch <> 0 {
        SET bestPe  TO finalPatch:PERIAPSIS.
        SET bestAoP TO finalPatch:ARGUMENTOFPERIAPSIS.
        SET bestLan TO finalPatch:LAN.
    } ELSE {
        SET testNode:PROGRADE TO lastGoodDv.
    }

    LOCAL finalDv IS testNode:PROGRADE.
    LOCAL bestUt IS testNode:TIME.
    REMOVE testNode.
    LOCAL nd IS NODE(bestUt, 0, 0, finalDv).
    ADD nd.

    LOCAL logMsg IS "Transfer -> " + targetBody:NAME + ": dV=" + ROUND(finalDv,1)
        + " m/s  Pe=" + ROUND(bestPe/1000,1) + "km  ETA=" + ROUND(bestUt - TIME:SECONDS,0) + "s".
    IF aopTarget >= 0 {
        LOCAL aopErr IS ABS(bestAoP - aopTarget).
        IF aopErr > 180 { SET aopErr TO 360 - aopErr. }
        SET logMsg TO logMsg + "  AoP=" + ROUND(bestAoP,1) + "(err " + ROUND(aopErr,1) + ")".
    }
    IF lanTarget >= 0 {
        LOCAL lanErr IS ABS(bestLan - lanTarget).
        IF lanErr > 180 { SET lanErr TO 360 - lanErr. }
        SET logMsg TO logMsg + "  LAN=" + ROUND(bestLan,1) + "(err " + ROUND(lanErr,1) + ")".
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
    RETURN nd.
}

GLOBAL FUNCTION planAoPChange {
    PARAMETER targetAoP.
    LOCAL currentAoP IS SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    LOCAL deltaAoP IS targetAoP - currentAoP.
    IF deltaAoP > 180  { SET deltaAoP TO deltaAoP - 360. }
    IF deltaAoP < -180 { SET deltaAoP TO deltaAoP + 360. }
    IF ABS(deltaAoP) < 2 { RETURN 0. }
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
    PARAMETER nd, origDV.
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

LOCAL FUNCTION _getTargetPatch {
    PARAMETER originTarget.
    PARAMETER targetBody.
    LOCAL p IS originTarget:ORBIT.
    UNTIL NOT p:HASNEXTPATCH {
        SET p TO p:NEXTPATCH.
        IF p:BODY:NAME = targetBody:NAME { RETURN p. }
    }
    RETURN 0.
}
