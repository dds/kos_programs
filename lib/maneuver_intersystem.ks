// ============================================================
// maneuver_intersystem.ks - Lambert intersystem body transfers
// (0:/lib/maneuver_intersystem.ks)
// ============================================================

GLOBAL FUNCTION planInterplanetaryTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER captureInc.
    PARAMETER lanTarget.
    PARAMETER aopTarget.
    PARAMETER centralBody.
    PARAMETER mu.

    LOCAL hohmannA IS (SHIP:ORBIT:SEMIMAJORAXIS + targetBody:ORBIT:SEMIMAJORAXIS) / 2.
    LOCAL hohmannTof IS CONSTANT:PI * SQRT(hohmannA^3 / mu).
    LOCAL shipPeriod IS SHIP:ORBIT:PERIOD.
    LOCAL nDepart IS 12.
    LOCAL nTof IS 9.
    LOCAL tofSpread IS hohmannTof * 0.3.
    LOCAL bestDv IS 9999999.
    LOCAL bestDepart IS -1.
    LOCAL bestArrive IS -1.
    LOCAL bestScore IS 999999999.
    LOCAL bestIncErr IS 999.
    LOCAL bestLanErr IS 999.
    LOCAL bestAopErr IS 999.

    mLog("Lambert scan: " + nDepart + " departures x " + nTof
        + " TOFs, hohmannTof=" + ROUND(hohmannTof,0) + "s").
    mLogWarn("STATS lambert setup target=" + targetBody:NAME
        + " departSamples=" + nDepart
        + " tofSamples=" + nTof
        + " hohmannTof=" + ROUND(hohmannTof,0)
        + " incTarget=" + ROUND(captureInc,1)
        + " lanTarget=" + ROUND(lanTarget,1)
        + " aopTarget=" + ROUND(aopTarget,1)).

    FROM { LOCAL di IS 0. } UNTIL di >= nDepart STEP { SET di TO di + 1. } DO {
        LOCAL departUt IS TIME:SECONDS + 60 + di * shipPeriod.
        LOCAL r1 IS POSITIONAT(SHIP, departUt) - POSITIONAT(centralBody, departUt).
        LOCAL v1Ship IS VELOCITYAT(SHIP, departUt):ORBIT.

        FROM { LOCAL ti IS 0. } UNTIL ti >= nTof STEP { SET ti TO ti + 1. } DO {
            LOCAL tofFrac IS (ti / (nTof - 1)) - 0.5.
            LOCAL tof IS hohmannTof + tofFrac * tofSpread * 2.
            IF tof < 60 { SET tof TO 60. }
            LOCAL arriveUt IS departUt + tof.
            LOCAL r2 IS POSITIONAT(targetBody, arriveUt) - POSITIONAT(centralBody, arriveUt).
            LOCAL result IS lambertSolve(r1, r2, tof, mu, FALSE).
            LOCAL v1Lambert IS result["v1"].
            LOCAL dvVec IS v1Lambert - v1Ship.
            LOCAL dvMag IS dvVec:MAG.

            LOCAL progradeHat_ IS v1Ship:NORMALIZED.
            LOCAL normalHat_ IS VCRS(r1, progradeHat_):NORMALIZED.
            LOCAL radialHat_ IS VCRS(normalHat_, progradeHat_):NORMALIZED.
            LOCAL dvPro_ IS VDOT(dvVec, progradeHat_).
            LOCAL dvNor_ IS VDOT(dvVec, normalHat_).
            LOCAL dvRad_ IS VDOT(dvVec, radialHat_).
            LOCAL candNode IS NODE(departUt, dvRad_, dvNor_, dvPro_).
            ADD candNode.
            WAIT 0.01.
            LOCAL seedEval IS _transferSeedScore(candNode, targetBody, targetPe, captureInc, lanTarget, aopTarget, 0, dvMag).
            REMOVE candNode.

            IF seedEval["SCORE"] < bestScore {
                SET bestDv TO dvMag.
                SET bestDepart TO departUt.
                SET bestArrive TO arriveUt.
                SET bestScore TO seedEval["SCORE"].
                SET bestIncErr TO seedEval["INC_ERR"].
                SET bestLanErr TO seedEval["LAN_ERR"].
                SET bestAopErr TO seedEval["AOP_ERR"].
                mLog("Lambert[d=" + di + ",t=" + ti + "] dV="
                    + ROUND(dvMag,1)
                    + " score=" + ROUND(bestScore,2)
                    + " incErr=" + ROUND(bestIncErr,1)
                    + " LAN err=" + ROUND(bestLanErr,1)
                    + " AoP err=" + ROUND(bestAopErr,1)
                    + " depart T+" + ROUND(departUt - TIME:SECONDS,0) + "s").
            }
        }
    }

    IF bestDepart < 0 {
        mLogError("planTransfer: Lambert scan found no valid solution.").
        mLogWarn("STATS lambert result target=" + targetBody:NAME + " status=no-solution").
        RETURN 0.
    }

    mLog("Lambert best: depart T+" + ROUND(bestDepart - TIME:SECONDS,0)
        + "s  tof=" + ROUND(bestArrive - bestDepart,0)
        + "s  dV=" + ROUND(bestDv,1)
        + "  score=" + ROUND(bestScore,2)
        + "  INC err=" + ROUND(bestIncErr,1)
        + "  LAN err=" + ROUND(bestLanErr,1)
        + "  AoP err=" + ROUND(bestAopErr,1)).
    mLogWarn("STATS lambert result target=" + targetBody:NAME
        + " status=grid-best departT=" + ROUND(bestDepart - TIME:SECONDS,0)
        + " tof=" + ROUND(bestArrive - bestDepart,0)
        + " dv=" + ROUND(bestDv,1)
        + " score=" + ROUND(bestScore,2)
        + " incErr=" + ROUND(bestIncErr,1)
        + " lanErr=" + ROUND(bestLanErr,1)
        + " aopErr=" + ROUND(bestAopErr,1)).

    LOCAL r1Best IS POSITIONAT(SHIP, bestDepart) - centralBody:POSITION.
    LOCAL r2Best IS POSITIONAT(targetBody, bestArrive) - centralBody:POSITION.
    LOCAL result IS lambertSolve(r1Best, r2Best, bestArrive - bestDepart, mu, FALSE).
    LOCAL dvVec IS result["v1"] - VELOCITYAT(SHIP, bestDepart):ORBIT.

    LOCAL progradeHat IS VELOCITYAT(SHIP, bestDepart):ORBIT:NORMALIZED.
    LOCAL normalHat IS VCRS(r1Best, progradeHat):NORMALIZED.
    LOCAL radialHat IS VCRS(normalHat, progradeHat):NORMALIZED.
    LOCAL dvPro IS VDOT(dvVec, progradeHat).
    LOCAL dvNor IS VDOT(dvVec, normalHat).
    LOCAL dvRad IS VDOT(dvVec, radialHat).

    LOCAL nd IS NODE(bestDepart, dvRad, dvNor, dvPro).
    ADD nd.
    WAIT 0.1.

    LOCAL patch IS _getTargetPatch(nd, targetBody).
    IF patch = 0 OR patch:PERIAPSIS < 0 {
        mLog("Lambert node has no encounter, searching nearby...").
        LOCAL foundTime IS _findEncounter(
            nd, targetBody, bestDepart, SHIP:ORBIT:PERIOD * 2, SHIP:ORBIT:PERIOD / 8).
        IF foundTime < 0 {
            mLogWarn("No encounter found near Lambert solution - proceeding anyway.").
        } ELSE {
            SET nd:TIME TO foundTime.
            WAIT 0.1.
            mLog("Encounter found at T+" + ROUND(foundTime - TIME:SECONDS, 0) + "s").
        }
    } ELSE {
        mLog("Encounter confirmed. Pe=" + ROUND(patch:PERIAPSIS/1000, 1) + "km").
    }

    IF lanTarget >= 0 AND aopTarget < 0 {
        SET nd TO _scanForLan(nd, targetBody, lanTarget, SHIP:ORBIT:PERIOD).
    }

    LOCAL finalPatch IS _getTargetPatch(nd, targetBody).
    IF finalPatch = 0 {
        mLogWarn("STATS lambert final target=" + targetBody:NAME + " status=no-patch").
    } ELSE {
        mLogWarn("STATS lambert final target=" + targetBody:NAME
            + " status=patched PeKm=" + ROUND(finalPatch:PERIAPSIS/1000,1)
            + " inc=" + ROUND(finalPatch:INCLINATION,1)
            + " LAN=" + ROUND(finalPatch:LAN,1)
            + " AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1)).
    }

    RETURN nd.
}
