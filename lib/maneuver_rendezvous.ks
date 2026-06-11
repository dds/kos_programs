// ============================================================
// maneuver_rendezvous.ks - Vessel rendezvous and asteroid intercept
// (0:/lib/maneuver_rendezvous.ks)
// ============================================================

GLOBAL FUNCTION planRendezvous {
    PARAMETER targetVessel.
    PARAMETER opts IS LEXICON().

    IF targetVessel:BODY:NAME <> SHIP:BODY:NAME {
        mLogError("planRendezvous: target orbits " + targetVessel:BODY:NAME
            + " but ship orbits " + SHIP:BODY:NAME + ".").
        RETURN 0.
    }

    IF _shouldUseLambertVesselIntercept(targetVessel) {
        RETURN planAsteroidIntercept(targetVessel, opts).
    }

    LOCAL mu IS SHIP:BODY:MU.
    LOCAL shipSMA IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL targetSMA IS targetVessel:ORBIT:SEMIMAJORAXIS.
    LOCAL shipPeriod IS SHIP:ORBIT:PERIOD.
    LOCAL targetPeriod IS targetVessel:ORBIT:PERIOD.
    LOCAL hohmannA IS (shipSMA + targetSMA) / 2.
    LOCAL hohmannTof IS CONSTANT:PI * SQRT(hohmannA^3 / mu).
    LOCAL vShip IS SQRT(mu / shipSMA).
    LOCAL vDepart IS SQRT(mu * (2/shipSMA - 1/hohmannA)).
    LOCAL hohmannDv IS vDepart - vShip.

    mLog("Rendezvous with " + targetVessel:NAME
        + ": Hohmann dV=" + ROUND(hohmannDv, 1) + " m/s"
        + "  TOF=" + ROUND(hohmannTof, 0) + "s").

    SET TARGET TO targetVessel.
    WAIT 0.1.
    LOCAL currentPhase IS phaseAngle().
    LOCAL targetMeanMotion IS 360 / targetPeriod.
    LOCAL targetSweep IS targetMeanMotion * hohmannTof.
    LOCAL idealPhaseAngle IS 180 - targetSweep.
    LOCAL phaseDiff IS idealPhaseAngle - currentPhase.
    IF phaseDiff < 0 { SET phaseDiff TO phaseDiff + 360. }
    LOCAL shipAngRate IS 360 / shipPeriod.
    LOCAL targetAngRate IS 360 / targetPeriod.
    LOCAL relativeRate IS shipAngRate - targetAngRate.
    LOCAL waitTime IS phaseDiff / ABS(relativeRate).

    IF waitTime < 60 {
        LOCAL synodicPeriod IS ABS(shipPeriod * targetPeriod / (shipPeriod - targetPeriod)).
        SET waitTime TO waitTime + synodicPeriod.
    }

    LOCAL departUt IS TIME:SECONDS + waitTime.
    mLog("Phase: current=" + ROUND(currentPhase, 1)
        + "  ideal=" + ROUND(idealPhaseAngle, 1)
        + "  wait=" + ROUND(waitTime, 0) + "s").

    LOCAL nd IS NODE(departUt, 0, 0, hohmannDv).
    ADD nd.
    WAIT 0.1.

    LOCAL scanRange IS shipPeriod / 4.
    LOCAL scanSteps IS 20.
    LOCAL scanDt IS scanRange * 2 / scanSteps.
    LOCAL bestTime IS departUt.
    LOCAL bestCA IS _findClosestApproach(
        targetVessel, departUt + hohmannTof * 0.5, departUt + hohmannTof * 1.5, 40).

    FROM { LOCAL si IS 0. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTime IS departUt - scanRange + si * scanDt.
        IF tryTime > TIME:SECONDS + 30 {
            SET nd:TIME TO tryTime.
            WAIT 0.02.
            LOCAL tryCa IS _findClosestApproach(
                targetVessel, tryTime + hohmannTof * 0.5, tryTime + hohmannTof * 1.5, 40).
            IF tryCa["distance"] < bestCA["distance"] {
                SET bestCA TO tryCa.
                SET bestTime TO tryTime.
            }
        }
    }
    SET nd:TIME TO bestTime.
    WAIT 0.1.
    mLog("Time scan: best CA=" + ROUND(bestCA["distance"]/1000, 1) + "km"
        + " at T+" + ROUND(bestCA["time"] - TIME:SECONDS, 0) + "s").

    LOCAL tA IS MAX(TIME:SECONDS + 30, bestTime - scanDt).
    LOCAL tB IS bestTime + scanDt.
    LOCAL gr IS (SQRT(5) + 1) / 2.

    FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
        LOCAL tC IS tB - (tB - tA) / gr.
        LOCAL tD IS tA + (tB - tA) / gr.
        SET nd:TIME TO tC. WAIT 0.02.
        LOCAL caC IS _findClosestApproach(targetVessel, tC + hohmannTof * 0.4, tC + hohmannTof * 1.6, 30).
        SET nd:TIME TO tD. WAIT 0.02.
        LOCAL caD IS _findClosestApproach(targetVessel, tD + hohmannTof * 0.4, tD + hohmannTof * 1.6, 30).
        IF caC["distance"] < caD["distance"] { SET tB TO tD. } ELSE { SET tA TO tC. }
    }
    SET nd:TIME TO (tA + tB) / 2.
    WAIT 0.1.

    LOCAL dvRange IS MAX(10, ABS(hohmannDv) * 0.2).
    LOCAL dvSteps IS 20.
    LOCAL dvStep IS dvRange * 2 / dvSteps.
    LOCAL bestDv IS hohmannDv.
    SET bestCA TO _findClosestApproach(
        targetVessel, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).

    FROM { LOCAL di IS 0. } UNTIL di > dvSteps STEP { SET di TO di + 1. } DO {
        LOCAL tryDv IS hohmannDv - dvRange + di * dvStep.
        SET nd:PROGRADE TO tryDv.
        WAIT 0.02.
        LOCAL tryCa IS _findClosestApproach(
            targetVessel, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
        IF tryCa["distance"] < bestCA["distance"] {
            SET bestCA TO tryCa.
            SET bestDv TO tryDv.
        }
    }
    SET nd:PROGRADE TO bestDv.
    WAIT 0.1.

    LOCAL dvA IS MAX(bestDv - dvStep, hohmannDv - dvRange).
    LOCAL dvB IS MIN(bestDv + dvStep, hohmannDv + dvRange).
    FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
        LOCAL dvC IS dvB - (dvB - dvA) / gr.
        LOCAL dvD IS dvA + (dvB - dvA) / gr.
        SET nd:PROGRADE TO dvC. WAIT 0.02.
        LOCAL caC IS _findClosestApproach(targetVessel, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
        SET nd:PROGRADE TO dvD. WAIT 0.02.
        LOCAL caD IS _findClosestApproach(targetVessel, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
        IF caC["distance"] < caD["distance"] { SET dvB TO dvD. } ELSE { SET dvA TO dvC. }
    }
    SET nd:PROGRADE TO (dvA + dvB) / 2.
    WAIT 0.1.

    LOCAL finalCa IS _findClosestApproach(targetVessel, nd:TIME + hohmannTof * 0.3, nd:TIME + hohmannTof * 2.0, 60).
    LOCAL relVel IS (VELOCITYAT(SHIP, finalCa["time"]):ORBIT
        - VELOCITYAT(targetVessel, finalCa["time"]):ORBIT):MAG.
    mLog("Rendezvous -> " + targetVessel:NAME
        + ": dV=" + ROUND(nd:DELTAV:MAG, 1) + " m/s"
        + "  CA=" + ROUND(finalCa["distance"]/1000, 1) + "km"
        + "  relV=" + ROUND(relVel, 1) + " m/s"
        + "  ETA=" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    archivePlannedManeuverLog("rendezvous").

    RETURN nd.
}

GLOBAL FUNCTION planAsteroidIntercept {
    PARAMETER targetVessel.
    PARAMETER opts IS LEXICON().

    IF targetVessel:BODY:NAME <> SHIP:BODY:NAME {
        mLogError("planAsteroidIntercept: target orbits "
            + targetVessel:BODY:NAME + " but ship orbits "
            + SHIP:BODY:NAME + ".").
        RETURN 0.
    }

    LOCAL centralBody IS SHIP:BODY.
    LOCAL mu IS centralBody:MU.
    LOCAL shipPeriod IS SHIP:ORBIT:PERIOD.
    LOCAL targetPeriod IS targetVessel:ORBIT:PERIOD.
    LOCAL maxDepartOrbits IS 8.
    LOCAL departSamples IS 9.
    LOCAL tofSamples IS 11.
    LOCAL minTof IS shipPeriod * 0.25.
    LOCAL maxTof IS targetPeriod * 6.
    LOCAL arrivalWeight IS 0.25.
    LOCAL refineIters IS 35.

    IF opts:HASKEY("MAX_DEPART_ORBITS") { SET maxDepartOrbits TO opts["MAX_DEPART_ORBITS"]. }
    IF opts:HASKEY("DEPART_SAMPLES") { SET departSamples TO opts["DEPART_SAMPLES"]. }
    IF opts:HASKEY("TOF_SAMPLES") { SET tofSamples TO opts["TOF_SAMPLES"]. }
    IF opts:HASKEY("MIN_TOF") { SET minTof TO opts["MIN_TOF"]. }
    IF opts:HASKEY("MAX_TOF") { SET maxTof TO opts["MAX_TOF"]. }
    IF opts:HASKEY("ARRIVAL_WEIGHT") { SET arrivalWeight TO opts["ARRIVAL_WEIGHT"]. }
    IF opts:HASKEY("REFINE_ITERS") { SET refineIters TO opts["REFINE_ITERS"]. }

    LOCAL departSpan IS shipPeriod * maxDepartOrbits.
    LOCAL departStep IS departSpan / MAX(1, departSamples - 1).
    LOCAL tofStep IS (maxTof - minTof) / MAX(1, tofSamples - 1).
    LOCAL bestCost IS 9e15.
    LOCAL bestDepart IS -1.
    LOCAL bestArrive IS -1.
    LOCAL bestDvVec IS V(0, 0, 0).
    LOCAL bestRelVel IS 0.
    LOCAL bestFlip IS FALSE.
    LOCAL transferArcs IS LIST(FALSE, TRUE).

    mLog("Asteroid intercept scan: " + departSamples + " departures x "
        + tofSamples + " TOFs around " + targetVessel:NAME + ".").

    FROM { LOCAL di IS 0. } UNTIL di >= departSamples STEP { SET di TO di + 1. } DO {
        LOCAL departUt IS TIME:SECONDS + 120 + di * departStep.
        LOCAL r1 IS POSITIONAT(SHIP, departUt) - POSITIONAT(centralBody, departUt).
        LOCAL vShip IS VELOCITYAT(SHIP, departUt):ORBIT.
        FROM { LOCAL ti IS 0. } UNTIL ti >= tofSamples STEP { SET ti TO ti + 1. } DO {
            LOCAL tof IS minTof + ti * tofStep.
            LOCAL arriveUt IS departUt + tof.
            LOCAL r2 IS POSITIONAT(targetVessel, arriveUt) - POSITIONAT(centralBody, arriveUt).
            LOCAL vTarget IS VELOCITYAT(targetVessel, arriveUt):ORBIT.
            FOR flip IN transferArcs {
                LOCAL result IS lambertSolve(r1, r2, tof, mu, flip).
                LOCAL dvVec IS result["v1"] - vShip.
                LOCAL relVel IS (result["v2"] - vTarget):MAG.
                LOCAL cost IS dvVec:MAG + relVel * arrivalWeight.
                IF cost < bestCost {
                    SET bestCost TO cost.
                    SET bestDepart TO departUt.
                    SET bestArrive TO arriveUt.
                    SET bestDvVec TO dvVec.
                    SET bestRelVel TO relVel.
                    SET bestFlip TO flip.
                    mLog("Asteroid candidate dV=" + ROUND(dvVec:MAG,1)
                        + " relV=" + ROUND(relVel,1)
                        + " depart T+" + ROUND(departUt - TIME:SECONDS,0)
                        + " tof=" + ROUND(tof,0)
                        + " flip=" + bestFlip + ".").
                }
            }
        }
    }

    IF bestDepart < 0 {
        mLogError("planAsteroidIntercept: no Lambert candidate found.").
        RETURN 0.
    }

    LOCAL refine IS _refineLambertIntercept(
        targetVessel, centralBody, mu, bestDepart, bestArrive - bestDepart,
        departStep, tofStep, minTof, maxTof, arrivalWeight, refineIters).
    SET bestDepart TO refine["DEPART"].
    SET bestArrive TO refine["ARRIVE"].
    SET bestDvVec TO refine["DVVEC"].
    SET bestRelVel TO refine["RELVEL"].
    SET bestFlip TO refine["FLIP"].

    LOCAL nd IS _nodeFromDvVector(bestDepart, bestDvVec).
    ADD nd.
    WAIT 0.1.

    LOCAL refineWindow IS MAX(60, (bestArrive - bestDepart) * 0.05).
    LOCAL finalCa IS _findClosestApproach(
        targetVessel, bestArrive - refineWindow, bestArrive + refineWindow, 50).
    mLog("Asteroid intercept -> " + targetVessel:NAME
        + ": dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s  relV=" + ROUND(bestRelVel,1)
        + " m/s  CA=" + ROUND(finalCa["distance"]/1000,2)
        + "km  ETA=" + ROUND(nd:TIME - TIME:SECONDS,0)
        + "s  TOF=" + ROUND(bestArrive - bestDepart,0) + "s.").
    archivePlannedManeuverLog("asteroid-intercept").
    RETURN nd.
}

LOCAL FUNCTION _refineLambertIntercept {
    PARAMETER targetVessel.
    PARAMETER centralBody.
    PARAMETER mu.
    PARAMETER startDepart.
    PARAMETER startTof.
    PARAMETER startDepartStep.
    PARAMETER startTofStep.
    PARAMETER minTof.
    PARAMETER maxTof.
    PARAMETER arrivalWeight.
    PARAMETER maxIter.

    LOCAL departStep IS startDepartStep / 2.
    LOCAL tofStep IS startTofStep / 2.
    LOCAL best IS _evalLambertIntercept(
        targetVessel, centralBody, mu, startDepart, startTof, FALSE, arrivalWeight).
    LOCAL alternateBest IS _evalLambertIntercept(
        targetVessel, centralBody, mu, startDepart, startTof, TRUE, arrivalWeight).
    IF alternateBest["COST"] < best["COST"] { SET best TO alternateBest. }

    LOCAL signs IS LIST(1, -1).
    LOCAL transferArcs IS LIST(FALSE, TRUE).
    FROM { LOCAL i IS 0. } UNTIL i >= maxIter STEP { SET i TO i + 1. } DO {
        LOCAL improved IS FALSE.
        LOCAL bestTrial IS best.
        FOR sgn IN signs {
            LOCAL departTry IS best["DEPART"] + sgn * departStep.
            IF departTry > TIME:SECONDS + 60 {
                FOR flip IN transferArcs {
                    LOCAL departTrial IS _evalLambertIntercept(
                        targetVessel, centralBody, mu,
                        departTry, best["TOF"], flip, arrivalWeight).
                    IF departTrial["COST"] < bestTrial["COST"] {
                        SET bestTrial TO departTrial.
                        SET improved TO TRUE.
                    }
                }
            }
        }
        FOR sgn IN signs {
            LOCAL tofTry IS best["TOF"] + sgn * tofStep.
            IF tofTry >= minTof AND tofTry <= maxTof {
                FOR flip IN transferArcs {
                    LOCAL tofTrial IS _evalLambertIntercept(
                        targetVessel, centralBody, mu,
                        best["DEPART"], tofTry, flip, arrivalWeight).
                    IF tofTrial["COST"] < bestTrial["COST"] {
                        SET bestTrial TO tofTrial.
                        SET improved TO TRUE.
                    }
                }
            }
        }
        IF improved {
            SET best TO bestTrial.
            mLog("Asteroid refine[" + i + "] dV=" + ROUND(best["DV"],1)
                + " relV=" + ROUND(best["RELVEL"],1)
                + " depart T+" + ROUND(best["DEPART"] - TIME:SECONDS,0)
                + " tof=" + ROUND(best["TOF"],0)
                + " flip=" + best["FLIP"] + ".").
        } ELSE {
            SET departStep TO departStep / 2.
            SET tofStep TO tofStep / 2.
            IF departStep < 60 AND tofStep < 60 { BREAK. }
        }
    }
    RETURN best.
}

LOCAL FUNCTION _evalLambertIntercept {
    PARAMETER targetVessel.
    PARAMETER centralBody.
    PARAMETER mu.
    PARAMETER departUt.
    PARAMETER tof.
    PARAMETER flip.
    PARAMETER arrivalWeight.

    LOCAL arriveUt IS departUt + tof.
    LOCAL r1 IS POSITIONAT(SHIP, departUt) - POSITIONAT(centralBody, departUt).
    LOCAL r2 IS POSITIONAT(targetVessel, arriveUt) - POSITIONAT(centralBody, arriveUt).
    LOCAL vShip IS VELOCITYAT(SHIP, departUt):ORBIT.
    LOCAL vTarget IS VELOCITYAT(targetVessel, arriveUt):ORBIT.
    LOCAL result IS lambertSolve(r1, r2, tof, mu, flip).
    LOCAL dvVec IS result["v1"] - vShip.
    LOCAL relVel IS (result["v2"] - vTarget):MAG.
    LOCAL cost IS dvVec:MAG + relVel * arrivalWeight.

    LOCAL out IS LEXICON().
    out:ADD("COST", cost).
    out:ADD("DEPART", departUt).
    out:ADD("TOF", tof).
    out:ADD("ARRIVE", arriveUt).
    out:ADD("DVVEC", dvVec).
    out:ADD("DV", dvVec:MAG).
    out:ADD("RELVEL", relVel).
    out:ADD("FLIP", flip).
    RETURN out.
}

LOCAL FUNCTION _shouldUseLambertVesselIntercept {
    PARAMETER targetVessel.
    IF targetVessel:BODY:NAME <> SHIP:BODY:NAME { RETURN FALSE. }
    IF SHIP:BODY:NAME = "Sun" { RETURN TRUE. }
    IF targetVessel:ORBIT:ECCENTRICITY > 0.1 { RETURN TRUE. }
    IF ABS(targetVessel:ORBIT:INCLINATION - SHIP:ORBIT:INCLINATION) > 5 { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _nodeFromDvVector {
    PARAMETER burnUt.
    PARAMETER dvVec.
    LOCAL r1 IS POSITIONAT(SHIP, burnUt) - POSITIONAT(SHIP:BODY, burnUt).
    LOCAL progradeHat IS VELOCITYAT(SHIP, burnUt):ORBIT:NORMALIZED.
    LOCAL normalHat IS VCRS(r1, progradeHat):NORMALIZED.
    LOCAL radialHat IS VCRS(normalHat, progradeHat):NORMALIZED.
    LOCAL dvPro IS VDOT(dvVec, progradeHat).
    LOCAL dvNor IS VDOT(dvVec, normalHat).
    LOCAL dvRad IS VDOT(dvVec, radialHat).
    RETURN NODE(burnUt, dvRad, dvNor, dvPro).
}

// ============================================================
// MATCH phase — final rendezvous brake and close approach.
//
// 1. Node at closest approach canceling relative velocity
//    (executeManeuver gives it the KAC alarm + warp handling).
//    VELOCITYAT differences at the SAME future time are safe:
//    the parent-motion frame error cancels.
// 2. Direct-thrust close-approach loop: nudge toward the target
//    at a distance-scaled speed, coast, re-brake — repeats until
//    inside MATCH_FINAL_DIST (150m default), EVA range.
// ============================================================

LOCAL FUNCTION _matchTargetVessel {
    LOCAL nm IS "".
    IF CFG:HASKEY("RENDEZVOUS_TARGET") { SET nm TO CFG["RENDEZVOUS_TARGET"]. }
    IF nm = "" AND HASTARGET AND TARGET:ISTYPE("Vessel") {
        SET nm TO TARGET:NAME.
    }
    IF nm = "" { RETURN 0. }
    LOCAL vs IS LIST().
    LIST TARGETS IN vs.
    FOR tv IN vs {
        IF tv:NAME = nm { RETURN tv. }
    }
    RETURN 0.
}

// Burn until our velocity relative to ves equals desiredVec.
// Distance-scaled gentle throttle; waits for alignment first.
LOCAL FUNCTION _matchBurnRel {
    PARAMETER ves.
    PARAMETER desiredVec.
    LOCAL throttleCmd IS 0.
    LOCK THROTTLE TO throttleCmd.
    LOCAL deadline IS TIME:SECONDS + 180.
    UNTIL TIME:SECONDS > deadline {
        LOCAL errVec IS desiredVec - (SHIP:VELOCITY:ORBIT - ves:VELOCITY:ORBIT).
        IF errVec:MAG < 0.2 { BREAK. }
        LOCK STEERING TO errVec.
        IF VANG(SHIP:FACING:FOREVECTOR, errVec) < 5 {
            LOCAL acc IS MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS).
            SET throttleCmd TO MIN(1, MAX(0.02, errVec:MAG / acc / 0.8)).
        } ELSE {
            SET throttleCmd TO 0.
        }
        WAIT 0.05.
    }
    SET throttleCmd TO 0.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
}

GLOBAL FUNCTION phaseMatch {
    LOCAL ves IS _matchTargetVessel().
    IF NOT ves:ISTYPE("Vessel") {
        mLogWarn("MATCH: no rendezvous target found — skipping.").
        nextPhase(xferSeq).
        RETURN.
    }
    SET TARGET TO ves.
    LOCAL finalDist IS 150.
    IF CFG:HASKEY("MATCH_FINAL_DIST") { SET finalDist TO CFG["MATCH_FINAL_DIST"]. }

    // Step 1: brake at closest approach (skip if already slow+close).
    LOCAL sep IS (ves:POSITION - SHIP:POSITION):MAG.
    LOCAL relSpd IS (SHIP:VELOCITY:ORBIT - ves:VELOCITY:ORBIT):MAG.
    mLog("MATCH: " + ves:NAME + " sep=" + ROUND(sep / 1000, 2)
        + "km relV=" + ROUND(relSpd, 1) + " m/s.").
    IF sep > 5000 OR relSpd > 15 {
        LOCAL ca IS _findClosestApproach(ves, TIME:SECONDS + 60,
            TIME:SECONDS + SHIP:ORBIT:PERIOD * 1.5, 120).
        LOCAL caT IS ca["time"].
        LOCAL dvVec IS VELOCITYAT(ves, caT):ORBIT - VELOCITYAT(SHIP, caT):ORBIT.
        mLog("MATCH: brake at CA in " + ROUND(caT - TIME:SECONDS, 0)
            + "s  dist=" + ROUND(ca["distance"] / 1000, 2)
            + "km  dv=" + ROUND(dvVec:MAG, 1) + " m/s.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        ADD _nodeFromDvVector(caT, dvVec).
        IF NOT executeManeuver() {
            mLogError("MATCH: brake burn failed — holding.").
            yieldToPrompt().
            RETURN.
        }
    }

    // Step 2: close in. Direct thrust, distance-scaled speed.
    SAS OFF.
    LOCAL pass IS 0.
    UNTIL pass >= 5 {
        SET pass TO pass + 1.
        SET sep TO (ves:POSITION - SHIP:POSITION):MAG.
        IF sep < finalDist { BREAK. }
        LOCAL closeSpd IS MIN(15, MAX(1, sep / 120)).
        LOCAL approachDir IS (ves:POSITION - SHIP:POSITION):NORMALIZED.
        mLog("MATCH: approach pass " + pass + " sep="
            + ROUND(sep, 0) + "m at " + ROUND(closeSpd, 1) + " m/s.").
        _matchBurnRel(ves, approachDir * closeSpd).

        // Coast until the gap stops shrinking, then stop.
        LOCAL lastSep IS sep + 1.
        UNTIL FALSE {
            SET sep TO (ves:POSITION - SHIP:POSITION):MAG.
            IF sep < finalDist OR sep > lastSep { BREAK. }
            SET lastSep TO sep.
            WAIT 1.
        }
        _matchBurnRel(ves, V(0, 0, 0)).
    }

    SET sep TO (ves:POSITION - SHIP:POSITION):MAG.
    SET relSpd TO (SHIP:VELOCITY:ORBIT - ves:VELOCITY:ORBIT):MAG.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    mLog("MATCH complete: sep=" + ROUND(sep, 0) + "m relV="
        + ROUND(relSpd, 2) + " m/s.").
    mLogWarn("STATS match result sep=" + ROUND(sep, 0)
        + " relV=" + ROUND(relSpd, 2) + " target=" + ves:NAME).
    nextPhase(xferSeq).
}

// ============================================================
// CREW_XFER phase — hold position until the rescued kerbal is
// aboard (crew count rises), then continue the sequence. The
// starting count persists in state so a reboot mid-EVA doesn't
// re-baseline with the rescuee already aboard. AG10 skips.
// ============================================================
GLOBAL FUNCTION phaseCrewXfer {
    LOCAL startCount IS stateGetNum("crew_xfer_start", -1).
    IF startCount < 0 {
        SET startCount TO SHIP:CREW():LENGTH.
        stateSetNum("crew_xfer_start", startCount).
    }
    IF SHIP:CREW():LENGTH > startCount {
        mLog("CREW_XFER: crew aboard (" + SHIP:CREW():LENGTH + ").").
    } ELSE {
        PRINT " ".
        PRINT "  CREW TRANSFER".
        PRINT "  EVA the rescued kerbal to this ship.".
        PRINT "  (AG10 to continue without a crew change.)".
        mLog("CREW_XFER: waiting for crew count > " + startCount + ".").
        LOCAL nextHud IS 0.
        UNTIL SHIP:CREW():LENGTH > startCount OR AG10 {
            IF TIME:SECONDS > nextHud {
                HUDTEXT("Awaiting crew transfer ("
                    + SHIP:CREW():LENGTH + "/" + (startCount + 1) + ")",
                    15, 2, 16, YELLOW, FALSE).
                SET nextHud TO TIME:SECONDS + 15.
            }
            WAIT 1.
        }
        IF AG10 AND SHIP:CREW():LENGTH <= startCount {
            mLogWarn("CREW_XFER: skipped by operator (AG10).").
        }
    }
    LOCAL roster IS "".
    FOR crewMember IN SHIP:CREW() {
        SET roster TO roster + crewMember:NAME + " ".
    }
    mLogWarn("STATS crew_xfer result count=" + SHIP:CREW():LENGTH
        + " roster=" + roster:TRIM).
    stateRemove("crew_xfer_start").
    nextPhase(xferSeq).
}
