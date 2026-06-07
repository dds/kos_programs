// ============================================================
// maneuver_intersystem.ks - Lambert intersystem body transfers
// (0:/lib/maneuver_intersystem.ks)
// ============================================================

GLOBAL FUNCTION planInterplanetaryTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER lanTarget.
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
    LOCAL bestLanErr IS 999.
    LOCAL lanTol IS 0.5.
    IF CFG:HASKEY("LAN_ERR_TOL") { SET lanTol TO CFG["LAN_ERR_TOL"]. }

    mLog("Lambert scan: " + nDepart + " departures x " + nTof
        + " TOFs, hohmannTof=" + ROUND(hohmannTof,0) + "s").

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

            IF dvMag < bestDv * 1.05 {
                LOCAL lanErr IS 999.
                IF lanTarget >= 0 {
                    LOCAL v2Lambert IS result["v2"].
                    LOCAL captureNormal IS VCRS(r2, v2Lambert):NORMALIZED.
                    LOCAL northPole IS V(0, 1, 0).
                    LOCAL nodeVec IS VCRS(northPole, captureNormal):NORMALIZED.
                    LOCAL estimatedLan IS ARCTAN2(nodeVec:Y, nodeVec:X).
                    IF estimatedLan < 0 { SET estimatedLan TO estimatedLan + 360. }
                    SET lanErr TO lanTarget - estimatedLan.
                    IF lanErr > 180 { SET lanErr TO lanErr - 360. }
                    IF lanErr < -180 { SET lanErr TO lanErr + 360. }
                }

                LOCAL betterSolution IS FALSE.
                IF lanTarget < 0 {
                    IF dvMag < bestDv { SET betterSolution TO TRUE. }
                } ELSE {
                    IF ABS(lanErr) < ABS(bestLanErr) AND dvMag < bestDv * 1.10 {
                        SET betterSolution TO TRUE.
                    }
                    IF ABS(lanErr) <= lanTol AND dvMag < bestDv {
                        SET betterSolution TO TRUE.
                    }
                }

                IF betterSolution {
                    SET bestDv TO dvMag.
                    SET bestDepart TO departUt.
                    SET bestArrive TO arriveUt.
                    SET bestLanErr TO lanErr.
                    mLog("Lambert[d=" + di + ",t=" + ti + "] dV="
                        + ROUND(dvMag,1) + " LAN err=" + ROUND(lanErr,1)
                        + " depart T+" + ROUND(departUt - TIME:SECONDS,0) + "s").
                }
            }
        }
    }

    IF bestDepart < 0 {
        mLogError("planTransfer: Lambert scan found no valid solution.").
        RETURN 0.
    }

    mLog("Lambert best: depart T+" + ROUND(bestDepart - TIME:SECONDS,0)
        + "s  tof=" + ROUND(bestArrive - bestDepart,0)
        + "s  dV=" + ROUND(bestDv,1)
        + "  LAN err=" + ROUND(bestLanErr,1)).

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

    IF lanTarget >= 0 {
        SET nd TO _scanForLan(nd, targetBody, lanTarget, SHIP:ORBIT:PERIOD).
    }

    RETURN nd.
}
