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
    LOCAL departStart IS TIME:SECONDS + 60.
    LOCAL plannedDepart IS stateGetNum("prelaunch_transfer_departure_ut", -1).
    IF plannedDepart > TIME:SECONDS + 60 {
        SET departStart TO plannedDepart - 3 * shipPeriod.
        UNTIL departStart >= TIME:SECONDS + 60 {
            SET departStart TO departStart + shipPeriod.
        }
    }
    LOCAL bestDv IS 9999999.
    LOCAL bestDepart IS -1.
    LOCAL bestArrive IS -1.

    mLog("Lambert scan: " + nDepart + " departures x " + nTof
        + " TOFs, hohmannTof=" + ROUND(hohmannTof,0) + "s").
    mLogWarn("STATS lambert setup target=" + targetBody:NAME
        + " departSamples=" + nDepart
        + " tofSamples=" + nTof
        + " hohmannTof=" + ROUND(hohmannTof,0)).

    FROM { LOCAL di IS 0. } UNTIL di >= nDepart STEP { SET di TO di + 1. } DO {
        LOCAL departUt IS departStart + di * shipPeriod.
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

            IF dvMag < bestDv {
                SET bestDv TO dvMag.
                SET bestDepart TO departUt.
                SET bestArrive TO arriveUt.
                mLog("Lambert[d=" + di + ",t=" + ti + "] dV=" + ROUND(dvMag,1) + " depart T+" + ROUND(departUt - TIME:SECONDS,0) + "s").
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
        + "s  dV=" + ROUND(bestDv,1)).
    mLogWarn("STATS lambert result target=" + targetBody:NAME
        + " status=grid-best departT=" + ROUND(bestDepart - TIME:SECONDS,0)
        + " tof=" + ROUND(bestArrive - bestDepart,0)
        + " dv=" + ROUND(bestDv,1)).

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
    IF NOT (patch = 0 OR patch:PERIAPSIS < 0) {
        mLog("Encounter confirmed. Pe=" + ROUND(patch:PERIAPSIS/1000, 1) + "km").
    }

    RETURN nd.
}
