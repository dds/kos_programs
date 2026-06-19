// ============================================================
// maneuver_intersystem.ks - Lambert intersystem body transfers
// (0:/lib/maneuver_intersystem.ks)
// ============================================================

GLOBAL TRANSFER_SCAN_LOOKAHEAD_HOURS IS 6.
GLOBAL TRANSFER_INTERPLANETARY_SAMPLES_PER_ORBIT IS 24.
GLOBAL TRANSFER_INTERPLANETARY_TOF_SAMPLES IS 9.

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
    LOCAL scanHours IS MAX(0.25, TRANSFER_SCAN_LOOKAHEAD_HOURS).
    LOCAL scanSpan IS MIN(scanHours * 3600, shipPeriod * 2).
    SET scanSpan TO MAX(shipPeriod, scanSpan).
    LOCAL departStep IS MAX(45, shipPeriod / MAX(8, TRANSFER_INTERPLANETARY_SAMPLES_PER_ORBIT)).
    LOCAL nDepart IS MAX(12, CEILING(scanSpan / departStep) + 1).
    LOCAL nTof IS MAX(3, TRANSFER_INTERPLANETARY_TOF_SAMPLES).
    LOCAL tofSpread IS hohmannTof * 0.3.
    LOCAL departStart IS TIME:SECONDS + 60.
    LOCAL bestDv IS 9999999.
    LOCAL bestDepart IS -1.
    LOCAL bestArrive IS -1.
    LOCAL bestPatchDv IS 9999999.
    LOCAL bestPatchDepart IS -1.
    LOCAL bestPatchArrive IS -1.
    LOCAL bestPatchPe IS -1.
    LOCAL bestVinf IS -1.
    LOCAL bestPatchVinf IS -1.
    LOCAL bestFlip IS FALSE.
    LOCAL bestPatchFlip IS FALSE.

    mLog("Lambert scan: " + nDepart + " departures x " + nTof
        + " TOFs, center=" + transferCenter:NAME
        + " hohmannTof=" + ROUND(hohmannTof,0) + "s"
        + " departSpan=" + ROUND(scanSpan,0) + "s").
    mLogWarn("STATS lambert setup target=" + targetBody:NAME
        + " center=" + transferCenter:NAME
        + " departSamples=" + nDepart
        + " tofSamples=" + nTof
        + " hohmannTof=" + ROUND(hohmannTof,0)
        + " departSpan=" + ROUND(scanSpan,0)).

    FROM { LOCAL di IS 0. } UNTIL di >= nDepart STEP { SET di TO di + 1. } DO {
        LOCAL departUt IS departStart + di * scanSpan / MAX(1, nDepart - 1).
        LOCAL r1 IS POSITIONAT(BODY, departUt) - POSITIONAT(transferCenter, departUt).
        LOCAL vOrigin IS _lambertFrameVelocity(BODY, transferCenter, departUt).

        FROM { LOCAL ti IS 0. } UNTIL ti >= nTof STEP { SET ti TO ti + 1. } DO {
            LOCAL tofFrac IS (ti / (nTof - 1)) - 0.5.
            LOCAL tof IS hohmannTof + tofFrac * tofSpread * 2.
            IF tof < 60 { SET tof TO 60. }
            LOCAL arriveUt IS departUt + tof.
            LOCAL r2 IS POSITIONAT(targetBody, arriveUt) - POSITIONAT(transferCenter, arriveUt).

            FOR flip IN LIST(FALSE, TRUE) {
                LOCAL result IS lambertSolve(r1, r2, tof, transferCenter:MU, flip).
                LOCAL v1Lambert IS result["v1"].
                LOCAL vInfVec IS v1Lambert - vOrigin.
                LOCAL vInfMag IS vInfVec:MAG.
                LOCAL burnVec IS _lambertEscapeBurnVector(departUt, vInfVec).
                LOCAL dvMag IS burnVec:MAG.
                LOCAL ndProbe IS _nodeFromLocalVector(departUt, burnVec).

                IF dvMag < bestDv {
                    SET bestDv TO dvMag.
                    SET bestDepart TO departUt.
                    SET bestArrive TO arriveUt.
                    SET bestVinf TO vInfMag.
                    SET bestFlip TO flip.
                    mLog("Lambert[d=" + di + ",t=" + ti + ",f=" + flip
                        + "] dV=" + ROUND(dvMag,1)
                        + " vInf=" + ROUND(vInfMag,1)
                        + " depart T+"
                        + ROUND(departUt - TIME:SECONDS,0) + "s").
                }

                ADD ndProbe.
                WAIT 0.02.
                LOCAL patch IS _getTargetPatch(ndProbe, targetBody).
                IF patch <> 0 AND patch:PERIAPSIS > 0 AND dvMag < bestPatchDv {
                    SET bestPatchDv TO dvMag.
                    SET bestPatchDepart TO departUt.
                    SET bestPatchArrive TO arriveUt.
                    SET bestPatchPe TO patch:PERIAPSIS.
                    SET bestPatchVinf TO vInfMag.
                    SET bestPatchFlip TO flip.
                    mLog("Lambert patch[d=" + di + ",t=" + ti
                        + ",f=" + flip + "] dV="
                        + ROUND(dvMag,1) + " vInf=" + ROUND(vInfMag,1)
                        + " Pe="
                        + ROUND(bestPatchPe/1000,1) + "km depart T+"
                        + ROUND(departUt - TIME:SECONDS,0) + "s").
                }
                REMOVE ndProbe.
                WAIT 0.02.
            }
        }
    }

    IF bestDepart < 0 {
        mLogError("planTransfer: Lambert scan found no valid solution.").
        mLogWarn("STATS lambert result target=" + targetBody:NAME + " status=no-solution").
        RETURN 0.
    }

    IF bestPatchDepart < 0 {
        mLogError("planTransfer: Lambert scan found no " + targetBody:NAME
            + " patch seed; "
            + "not passing raw non-encounter to B-plane targeting.").
        mLogWarn("STATS lambert result target=" + targetBody:NAME
            + " status=no-patch-seed"
            + " rawDepartT=" + ROUND(bestDepart - TIME:SECONDS,0)
            + " rawTof=" + ROUND(bestArrive - bestDepart,0)
            + " rawDv=" + ROUND(bestDv,1)
            + " rawVinf=" + ROUND(bestVinf,1)
            + " rawFlip=" + bestFlip).
        RETURN 0.
    }
    SET bestDv TO bestPatchDv.
    SET bestDepart TO bestPatchDepart.
    SET bestArrive TO bestPatchArrive.
    SET bestVinf TO bestPatchVinf.
    SET bestFlip TO bestPatchFlip.

    mLog("Lambert best: depart T+" + ROUND(bestDepart - TIME:SECONDS,0)
        + "s  tof=" + ROUND(bestArrive - bestDepart,0)
        + "s  dV=" + ROUND(bestDv,1)
        + "  vInf=" + ROUND(bestVinf,1)).
    mLogWarn("STATS lambert result target=" + targetBody:NAME
        + " status=grid-best departT=" + ROUND(bestDepart - TIME:SECONDS,0)
        + " tof=" + ROUND(bestArrive - bestDepart,0)
        + " dv=" + ROUND(bestDv,1)
        + " vinf=" + ROUND(bestVinf,1)
        + " flip=" + bestFlip
        + " patch=" + (bestPatchDepart >= 0)
        + " PeKm=" + ROUND(bestPatchPe/1000,1)).

    LOCAL r1Best IS POSITIONAT(BODY, bestDepart) - POSITIONAT(transferCenter, bestDepart).
    LOCAL r2Best IS POSITIONAT(targetBody, bestArrive) - POSITIONAT(transferCenter, bestArrive).
    LOCAL result IS lambertSolve(r1Best, r2Best, bestArrive - bestDepart, transferCenter:MU, bestFlip).
    LOCAL vOriginBest IS _lambertFrameVelocity(BODY, transferCenter, bestDepart).
    LOCAL vInfBest IS result["v1"] - vOriginBest.

    LOCAL nd IS _lambertEscapeNode(bestDepart, vInfBest).
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

