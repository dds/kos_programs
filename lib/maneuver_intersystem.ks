// ============================================================
// maneuver_intersystem.ks - Lambert intersystem body transfers
// (0:/lib/maneuver_intersystem.ks)
// ============================================================

GLOBAL TRANSFER_SCAN_LOOKAHEAD_HOURS IS 6.

GLOBAL FUNCTION planInterplanetaryTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER captureInc.
    PARAMETER lanTarget.
    PARAMETER aopTarget.
    PARAMETER centralBody.
    PARAMETER mu.

    LOCAL transferCenter IS targetBody:BODY.
    IF BODY:HASBODY AND BODY:BODY = targetBody:BODY {
        SET transferCenter TO BODY:BODY.
    } ELSE {
        mLogWarn("Lambert: target does not share current body's parent; "
            + "falling back to supplied central body " + centralBody:NAME + ".").
        SET transferCenter TO centralBody.
    }

    LOCAL originSma IS BODY:ORBIT:SEMIMAJORAXIS.
    LOCAL hohmannA IS (originSma + targetBody:ORBIT:SEMIMAJORAXIS) / 2.
    LOCAL hohmannTof IS CONSTANT:PI * SQRT(hohmannA^3 / transferCenter:MU).
    LOCAL shipPeriod IS SHIP:ORBIT:PERIOD.
    LOCAL nDepart IS 12.
    LOCAL nTof IS 9.
    LOCAL tofSpread IS hohmannTof * 0.3.
    LOCAL departStart IS TIME:SECONDS + 60.
    LOCAL bestDv IS 9999999.
    LOCAL bestDepart IS -1.
    LOCAL bestArrive IS -1.
    LOCAL bestPatchDv IS 9999999.
    LOCAL bestPatchDepart IS -1.
    LOCAL bestPatchArrive IS -1.
    LOCAL bestPatchPe IS -1.

    mLog("Lambert scan: " + nDepart + " departures x " + nTof
        + " TOFs, center=" + transferCenter:NAME
        + " hohmannTof=" + ROUND(hohmannTof,0) + "s").
    mLogWarn("STATS lambert setup target=" + targetBody:NAME
        + " center=" + transferCenter:NAME
        + " departSamples=" + nDepart
        + " tofSamples=" + nTof
        + " hohmannTof=" + ROUND(hohmannTof,0)).

    FROM { LOCAL di IS 0. } UNTIL di >= nDepart STEP { SET di TO di + 1. } DO {
        LOCAL departUt IS departStart + di * shipPeriod.
        LOCAL r1 IS POSITIONAT(BODY, departUt) - POSITIONAT(transferCenter, departUt).
        LOCAL v1Ship IS _lambertFrameVelocity(SHIP, transferCenter, departUt).

        FROM { LOCAL ti IS 0. } UNTIL ti >= nTof STEP { SET ti TO ti + 1. } DO {
            LOCAL tofFrac IS (ti / (nTof - 1)) - 0.5.
            LOCAL tof IS hohmannTof + tofFrac * tofSpread * 2.
            IF tof < 60 { SET tof TO 60. }
            LOCAL arriveUt IS departUt + tof.
            LOCAL r2 IS POSITIONAT(targetBody, arriveUt) - POSITIONAT(transferCenter, arriveUt).
            LOCAL result IS lambertSolve(r1, r2, tof, transferCenter:MU, FALSE).
            LOCAL v1Lambert IS result["v1"].
            LOCAL dvVec IS v1Lambert - v1Ship.
            LOCAL dvMag IS dvVec:MAG.

            IF dvMag < bestDv {
                SET bestDv TO dvMag.
                SET bestDepart TO departUt.
                SET bestArrive TO arriveUt.
                mLog("Lambert[d=" + di + ",t=" + ti + "] dV=" + ROUND(dvMag,1) + " depart T+" + ROUND(departUt - TIME:SECONDS,0) + "s").
            }

            LOCAL ndProbe IS _lambertNodeFromVector(
                departUt, dvVec, transferCenter).
            ADD ndProbe.
            WAIT 0.02.
            LOCAL patch IS _getTargetPatch(ndProbe, targetBody).
            IF patch <> 0 AND patch:PERIAPSIS > 0 AND dvMag < bestPatchDv {
                SET bestPatchDv TO dvMag.
                SET bestPatchDepart TO departUt.
                SET bestPatchArrive TO arriveUt.
                SET bestPatchPe TO patch:PERIAPSIS.
                mLog("Lambert patch[d=" + di + ",t=" + ti + "] dV="
                    + ROUND(dvMag,1) + " Pe="
                    + ROUND(bestPatchPe/1000,1) + "km depart T+"
                    + ROUND(departUt - TIME:SECONDS,0) + "s").
            }
            REMOVE ndProbe.
            WAIT 0.02.
        }
    }

    IF bestDepart < 0 {
        mLogError("planTransfer: Lambert scan found no valid solution.").
        mLogWarn("STATS lambert result target=" + targetBody:NAME + " status=no-solution").
        RETURN 0.
    }

    IF bestPatchDepart >= 0 {
        SET bestDv TO bestPatchDv.
        SET bestDepart TO bestPatchDepart.
        SET bestArrive TO bestPatchArrive.
    } ELSE {
        mLogWarn("Lambert scan found no patch-producing candidate; using raw lowest-dV solution.").
    }

    mLog("Lambert best: depart T+" + ROUND(bestDepart - TIME:SECONDS,0)
        + "s  tof=" + ROUND(bestArrive - bestDepart,0)
        + "s  dV=" + ROUND(bestDv,1)).
    mLogWarn("STATS lambert result target=" + targetBody:NAME
        + " status=grid-best departT=" + ROUND(bestDepart - TIME:SECONDS,0)
        + " tof=" + ROUND(bestArrive - bestDepart,0)
        + " dv=" + ROUND(bestDv,1)
        + " patch=" + (bestPatchDepart >= 0)
        + " PeKm=" + ROUND(bestPatchPe/1000,1)).

    LOCAL r1Best IS POSITIONAT(BODY, bestDepart) - POSITIONAT(transferCenter, bestDepart).
    LOCAL r2Best IS POSITIONAT(targetBody, bestArrive) - POSITIONAT(transferCenter, bestArrive).
    LOCAL result IS lambertSolve(r1Best, r2Best, bestArrive - bestDepart, transferCenter:MU, FALSE).
    LOCAL dvVec IS result["v1"] - _lambertFrameVelocity(SHIP, transferCenter, bestDepart).

    LOCAL nd IS _lambertNodeFromVector(bestDepart, dvVec, transferCenter).
    ADD nd.
    WAIT 0.1.

    LOCAL patch IS _getTargetPatch(nd, targetBody).
    IF NOT (patch = 0 OR patch:PERIAPSIS < 0) {
        mLog("Encounter confirmed. Pe=" + ROUND(patch:PERIAPSIS/1000, 1) + "km").
    }

    RETURN nd.
}

