// ============================================================
// rdv_plan.ks - Lightweight same-body rendezvous planning phase
// (0:/lib/rdv_plan.ks)
// ============================================================

LOCAL RDV_MAX_RETRIES IS 5.

GLOBAL FUNCTION phaseRendezvous {
    LOCAL targetName IS "".
    IF CFG:HASKEY("RENDEZVOUS_TARGET") { SET targetName TO CFG["RENDEZVOUS_TARGET"]. }
    IF CFG:HASKEY("ASTEROID_TARGET")   { SET targetName TO CFG["ASTEROID_TARGET"]. }

    IF targetName = "" {
        mLogWarn("RDV phase requested but no RENDEZVOUS_TARGET or ASTEROID_TARGET configured.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL targetVessel IS VESSEL(targetName).
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    orbitSummary().
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS planRendezvous(targetVessel).
        IF nd = 0 {
            mLogError("Rendezvous planner failed for " + targetName + ".").
            RETURN.
        }
        mLog("Rendezvous planned with " + targetName + ".").
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Rendezvous burn missed (attempt " + retries + ") - waiting 10s.").
            IF retries >= RDV_MAX_RETRIES {
                mLogError("Rendezvous failed after " + retries + " attempts.").
                RETURN.
            }
            WAIT 10.
        }
    }

    orbitSummary().
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseRdv {
    phaseRendezvous().
}

GLOBAL FUNCTION planRendezvous {
    PARAMETER targetVessel.

    IF targetVessel:BODY:NAME <> SHIP:BODY:NAME {
        mLogError("planRendezvous: target orbits " + targetVessel:BODY:NAME
            + " but ship orbits " + SHIP:BODY:NAME + ".").
        RETURN 0.
    }
    IF targetVessel:ORBIT:ECCENTRICITY > 0.1
            OR ABS(targetVessel:ORBIT:INCLINATION - SHIP:ORBIT:INCLINATION) > 5 {
        mLogWarn("RDV uses lightweight Hohmann planner; target orbit is eccentric or inclined.").
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
