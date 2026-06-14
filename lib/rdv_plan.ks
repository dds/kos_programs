// ============================================================
// rdv_plan.ks - Lightweight same-body rendezvous planning phase
// (0:/lib/rdv_plan.ks)
// ============================================================

LOCAL RDV_MAX_RETRIES IS 5.

LOCAL FUNCTION _rdvScoreCandidate {
    PARAMETER targetVessel.
    PARAMETER ca.
    PARAMETER dv.
    PARAMETER hohmannDv.

    LOCAL caT IS ca["time"].
    LOCAL bodyPos IS POSITIONAT(SHIP:BODY, caT).
    LOCAL shipRadius IS (POSITIONAT(SHIP, caT) - bodyPos):MAG.
    LOCAL targetRadius IS (POSITIONAT(targetVessel, caT) - bodyPos):MAG.
    LOCAL radiusErr IS ABS(shipRadius - targetRadius).
    LOCAL relVel IS (VELOCITYAT(SHIP, caT):ORBIT
        - VELOCITYAT(targetVessel, caT):ORBIT):MAG.
    LOCAL score IS ca["distance"] / 1000
        + (radiusErr / 250)^2
        + relVel * 0.25
        + ABS(dv - hohmannDv) * 0.5.

    RETURN LEXICON(
        "SCORE", score,
        "CA", ca["distance"],
        "RADIUS_ERR", radiusErr,
        "RELVEL", relVel
    ).
}

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
    LOCAL seed IS _hohmannSeed(shipSMA, targetSMA, mu, targetPeriod).
    LOCAL hohmannTof IS seed["TOF"].
    LOCAL hohmannDv IS seed["DV"].

    mLog("Rendezvous with " + targetVessel:NAME
        + ": Hohmann dV=" + ROUND(hohmannDv, 1) + " m/s"
        + "  TOF=" + ROUND(hohmannTof, 0) + "s").

    SET TARGET TO targetVessel.
    WAIT 0.1.
    LOCAL currentPhase IS phaseAngle().
    LOCAL idealPhaseAngle IS seed["IDEAL_PHASE"].
    LOCAL phasePlan IS _hohmannPhaseWait(currentPhase, idealPhaseAngle,
        shipPeriod, targetPeriod, 60).
    LOCAL waitTime IS phasePlan["WAIT"].

    LOCAL departUt IS TIME:SECONDS + waitTime.
    mLog("Phase: current=" + ROUND(currentPhase, 1)
        + "  ideal=" + ROUND(idealPhaseAngle, 1)
        + "  diff=" + ROUND(phasePlan["DIFF"], 1)
        + "  wait=" + ROUND(waitTime, 0) + "s").

    LOCAL nd IS NODE(departUt, 0, 0, hohmannDv).
    ADD nd.
    WAIT 0.1.

    LOCAL scanOrbits IS 2.
    IF CFG:HASKEY("RDV_SCAN_ORBITS") { SET scanOrbits TO MAX(1, CFG["RDV_SCAN_ORBITS"]). }
    LOCAL samplesPerOrbit IS 8.
    IF CFG:HASKEY("RDV_SCAN_SAMPLES_PER_ORBIT") {
        SET samplesPerOrbit TO MAX(4, CFG["RDV_SCAN_SAMPLES_PER_ORBIT"]).
    }
    LOCAL scanSteps IS scanOrbits * samplesPerOrbit.
    LOCAL scanDt IS shipPeriod / samplesPerOrbit.
    LOCAL bestTime IS departUt.
    LOCAL bestCA IS _findClosestApproach(
        targetVessel, departUt + hohmannTof * 0.5, departUt + hohmannTof * 1.5, 40).
    LOCAL bestScore IS _rdvScoreCandidate(targetVessel, bestCA, nd:PROGRADE, hohmannDv).

    FROM { LOCAL si IS -scanSteps. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTime IS departUt + si * scanDt.
        IF tryTime > TIME:SECONDS + 30 {
            SET nd:TIME TO tryTime.
            WAIT 0.02.
            LOCAL tryCa IS _findClosestApproach(
                targetVessel, tryTime + hohmannTof * 0.5, tryTime + hohmannTof * 1.5, 40).
            LOCAL tryScore IS _rdvScoreCandidate(targetVessel, tryCa, nd:PROGRADE, hohmannDv).
            IF tryScore["SCORE"] < bestScore["SCORE"] {
                SET bestCA TO tryCa.
                SET bestScore TO tryScore.
                SET bestTime TO tryTime.
            }
        }
    }
    SET nd:TIME TO bestTime.
    WAIT 0.1.
    mLog("Time scan: best CA=" + ROUND(bestCA["distance"]/1000, 1) + "km"
        + " radiusErr=" + ROUND(bestScore["RADIUS_ERR"]/1000, 1) + "km"
        + " score=" + ROUND(bestScore["SCORE"], 1)
        + " at T+" + ROUND(bestCA["time"] - TIME:SECONDS, 0) + "s").

    LOCAL tA IS MAX(TIME:SECONDS + 30, bestTime - scanDt).
    LOCAL tB IS bestTime + scanDt.
    LOCAL gr IS (SQRT(5) + 1) / 2.

    FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
        LOCAL tC IS tB - (tB - tA) / gr.
        LOCAL tD IS tA + (tB - tA) / gr.
        SET nd:TIME TO tC. WAIT 0.02.
        LOCAL caC IS _findClosestApproach(targetVessel, tC + hohmannTof * 0.4, tC + hohmannTof * 1.6, 30).
        LOCAL scoreC IS _rdvScoreCandidate(targetVessel, caC, nd:PROGRADE, hohmannDv).
        SET nd:TIME TO tD. WAIT 0.02.
        LOCAL caD IS _findClosestApproach(targetVessel, tD + hohmannTof * 0.4, tD + hohmannTof * 1.6, 30).
        LOCAL scoreD IS _rdvScoreCandidate(targetVessel, caD, nd:PROGRADE, hohmannDv).
        IF scoreC["SCORE"] < scoreD["SCORE"] { SET tB TO tD. } ELSE { SET tA TO tC. }
    }
    SET nd:TIME TO (tA + tB) / 2.
    WAIT 0.1.

    LOCAL dvRange IS MAX(0.5, ABS(hohmannDv) * 0.25).
    LOCAL dvSteps IS 20.
    LOCAL dvStep IS dvRange * 2 / dvSteps.
    LOCAL bestDv IS hohmannDv.
    LOCAL dvLow IS hohmannDv - dvRange.
    LOCAL dvHigh IS hohmannDv + dvRange.
    IF hohmannDv > 0 { SET dvLow TO MAX(hohmannDv * 0.5, dvLow). }
    IF hohmannDv < 0 { SET dvHigh TO MIN(hohmannDv * 0.5, dvHigh). }
    SET bestCA TO _findClosestApproach(
        targetVessel, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
    SET bestScore TO _rdvScoreCandidate(targetVessel, bestCA, nd:PROGRADE, hohmannDv).

    FROM { LOCAL di IS 0. } UNTIL di > dvSteps STEP { SET di TO di + 1. } DO {
        LOCAL tryDv IS dvLow + di * (dvHigh - dvLow) / dvSteps.
        SET nd:PROGRADE TO tryDv.
        WAIT 0.02.
        LOCAL tryCa IS _findClosestApproach(
            targetVessel, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
        LOCAL tryScore IS _rdvScoreCandidate(targetVessel, tryCa, tryDv, hohmannDv).
        IF tryScore["SCORE"] < bestScore["SCORE"] {
            SET bestCA TO tryCa.
            SET bestScore TO tryScore.
            SET bestDv TO tryDv.
        }
    }
    SET nd:PROGRADE TO bestDv.
    WAIT 0.1.

    LOCAL dvA IS MAX(bestDv - dvStep, dvLow).
    LOCAL dvB IS MIN(bestDv + dvStep, dvHigh).
    FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
        LOCAL dvC IS dvB - (dvB - dvA) / gr.
        LOCAL dvD IS dvA + (dvB - dvA) / gr.
        SET nd:PROGRADE TO dvC. WAIT 0.02.
        LOCAL caC IS _findClosestApproach(targetVessel, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
        LOCAL scoreC IS _rdvScoreCandidate(targetVessel, caC, dvC, hohmannDv).
        SET nd:PROGRADE TO dvD. WAIT 0.02.
        LOCAL caD IS _findClosestApproach(targetVessel, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
        LOCAL scoreD IS _rdvScoreCandidate(targetVessel, caD, dvD, hohmannDv).
        IF scoreC["SCORE"] < scoreD["SCORE"] { SET dvB TO dvD. } ELSE { SET dvA TO dvC. }
    }
    SET nd:PROGRADE TO (dvA + dvB) / 2.
    WAIT 0.1.

    LOCAL finalCa IS _findClosestApproach(targetVessel, nd:TIME + hohmannTof * 0.3, nd:TIME + hohmannTof * 2.0, 60).
    LOCAL finalScore IS _rdvScoreCandidate(targetVessel, finalCa, nd:PROGRADE, hohmannDv).
    LOCAL relVel IS (VELOCITYAT(SHIP, finalCa["time"]):ORBIT
        - VELOCITYAT(targetVessel, finalCa["time"]):ORBIT):MAG.
    mLog("Rendezvous -> " + targetVessel:NAME
        + ": dV=" + ROUND(nd:DELTAV:MAG, 1) + " m/s"
        + "  CA=" + ROUND(finalCa["distance"]/1000, 1) + "km"
        + "  radiusErr=" + ROUND(finalScore["RADIUS_ERR"]/1000, 1) + "km"
        + "  relV=" + ROUND(relVel, 1) + " m/s"
        + "  ETA=" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    mLogWarn("STATS rdv result target=" + targetVessel:NAME
        + " dv=" + ROUND(nd:DELTAV:MAG,1)
        + " caKm=" + ROUND(finalCa["distance"]/1000,1)
        + " radiusErrKm=" + ROUND(finalScore["RADIUS_ERR"]/1000,1)
        + " relV=" + ROUND(relVel,1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).

    LOCAL maxCa IS 50000.
    LOCAL maxRadiusErr IS 5000.
    IF CFG:HASKEY("RDV_MAX_CA") { SET maxCa TO CFG["RDV_MAX_CA"]. }
    IF CFG:HASKEY("RDV_MAX_RADIUS_ERR") { SET maxRadiusErr TO CFG["RDV_MAX_RADIUS_ERR"]. }
    IF finalCa["distance"] > maxCa OR finalScore["RADIUS_ERR"] > maxRadiusErr {
        mLogError("Rendezvous planner refused weak intercept: CA="
            + ROUND(finalCa["distance"]/1000,1) + "km radiusErr="
            + ROUND(finalScore["RADIUS_ERR"]/1000,1) + "km.").
        IF HASNODE { REMOVE nd. }
        RETURN 0.
    }
    archivePlannedManeuverLog("rendezvous").

    RETURN nd.
}