LOCAL FUNCTION _lambertFrameVelocity {
    PARAMETER obj.
    PARAMETER frameCenter.
    PARAMETER t.
    LOCAL dt IS 1.
    RETURN ((POSITIONAT(obj, t + dt) - POSITIONAT(frameCenter, t + dt))
        - (POSITIONAT(obj, t - dt) - POSITIONAT(frameCenter, t - dt)))
        / (2 * dt).
}

LOCAL FUNCTION _lambertNodeFromVector {
    PARAMETER burnUt.
    PARAMETER dvVec.
    PARAMETER frameCenter.

    LOCAL localR IS POSITIONAT(SHIP, burnUt) - POSITIONAT(BODY, burnUt).
    LOCAL progradeHat IS VELOCITYAT(SHIP, burnUt):ORBIT:NORMALIZED.
    LOCAL normalHat IS VCRS(localR:NORMALIZED, progradeHat):NORMALIZED.
    LOCAL radialHat IS VCRS(normalHat, progradeHat):NORMALIZED.
    LOCAL dvPro IS VDOT(dvVec, progradeHat).
    LOCAL dvNor IS VDOT(dvVec, normalHat).
    LOCAL dvRad IS VDOT(dvVec, radialHat).

    RETURN NODE(burnUt, dvRad, dvNor, dvPro).
}