LOCAL FUNCTION _lambertEscapeNode {
    PARAMETER burnUt.
    PARAMETER vInfVec.

    RETURN _nodeFromLocalVector(
        burnUt, _lambertEscapeBurnVector(burnUt, vInfVec)).
}

LOCAL FUNCTION _lambertEscapeBurnVector {
    PARAMETER burnUt.
    PARAMETER vInfVec.

    LOCAL localR IS POSITIONAT(SHIP, burnUt) - POSITIONAT(BODY, burnUt).
    LOCAL rHat IS localR:NORMALIZED.
    LOCAL localVel IS _lambertFrameVelocity(SHIP, BODY, burnUt).
    LOCAL vInfMag IS vInfVec:MAG.
    LOCAL aim IS vInfVec:NORMALIZED.
    LOCAL ecc IS 1 + localR:MAG * vInfMag ^ 2 / BODY:MU.
    LOCAL sinNuInf IS SQRT(MAX(1e-6, 1 - (1 / ecc) ^ 2)).
    LOCAL tangentAim IS (aim + (1 / ecc) * rHat) / sinNuInf.
    SET tangentAim TO tangentAim - VDOT(tangentAim, rHat) * rHat.
    IF tangentAim:MAG < 1e-6 {
        SET tangentAim TO localVel:NORMALIZED.
    } ELSE {
        SET tangentAim TO tangentAim:NORMALIZED.
    }

    LOCAL burnSpeed IS SQRT(vInfMag ^ 2 + 2 * BODY:MU / localR:MAG).
    LOCAL desiredLocalVel IS tangentAim * burnSpeed.
    RETURN desiredLocalVel - localVel.
}

LOCAL FUNCTION _nodeFromLocalVector {
    PARAMETER burnUt.
    PARAMETER dvVec.
    LOCAL localR IS POSITIONAT(SHIP, burnUt) - POSITIONAT(BODY, burnUt).
    LOCAL localVel IS _lambertFrameVelocity(SHIP, BODY, burnUt).
    LOCAL progradeHat IS localVel:NORMALIZED.
    LOCAL normalHat IS VCRS(localR:NORMALIZED, progradeHat):NORMALIZED.
    LOCAL radialHat IS VCRS(progradeHat, normalHat):NORMALIZED.
    LOCAL dvPro IS VDOT(dvVec, progradeHat).
    LOCAL dvNor IS VDOT(dvVec, normalHat).
    LOCAL dvRad IS VDOT(dvVec, radialHat).

    RETURN NODE(burnUt, dvRad, dvNor, dvPro).
}
