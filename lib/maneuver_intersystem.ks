// ============================================================
// maneuver_intersystem.ks - Lambert intersystem body transfers
// (0:/lib/maneuver_intersystem.ks)
// ============================================================

GLOBAL TRANSFER_SCAN_LOOKAHEAD_HOURS IS 6.
GLOBAL TRANSFER_INTERPLANETARY_SAMPLES_PER_ORBIT IS 24.
GLOBAL TRANSFER_INTERPLANETARY_TOF_SAMPLES IS 9.
GLOBAL TRANSFER_INTERPLANETARY_MAX_DEPART_INDEX IS 35.
GLOBAL TRANSFER_INTERPLANETARY_DEPART_LEAD IS 300.

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
    SET nDepart TO MIN(nDepart, MAX(1, TRANSFER_INTERPLANETARY_MAX_DEPART_INDEX) + 1).
    LOCAL nTof IS MAX(3, TRANSFER_INTERPLANETARY_TOF_SAMPLES).
    LOCAL tofSpread IS hohmannTof * 0.3.
    LOCAL minDepartLead IS MAX(120, TRANSFER_INTERPLANETARY_DEPART_LEAD).
    LOCAL departStart IS TIME:SECONDS + minDepartLead.
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
        + " departSpan=" + ROUND(scanSpan,0) + "s"
        + " departLead=" + ROUND(minDepartLead,0) + "s").
    mLogWarn("STATS lambert setup target=" + targetBody:NAME
        + " center=" + transferCenter:NAME
        + " departSamples=" + nDepart
        + " tofSamples=" + nTof
        + " hohmannTof=" + ROUND(hohmannTof,0)
        + " departSpan=" + ROUND(scanSpan,0)
        + " departLead=" + ROUND(minDepartLead,0)).

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

                ADD ndProbe.
                WAIT 0.02.
                LOCAL safeDeparture IS _lambertDepartureSafe(ndProbe).

                IF safeDeparture AND dvMag < bestDv {
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

                LOCAL patch IS _getTargetPatch(ndProbe, targetBody).
                IF safeDeparture AND patch <> 0 AND patch:PERIAPSIS > 0
                        AND dvMag < bestPatchDv {
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

    LOCAL staleLead IS 45.
    IF bestDepart < TIME:SECONDS + staleLead {
        mLogError("planTransfer: Lambert best departure went stale during scan.").
        mLogWarn("STATS lambert result target=" + targetBody:NAME
            + " status=stale-seed"
            + " rawDepartT=" + ROUND(bestDepart - TIME:SECONDS,0)
            + " minLead=" + staleLead
            + " rawDv=" + ROUND(bestDv,1)
            + " rawVinf=" + ROUND(bestVinf,1)).
        RETURN 0.
    }

    IF bestPatchDepart < 0 {
        mLogWarn("Lambert scan found no direct patch; refining raw best "
            + "closest approach seed.").
        LOCAL rawNode IS _lambertNodeFor(
            bestDepart, bestArrive, bestFlip, targetBody, transferCenter).
        ADD rawNode.
        WAIT 0.1.
        LOCAL refinedPatch IS _refineLambertPatchSeed(
            rawNode, targetBody, bestArrive, bestDv).
        IF refinedPatch <> 0 {
            mLog("Lambert refined patch seed: dV="
                + ROUND(rawNode:DELTAV:MAG,1)
                + " Pe=" + ROUND(refinedPatch:PERIAPSIS/1000,1)
                + "km depart T+"
                + ROUND(rawNode:TIME - TIME:SECONDS,0) + "s").
            mLogWarn("STATS lambert result target=" + targetBody:NAME
                + " status=refined-patch-seed"
                + " departT=" + ROUND(rawNode:TIME - TIME:SECONDS,0)
                + " tof=" + ROUND(bestArrive - rawNode:TIME,0)
                + " dv=" + ROUND(rawNode:DELTAV:MAG,1)
                + " vinf=" + ROUND(bestVinf,1)
                + " flip=" + bestFlip
                + " PeKm=" + ROUND(refinedPatch:PERIAPSIS/1000,1)).
            RETURN rawNode.
        } ELSE {
            mLogError("planTransfer: Lambert scan found no " + targetBody:NAME
                + " patch seed after closest-approach refine.").
            mLogWarn("STATS lambert result target=" + targetBody:NAME
                + " status=no-patch-seed"
                + " rawDepartT=" + ROUND(bestDepart - TIME:SECONDS,0)
                + " rawTof=" + ROUND(bestArrive - bestDepart,0)
                + " rawDv=" + ROUND(bestDv,1)
                + " rawVinf=" + ROUND(bestVinf,1)
                + " rawFlip=" + bestFlip
                + " refinedDv=" + ROUND(rawNode:DELTAV:MAG,1)).
            REMOVE rawNode.
            RETURN 0.
        }
    }
    SET bestDv TO bestPatchDv.
    SET bestDepart TO bestPatchDepart.
    SET bestArrive TO bestPatchArrive.
    SET bestVinf TO bestPatchVinf.
    SET bestFlip TO bestPatchFlip.

    IF bestDepart < TIME:SECONDS + staleLead {
        mLogError("planTransfer: Lambert patch departure went stale during scan.").
        mLogWarn("STATS lambert result target=" + targetBody:NAME
            + " status=stale-patch"
            + " departT=" + ROUND(bestDepart - TIME:SECONDS,0)
            + " minLead=" + staleLead
            + " dv=" + ROUND(bestDv,1)
            + " vinf=" + ROUND(bestVinf,1)).
        RETURN 0.
    }

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

    LOCAL nd IS _lambertNodeFor(
        bestDepart, bestArrive, bestFlip, targetBody, transferCenter).
    ADD nd.
    WAIT 0.1.

    LOCAL patch IS _getTargetPatch(nd, targetBody).
    IF NOT (patch = 0 OR patch:PERIAPSIS < 0) {
        mLog("Encounter confirmed. Pe=" + ROUND(patch:PERIAPSIS/1000, 1) + "km").
    }

    RETURN nd.
}

LOCAL FUNCTION _lambertNodeFor {
    PARAMETER departUt.
    PARAMETER arriveUt.
    PARAMETER flip.
    PARAMETER targetBody.
    PARAMETER transferCenter.

    LOCAL r1 IS POSITIONAT(BODY, departUt)
        - POSITIONAT(transferCenter, departUt).
    LOCAL r2 IS POSITIONAT(targetBody, arriveUt)
        - POSITIONAT(transferCenter, arriveUt).
    LOCAL result IS lambertSolve(
        r1, r2, arriveUt - departUt, transferCenter:MU, flip).
    LOCAL vOrigin IS _lambertFrameVelocity(BODY, transferCenter, departUt).
    LOCAL vInf IS result["v1"] - vOrigin.
    RETURN _lambertEscapeNode(departUt, vInf).
}

LOCAL FUNCTION _lambertDepartureSafe {
    PARAMETER nd.

    LOCAL o IS nd:ORBIT.
    IF o:BODY <> BODY { RETURN TRUE. }
    IF o:HASNEXTPATCH { RETURN TRUE. }

    LOCAL peFloor IS 10000.
    IF BODY:ATM:EXISTS {
        SET peFloor TO BODY:ATM:HEIGHT + 5000.
    }

    IF o:PERIAPSIS > peFloor { RETURN TRUE. }

    LOCAL localR IS POSITIONAT(SHIP, nd:TIME) - POSITIONAT(BODY, nd:TIME).
    LOCAL localVel IS _localOrbitVelocityVector(nd:TIME).
    LOCAL postBurnVel IS localVel + _nodeLocalVector(nd).
    LOCAL outbound IS VDOT(localR, postBurnVel) >= 0.

    IF o:ECCENTRICITY >= 1 { RETURN outbound. }
    IF o:APOAPSIS > BODY:SOIRADIUS { RETURN outbound. }
    RETURN FALSE.
}

LOCAL FUNCTION _lambertPatchEval {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER arriveUt.

    LOCAL patch IS _getTargetPatch(nd, targetBody).
    LOCAL tof IS MAX(3600, arriveUt - nd:TIME).
    LOCAL pad IS MAX(21600, tof * 0.12).
    LOCAL ca IS _findClosestApproach(
        targetBody, arriveUt - pad, arriveUt + pad, 36).
    LOCAL safeDeparture IS _lambertDepartureSafe(nd).
    LOCAL score IS ca["distance"] + nd:DELTAV:MAG * 1000.
    IF NOT safeDeparture {
        SET score TO score + 9e15.
    }
    IF patch <> 0 {
        SET score TO score - targetBody:SOIRADIUS * 4.
    }
    RETURN LEXICON(
        "SCORE", score,
        "CA", ca,
        "PATCH", patch,
        "SAFE", safeDeparture
    ).
}

LOCAL FUNCTION _refineLambertPatchSeed {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER arriveUt.
    PARAMETER startDv.

    LOCAL best IS _lambertPatchEval(nd, targetBody, arriveUt).
    mLog("Lambert patch refine: start CA="
        + ROUND(best["CA"]["distance"]/1000,1)
        + "km patch=" + (best["PATCH"] <> 0)
        + " safe=" + best["SAFE"]
        + " SOI=" + ROUND(targetBody:SOIRADIUS/1000,0) + "km").
    IF NOT best["SAFE"] {
        mLogWarn("Lambert patch refine: raw seed has unsafe Kerbin Pe; "
            + "not refining an impact departure.").
        RETURN 0.
    }
    IF best["PATCH"] <> 0 { RETURN best["PATCH"]. }

    LOCAL axes IS LIST("PROGRADE", "NORMAL", "RADIALOUT", "TIME").
    LOCAL steps IS LEXICON(
        "PROGRADE", 10.0,
        "NORMAL", 20.0,
        "RADIALOUT", 20.0,
        "TIME", 180.0
    ).
    LOCAL mins IS LEXICON(
        "PROGRADE", 0.5,
        "NORMAL", 0.5,
        "RADIALOUT", 0.5,
        "TIME", 5.0
    ).
    LOCAL signs IS LIST(1, -1).
    LOCAL dvCap IS startDv + 250.

    FROM { LOCAL iter IS 0. } UNTIL iter >= 18 STEP { SET iter TO iter + 1. } DO {
        LOCAL bestAxis IS "".
        LOCAL bestValue IS 0.
        LOCAL bestTrial IS best.

        FOR axis IN axes {
            LOCAL oldVal IS _nodeAxisGet(nd, axis).
            FOR sgn IN signs {
                LOCAL trialVal IS oldVal + sgn * steps[axis].
                IF axis <> "TIME" OR trialVal > TIME:SECONDS + 30 {
                    _nodeAxisSet(nd, axis, trialVal).
                    WAIT 0.02.
                    IF nd:DELTAV:MAG <= dvCap {
                        LOCAL trial IS _lambertPatchEval(nd, targetBody, arriveUt).
                        IF trial["SAFE"] AND trial["SCORE"] < bestTrial["SCORE"] {
                            SET bestTrial TO trial.
                            SET bestAxis TO axis.
                            SET bestValue TO trialVal.
                        }
                    }
                }
            }
            _nodeAxisSet(nd, axis, oldVal).
            WAIT 0.01.
        }

        IF bestAxis <> "" {
            _nodeAxisSet(nd, bestAxis, bestValue).
            WAIT 0.02.
            SET best TO _lambertPatchEval(nd, targetBody, arriveUt).
            mLog("  Lambert seed[" + iter + "] " + bestAxis + "="
                + ROUND(bestValue,2)
                + " CA=" + ROUND(best["CA"]["distance"]/1000,1)
                + "km patch=" + (best["PATCH"] <> 0)
                + " safe=" + best["SAFE"]
                + " dV=" + ROUND(nd:DELTAV:MAG,1)).
            IF best["PATCH"] <> 0 {
                RETURN best["PATCH"].
            }
        } ELSE {
            FOR axis IN axes {
                SET steps[axis] TO steps[axis] / 2.
            }
            LOCAL small IS TRUE.
            FOR axis IN axes {
                IF steps[axis] >= mins[axis] { SET small TO FALSE. }
            }
            IF small { BREAK. }
        }
    }

    mLogWarn("STATS lambert-patch-refine target=" + targetBody:NAME
        + " finalCaKm=" + ROUND(best["CA"]["distance"]/1000,1)
        + " patch=" + (best["PATCH"] <> 0)
        + " dv=" + ROUND(nd:DELTAV:MAG,1)).
    RETURN best["PATCH"].
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
    LOCAL localVel IS _localOrbitVelocityVector(burnUt).
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
    LOCAL localVel IS _localOrbitVelocityVector(burnUt).
    LOCAL progradeHat IS localVel:NORMALIZED.
    LOCAL normalHat IS VCRS(localR:NORMALIZED, progradeHat):NORMALIZED.
    LOCAL radialHat IS VCRS(progradeHat, normalHat):NORMALIZED.
    LOCAL dvPro IS VDOT(dvVec, progradeHat).
    LOCAL dvNor IS VDOT(dvVec, normalHat).
    LOCAL dvRad IS VDOT(dvVec, radialHat).

    RETURN NODE(burnUt, dvRad, dvNor, dvPro).
}

LOCAL FUNCTION _nodeLocalVector {
    PARAMETER nd.
    LOCAL localR IS POSITIONAT(SHIP, nd:TIME) - POSITIONAT(BODY, nd:TIME).
    LOCAL localVel IS _localOrbitVelocityVector(nd:TIME).
    LOCAL progradeHat IS localVel:NORMALIZED.
    LOCAL normalHat IS VCRS(localR:NORMALIZED, progradeHat):NORMALIZED.
    LOCAL radialHat IS VCRS(progradeHat, normalHat):NORMALIZED.

    RETURN nd:PROGRADE * progradeHat
        + nd:NORMAL * normalHat
        + nd:RADIALOUT * radialHat.
}

LOCAL FUNCTION _localOrbitVelocityVector {
    PARAMETER t.

    LOCAL localR IS POSITIONAT(SHIP, t) - POSITIONAT(BODY, t).
    LOCAL dirVec IS _lambertFrameVelocity(SHIP, BODY, t).
    IF dirVec:MAG < 1e-6 {
        SET dirVec TO VELOCITYAT(SHIP, t):ORBIT.
    }
    LOCAL speed2 IS BODY:MU * (2 / localR:MAG
        - 1 / SHIP:ORBIT:SEMIMAJORAXIS).
    LOCAL speed IS SHIP:VELOCITY:ORBIT:MAG.
    IF speed2 > 0 {
        SET speed TO SQRT(speed2).
    }
    RETURN dirVec:NORMALIZED * speed.
}
