// ============================================================
// maneuver_intersystem.ks - Lambert intersystem body transfers
// (0:/lib/maneuver_intersystem.ks)
// ============================================================

GLOBAL TRANSFER_SCAN_LOOKAHEAD_HOURS IS 6.
GLOBAL TRANSFER_INTERPLANETARY_SAMPLES_PER_ORBIT IS 24.
GLOBAL TRANSFER_INTERPLANETARY_TOF_SAMPLES IS 13.
GLOBAL TRANSFER_INTERPLANETARY_MAX_DEPART_INDEX IS 27.
GLOBAL TRANSFER_INTERPLANETARY_DEPART_LEAD IS 300.
GLOBAL TRANSFER_LAMBERT_MIN_NODE_DV IS 10.
GLOBAL TRANSFER_INTERPLANETARY_TOF_SPREAD_FRAC IS 0.45.
GLOBAL TRANSFER_LAMBERT_SHORTLIST IS 10.
GLOBAL TRANSFER_LAMBERT_REFINE_MAX_ITER IS 36.
GLOBAL TRANSFER_LAMBERT_REFINE_STALL_LIMIT IS 3.

LOCAL FUNCTION _lambertShortlistAdd {
    PARAMETER shortlist.
    PARAMETER cand.
    PARAMETER maxLen.

    IF shortlist:LENGTH < maxLen {
        shortlist:ADD(cand).
        RETURN.
    }

    LOCAL worstI IS 0.
    LOCAL worstDv IS shortlist[0]["DV"].
    FROM { LOCAL i IS 1. } UNTIL i >= shortlist:LENGTH STEP { SET i TO i + 1. } DO {
        IF shortlist[i]["DV"] > worstDv {
            SET worstI TO i.
            SET worstDv TO shortlist[i]["DV"].
        }
    }

    IF cand["DV"] < worstDv {
        SET shortlist[worstI] TO cand.
    }
}

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
    LOCAL scanSpan IS scanHours * 3600.
    LOCAL departStep IS MAX(45, shipPeriod / MAX(8, TRANSFER_INTERPLANETARY_SAMPLES_PER_ORBIT)).
    LOCAL nDepart IS MAX(12, CEILING(scanSpan / departStep) + 1).
    SET nDepart TO MIN(nDepart, MAX(1, TRANSFER_INTERPLANETARY_MAX_DEPART_INDEX) + 1).
    LOCAL nTof IS MAX(3, TRANSFER_INTERPLANETARY_TOF_SAMPLES).
    LOCAL tofSpread IS hohmannTof * MAX(0.1, TRANSFER_INTERPLANETARY_TOF_SPREAD_FRAC).
    LOCAL minDepartLead IS MAX(120, TRANSFER_INTERPLANETARY_DEPART_LEAD).
    LOCAL departStart IS TIME:SECONDS + minDepartLead.
    LOCAL bestDv IS 9999999.
    LOCAL bestDepart IS -1.
    LOCAL bestArrive IS -1.
    LOCAL bestPatchPe IS -1.
    LOCAL bestCaKm IS 999999999.
    LOCAL bestVinf IS 9999999.
    LOCAL bestFlip IS FALSE.
    LOCAL bestAnalyticDv IS -1.
    LOCAL bestDvDelta IS -1.
    LOCAL bestPro IS 0.
    LOCAL bestNor IS 0.
    LOCAL bestRad IS 0.
    LOCAL rawDepart IS -1.
    LOCAL rawArrive IS -1.
    LOCAL rawDv IS 9999999.
    LOCAL rawVinf IS 9999999.
    LOCAL rawFlip IS FALSE.
    LOCAL gates IS _lambertAnalyticGates(targetBody, transferCenter).
    LOCAL vinfGate IS gates["VINF_GATE"].
    LOCAL dvGate IS gates["DV_GATE"].

    mLog("Lambert scan: " + nDepart + " departures x " + nTof
        + " TOFs, center=" + transferCenter:NAME
        + " hohmannTof=" + ROUND(hohmannTof,0) + "s"
        + " departSpan=" + ROUND(scanSpan,0) + "s"
        + " departLead=" + ROUND(minDepartLead,0) + "s"
        + " vInfH=" + ROUND(gates["VINF_HOHMANN"],1)
        + " dvEject=" + ROUND(gates["DV_EJECT"],1)).
    mLogWarn("STATS lambert setup target=" + targetBody:NAME
        + " center=" + transferCenter:NAME
        + " departSamples=" + nDepart
        + " tofSamples=" + nTof
        + " hohmannTof=" + ROUND(hohmannTof,0)
        + " departSpan=" + ROUND(scanSpan,0)
        + " departLead=" + ROUND(minDepartLead,0)
        + " vInfHohmann=" + ROUND(gates["VINF_HOHMANN"],1)
        + " dvEject=" + ROUND(gates["DV_EJECT"],1)
        + " vinfGate=" + ROUND(vinfGate,1)
        + " dvGate=" + ROUND(dvGate,1)).
    _lambertLogFrameSetup(targetBody, transferCenter).

    LOCAL scanStartClock IS TIME:SECONDS.
    LOCAL pass1Cells IS 0.
    LOCAL pass1Survivors IS 0.
    LOCAL pass2Evals IS 0.
    LOCAL shortlist IS LIST().
    LOCAL shortlistMax IS MAX(1, TRANSFER_LAMBERT_SHORTLIST).

    FROM { LOCAL di IS 0. } UNTIL di >= nDepart STEP { SET di TO di + 1. } DO {
        LOCAL departUt IS departStart + di * scanSpan / MAX(1, nDepart - 1).
        LOCAL originState IS orbitalStateVectors(BODY, departUt, transferCenter).
        LOCAL r1 IS originState["p"].
        LOCAL vOrigin IS originState["v"].

        FROM { LOCAL ti IS 0. } UNTIL ti >= nTof STEP { SET ti TO ti + 1. } DO {
            LOCAL tofFrac IS (ti / (nTof - 1)) - 0.5.
            LOCAL tof IS hohmannTof + tofFrac * tofSpread * 2.
            IF tof < 60 { SET tof TO 60. }
            LOCAL arriveUt IS departUt + tof.
            LOCAL targetState IS orbitalStateVectors(targetBody, arriveUt, transferCenter).
            LOCAL r2 IS targetState["p"].

            FOR flip IN LIST(FALSE, TRUE) {
                SET pass1Cells TO pass1Cells + 1.
                LOCAL result IS lambertSolve(r1, r2, tof, transferCenter:MU, flip).
                LOCAL v1Lambert IS result["v1"].
                LOCAL vInfVec IS v1Lambert - vOrigin.
                LOCAL vInfMag IS vInfVec:MAG.
                LOCAL burnVec IS _lambertEscapeBurnVector(departUt, vInfVec).
                LOCAL dvMag IS burnVec:MAG.
                LOCAL canEncounter IS vInfMag < vinfGate
                    AND dvMag > TRANSFER_LAMBERT_MIN_NODE_DV
                    AND dvMag < dvGate.

                IF canEncounter AND vInfMag < rawVinf {
                    SET rawDepart TO departUt.
                    SET rawArrive TO arriveUt.
                    SET rawDv TO dvMag.
                    SET rawVinf TO vInfMag.
                    SET rawFlip TO flip.
                    mLog("Lambert[d=" + di + ",t=" + ti + ",f=" + flip
                        + "] dV=" + ROUND(dvMag,1)
                        + " vInf=" + ROUND(vInfMag,1)
                        + " depart T+"
                        + ROUND(departUt - TIME:SECONDS,0) + "s").
                }

                IF di = 0 AND ti = 0 AND flip {
                    mLogWarn("STATS lambert-cell d=0 t=0 f=True"
                        + " pass=analytic"
                        + " vInf=" + ROUND(vInfMag,1)
                        + " dv=" + ROUND(dvMag,1)
                        + " soiKm=" + ROUND(targetBody:SOIRADIUS/1000,1)
                        + " gated=" + canEncounter).
                }

                IF canEncounter {
                    SET pass1Survivors TO pass1Survivors + 1.
                    LOCAL cand IS LEXICON(
                        "DEPART", departUt,
                        "ARRIVE", arriveUt,
                        "FLIP", flip,
                        "DV", dvMag,
                        "VINF", vInfMag,
                        "DI", di,
                        "TI", ti,
                        "TOF", tof
                    ).
                    _lambertShortlistAdd(shortlist, cand, shortlistMax).
                }
            }
        }
    }

    mLogWarn("STATS lambert-pass1 target=" + targetBody:NAME
        + " cells=" + pass1Cells
        + " survivors=" + pass1Survivors
        + " shortlist=" + shortlist:LENGTH
        + " oldLiveEvals=" + pass1Cells).

    FOR cand IN shortlist {
        LOCAL ndProbe IS _lambertNodeFor(
            cand["DEPART"], cand["ARRIVE"], cand["FLIP"],
            targetBody, transferCenter).
        ADD ndProbe.
        WAIT 0.02.
        SET pass2Evals TO pass2Evals + 1.
        LOCAL safeDeparture IS _lambertDepartureSafe(ndProbe).
        LOCAL nodeDv IS ndProbe:DELTAV:MAG.
        LOCAL nodePro IS ndProbe:PROGRADE.
        LOCAL nodeNor IS ndProbe:NORMAL.
        LOCAL nodeRad IS ndProbe:RADIALOUT.
        LOCAL dvDelta IS ABS(nodeDv - cand["DV"]).
        LOCAL dvAgree IS dvDelta <= MAX(0.5, cand["DV"] * 0.005).
        LOCAL caKm IS -1.
        LOCAL patch IS 0.
        IF safeDeparture AND dvAgree {
            LOCAL pad IS MAX(21600, cand["TOF"] * 0.12).
            LOCAL ca IS _findClosestApproach(
                targetBody, cand["ARRIVE"] - pad, cand["ARRIVE"] + pad, 36).
            SET caKm TO ca["distance"] / 1000.
            SET patch TO _getTargetPatch(ndProbe, targetBody).
        }
        mLog("Lambert confirm[d=" + cand["DI"]
            + ",t=" + cand["TI"]
            + ",f=" + cand["FLIP"] + "] analyticDv="
            + ROUND(cand["DV"],1)
            + " nodeDv=" + ROUND(nodeDv,1)
            + " dvDelta=" + ROUND(dvDelta,2)
            + " vInf=" + ROUND(cand["VINF"],1)
            + " prograde=" + ROUND(nodePro,1)
            + " normal=" + ROUND(nodeNor,1)
            + " radial=" + ROUND(nodeRad,1)
            + " CA=" + ROUND(caKm,1)
            + "km safe=" + safeDeparture
            + " dvAgree=" + dvAgree
            + " depart T+"
            + ROUND(cand["DEPART"] - TIME:SECONDS,0) + "s").

        IF safeDeparture AND dvAgree AND caKm >= 0
                AND caKm < bestCaKm {
            SET bestDv TO nodeDv.
            SET bestAnalyticDv TO cand["DV"].
            SET bestDvDelta TO dvDelta.
            SET bestPro TO nodePro.
            SET bestNor TO nodeNor.
            SET bestRad TO nodeRad.
            SET bestDepart TO cand["DEPART"].
            SET bestArrive TO cand["ARRIVE"].
            SET bestVinf TO cand["VINF"].
            SET bestFlip TO cand["FLIP"].
            SET bestCaKm TO caKm.
            SET bestPatchPe TO -1.
            IF patch <> 0 { SET bestPatchPe TO patch:PERIAPSIS. }
            mLog("Lambert refine-seed[d=" + cand["DI"]
                + ",t=" + cand["TI"]
                + ",f=" + cand["FLIP"] + "] dV="
                + ROUND(nodeDv,1) + " vInf=" + ROUND(cand["VINF"],1)
                + " CA=" + ROUND(caKm,1)
                + "km depart T+"
                + ROUND(cand["DEPART"] - TIME:SECONDS,0) + "s").
        }
        REMOVE ndProbe.
        WAIT 0.02.
    }

    mLogWarn("STATS lambert-pass2 target=" + targetBody:NAME
        + " evals=" + pass2Evals
        + " selectedDepartT=" + ROUND(bestDepart - TIME:SECONDS,0)
        + " selectedAnalyticDv=" + ROUND(bestAnalyticDv,1)
        + " selectedDv=" + ROUND(bestDv,1)
        + " selectedDvDelta=" + ROUND(bestDvDelta,2)
        + " selectedVinf=" + ROUND(bestVinf,1)
        + " selectedPrograde=" + ROUND(bestPro,1)
        + " selectedNormal=" + ROUND(bestNor,1)
        + " selectedRadial=" + ROUND(bestRad,1)
        + " selectedCaKm=" + ROUND(bestCaKm,1)
        + " scanWall=" + ROUND(TIME:SECONDS - scanStartClock,1)
        + " oldLiveEvals=" + pass1Cells).

    IF bestDepart < 0 {
        mLogError("planTransfer: Lambert scan found no gated "
            + targetBody:NAME + " encounter seed.").
        mLogWarn("STATS lambert result target=" + targetBody:NAME
            + " status=no-encounter-seed"
            + " rawDepartT=" + ROUND(rawDepart - TIME:SECONDS,0)
            + " rawTof=" + ROUND(rawArrive - rawDepart,0)
            + " rawDv=" + ROUND(rawDv,1)
            + " rawVinf=" + ROUND(rawVinf,1)
            + " rawFlip=" + rawFlip
            + " vinfGate=" + ROUND(vinfGate,1)
            + " dvGate=" + ROUND(dvGate,1)
            + " minDv=" + ROUND(TRANSFER_LAMBERT_MIN_NODE_DV,1)).
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
            + " rawVinf=" + ROUND(bestVinf,1)
            + " caKm=" + ROUND(bestCaKm,1)).
        RETURN 0.
    }

    LOCAL seedInfo IS _lambertSelectionInfo(
        "refine-seed", bestDepart, bestArrive, bestFlip,
        targetBody, transferCenter, hohmannTof, gates).
    _lambertLogSelection(seedInfo, targetBody, transferCenter).

    mLog("Lambert best refine seed: depart T+"
        + ROUND(bestDepart - TIME:SECONDS,0)
        + "s  tof=" + ROUND(bestArrive - bestDepart,0)
        + "s  dV=" + ROUND(bestDv,1)
        + "  vInf=" + ROUND(bestVinf,1)
        + "  CA=" + ROUND(bestCaKm,1) + "km").
    mLogWarn("STATS lambert result target=" + targetBody:NAME
        + " status=refine-seed departT=" + ROUND(bestDepart - TIME:SECONDS,0)
        + " tof=" + ROUND(bestArrive - bestDepart,0)
        + " dv=" + ROUND(bestDv,1)
        + " vinf=" + ROUND(bestVinf,1)
        + " flip=" + bestFlip
        + " caKm=" + ROUND(bestCaKm,1)
        + " PeKm=" + ROUND(bestPatchPe/1000,1)).

    LOCAL nd IS _lambertNodeFor(
        bestDepart, bestArrive, bestFlip, targetBody, transferCenter).
    ADD nd.
    WAIT 0.1.

    LOCAL refinedPatch IS _refineLambertPatchSeed(
        nd, targetBody, bestArrive, bestDv).
    LOCAL finalEval IS _lambertPatchEval(nd, targetBody, bestArrive).
    LOCAL finalCaKm IS finalEval["CA"]["distance"] / 1000.
    LOCAL finalPatch IS finalEval["PATCH"].
    IF finalPatch <> 0 AND finalCaKm * 1000 < targetBody:SOIRADIUS {
        mLog("Encounter confirmed. Pe="
            + ROUND(finalPatch:PERIAPSIS/1000, 1)
            + "km CA=" + ROUND(finalCaKm,1) + "km").
        mLogWarn("STATS lambert result target=" + targetBody:NAME
            + " status=refined-patch-seed"
            + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)
            + " tof=" + ROUND(bestArrive - nd:TIME,0)
            + " dv=" + ROUND(nd:DELTAV:MAG,1)
            + " vinf=" + ROUND(bestVinf,1)
            + " flip=" + bestFlip
            + " startCaKm=" + ROUND(bestCaKm,1)
            + " finalCaKm=" + ROUND(finalCaKm,1)
            + " PeKm=" + ROUND(finalPatch:PERIAPSIS/1000,1)).
        RETURN nd.
    }

    mLogError("planTransfer: Lambert refinement did not reach "
        + targetBody:NAME + " SOI.").
    mLogWarn("STATS lambert result target=" + targetBody:NAME
        + " status=refine-failed"
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)
        + " dv=" + ROUND(nd:DELTAV:MAG,1)
        + " vinf=" + ROUND(bestVinf,1)
        + " flip=" + bestFlip
        + " startCaKm=" + ROUND(bestCaKm,1)
        + " finalCaKm=" + ROUND(finalCaKm,1)
        + " patch=" + (finalPatch <> 0)
        + " refinedPatch=" + (refinedPatch <> 0)).
    REMOVE nd.
    RETURN 0.
}

LOCAL FUNCTION _lambertNodeFor {
    PARAMETER departUt.
    PARAMETER arriveUt.
    PARAMETER flip.
    PARAMETER targetBody.
    PARAMETER transferCenter.

    LOCAL originState IS orbitalStateVectors(BODY, departUt, transferCenter).
    LOCAL targetState IS orbitalStateVectors(targetBody, arriveUt, transferCenter).
    LOCAL r1 IS originState["p"].
    LOCAL r2 IS targetState["p"].
    LOCAL result IS lambertSolve(
        r1, r2, arriveUt - departUt, transferCenter:MU, flip).
    LOCAL vOrigin IS originState["v"].
    LOCAL vInf IS result["v1"] - vOrigin.
    RETURN _lambertEscapeNode(departUt, vInf).
}

LOCAL FUNCTION _lambertLogFrameSetup {
    PARAMETER targetBody.
    PARAMETER transferCenter.

    mLogWarn("STATS lambert-frame target=" + targetBody:NAME
        + " originStateCenter=" + transferCenter:NAME
        + " targetStateCenter=" + transferCenter:NAME
        + " shipLocalStateCenter=" + BODY:NAME).
}

LOCAL FUNCTION _lambertAnalyticGates {
    PARAMETER targetBody.
    PARAMETER transferCenter.

    LOCAL rOrigin IS BODY:ORBIT:SEMIMAJORAXIS.
    LOCAL rTarget IS targetBody:ORBIT:SEMIMAJORAXIS.
    LOCAL aTransfer IS (rOrigin + rTarget) / 2.
    LOCAL vTransfer IS SQRT(transferCenter:MU
        * (2 / rOrigin - 1 / aTransfer)).
    LOCAL vOriginCirc IS SQRT(transferCenter:MU / rOrigin).
    LOCAL vInfHohmann IS ABS(vTransfer - vOriginCirc).
    LOCAL rPark IS SHIP:ORBIT:SEMIMAJORAXIS.
    IF rPark <= 0 { SET rPark TO BODY:RADIUS + MAX(0, SHIP:ALTITUDE). }
    LOCAL dvEject IS SQRT(vInfHohmann ^ 2 + 2 * BODY:MU / rPark)
        - SQRT(BODY:MU / rPark).
    RETURN LEXICON(
        "VINF_HOHMANN", vInfHohmann,
        "DV_EJECT", dvEject,
        "VINF_GATE", 1.3 * vInfHohmann,
        "DV_GATE", 1.5 * dvEject
    ).
}

LOCAL FUNCTION _lambertSelectionInfo {
    PARAMETER label.
    PARAMETER departUt.
    PARAMETER arriveUt.
    PARAMETER flip.
    PARAMETER targetBody.
    PARAMETER transferCenter.
    PARAMETER hohmannTof.
    PARAMETER gates.

    LOCAL originState IS orbitalStateVectors(BODY, departUt, transferCenter).
    LOCAL targetDepartState IS orbitalStateVectors(targetBody, departUt, transferCenter).
    LOCAL targetArriveState IS orbitalStateVectors(targetBody, arriveUt, transferCenter).
    LOCAL result IS lambertSolve(
        originState["p"], targetArriveState["p"],
        arriveUt - departUt, transferCenter:MU, flip).
    LOCAL v1Lambert IS result["v1"].
    LOCAL vOrigin IS originState["v"].
    LOCAL vInfVec IS v1Lambert - vOrigin.
    LOCAL nd IS _lambertEscapeNode(departUt, vInfVec).

    ADD nd.
    WAIT 0.05.
    LOCAL tof IS arriveUt - departUt.
    LOCAL pad IS MAX(21600, tof * 0.12).
    LOCAL ca IS _findClosestApproach(
        targetBody, arriveUt - pad, arriveUt + pad, 36).
    LOCAL patch IS _getTargetPatch(nd, targetBody).
    LOCAL patchPeKm IS -1.
    IF patch <> 0 { SET patchPeKm TO patch:PERIAPSIS / 1000. }
    LOCAL pro IS nd:PROGRADE.
    LOCAL nor IS nd:NORMAL.
    LOCAL rad IS nd:RADIALOUT.
    LOCAL nodeDv IS nd:DELTAV:MAG.
    REMOVE nd.
    WAIT 0.02.

    LOCAL phaseAngle IS VANG(
        originState["p"], targetDepartState["p"]).
    LOCAL tofFrac IS tof / hohmannTof.
    LOCAL vinfOk IS vInfVec:MAG < gates["VINF_GATE"].
    LOCAL dvOk IS nodeDv > TRANSFER_LAMBERT_MIN_NODE_DV.
    LOCAL dvMaxOk IS nodeDv < gates["DV_GATE"].
    LOCAL caOk IS ca["distance"] < targetBody:SOIRADIUS.
    LOCAL frameOk IS transferCenter = targetBody:BODY.
    LOCAL sanityOk IS vinfOk AND dvOk AND dvMaxOk AND caOk AND frameOk.
    LOCAL reason IS "PASS".
    IF NOT frameOk { SET reason TO "frame-not-target-parent". }
    IF frameOk AND NOT vinfOk { SET reason TO "vinf-high". }
    IF frameOk AND vinfOk AND NOT dvOk { SET reason TO "dv-zero". }
    IF frameOk AND vinfOk AND dvOk AND NOT dvMaxOk { SET reason TO "dv-high". }
    IF frameOk AND vinfOk AND dvOk AND dvMaxOk AND NOT caOk { SET reason TO "ca-outside-soi". }

    RETURN LEXICON(
        "LABEL", label,
        "DEPART_UT", departUt,
        "ARRIVE_UT", arriveUt,
        "TOF", tof,
        "TOF_FRAC", tofFrac,
        "PHASE_ANGLE", phaseAngle,
        "V1_MAG", v1Lambert:MAG,
        "VORIGIN_MAG", vOrigin:MAG,
        "VINF_MAG", vInfVec:MAG,
        "PROGRADE", pro,
        "NORMAL", nor,
        "RADIALOUT", rad,
        "NODE_DV", nodeDv,
        "CA_KM", ca["distance"] / 1000,
        "CA_UT", ca["time"],
        "PATCH", patch <> 0,
        "PATCH_PE_KM", patchPeKm,
        "FLIP", flip,
        "FRAME_OK", frameOk,
        "DV_OK", dvOk,
        "DV_MAX_OK", dvMaxOk,
        "CA_OK", caOk,
        "CENTER", transferCenter:NAME,
        "VINF_HOHMANN", gates["VINF_HOHMANN"],
        "DV_EJECT", gates["DV_EJECT"],
        "VINF_GATE", gates["VINF_GATE"],
        "DV_GATE", gates["DV_GATE"],
        "SANITY_OK", sanityOk,
        "SANITY_REASON", reason
    ).
}

LOCAL FUNCTION _lambertLogSelection {
    PARAMETER info.
    PARAMETER targetBody.
    PARAMETER transferCenter.

    LOCAL verdict IS "FAIL".
    IF info["SANITY_OK"] { SET verdict TO "PASS". }
    mLogWarn("STATS lambert-selection label=" + info["LABEL"]
        + " target=" + targetBody:NAME
        + " center=" + transferCenter:NAME
        + " departUT=" + ROUND(info["DEPART_UT"],1)
        + " arriveUT=" + ROUND(info["ARRIVE_UT"],1)
        + " phaseDeg=" + ROUND(info["PHASE_ANGLE"],2)
        + " tof=" + ROUND(info["TOF"],0)
        + " tofHohmannFrac=" + ROUND(info["TOF_FRAC"],3)).
    mLogWarn("STATS lambert-vectors label=" + info["LABEL"]
        + " v1Helio=" + ROUND(info["V1_MAG"],1)
        + " vSunDepart=" + ROUND(info["VORIGIN_MAG"],1)
        + " vInf=" + ROUND(info["VINF_MAG"],1)).
    mLogWarn("STATS lambert-node label=" + info["LABEL"]
        + " prograde=" + ROUND(info["PROGRADE"],1)
        + " normal=" + ROUND(info["NORMAL"],1)
        + " radial=" + ROUND(info["RADIALOUT"],1)
        + " dv=" + ROUND(info["NODE_DV"],1)
        + " caKm=" + ROUND(info["CA_KM"],1)
        + " caUT=" + ROUND(info["CA_UT"],1)
        + " patch=" + info["PATCH"]
        + " patchPeKm=" + ROUND(info["PATCH_PE_KM"],1)).
    mLogWarn("STATS lambert-sanity label=" + info["LABEL"]
        + " verdict=" + verdict
        + " reason=" + info["SANITY_REASON"]
        + " center=" + info["CENTER"]
        + " vInfHohmann=" + ROUND(info["VINF_HOHMANN"],1)
        + " dvEject=" + ROUND(info["DV_EJECT"],1)
        + " vinfGate=" + ROUND(info["VINF_GATE"],1)
        + " vinf=" + ROUND(info["VINF_MAG"],1)
        + " minDv=" + ROUND(TRANSFER_LAMBERT_MIN_NODE_DV,1)
        + " dvGate=" + ROUND(info["DV_GATE"],1)
        + " dvOk=" + info["DV_OK"]
        + " dvMaxOk=" + info["DV_MAX_OK"]
        + " caOk=" + info["CA_OK"]
        + " flip=" + info["FLIP"]).
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

    LOCAL state IS _localOrbitState(nd:TIME).
    LOCAL localR IS state["r"].
    LOCAL localVel IS state["v"].
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
    LOCAL patchOk IS FALSE.
    LOCAL patchPe IS -1.
    LOCAL ca IS LEXICON("distance", 9e15, "time", arriveUt).
    LOCAL score IS 9e15.
    IF patch <> 0 {
        SET patchPe TO patch:PERIAPSIS.
        IF patchPe > 0 AND patchPe < targetBody:SOIRADIUS {
            SET patchOk TO TRUE.
            SET ca TO LEXICON("distance", patchPe, "time", arriveUt).
            SET score TO -1e9 + patchPe.
        }
    }
    IF NOT patchOk {
        LOCAL tof IS MAX(3600, arriveUt - nd:TIME).
        LOCAL pad IS MAX(21600, tof * 0.12).
        SET ca TO _findClosestApproach(
            targetBody, arriveUt - pad, arriveUt + pad, 36).
        SET score TO ca["distance"].
    }
    LOCAL safeDeparture IS _lambertDepartureSafe(nd).
    IF NOT safeDeparture {
        SET score TO score + 9e15.
    }
    RETURN LEXICON(
        "SCORE", score,
        "CA", ca,
        "PATCH", patch,
        "PATCH_OK", patchOk,
        "PATCH_PE", patchPe,
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
    IF best["PATCH_OK"] { RETURN best["PATCH"]. }

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
    LOCAL maxIter IS MAX(18, TRANSFER_LAMBERT_REFINE_MAX_ITER).
    LOCAL stallLimit IS MAX(1, TRANSFER_LAMBERT_REFINE_STALL_LIMIT).
    LOCAL stalls IS 0.
    LOCAL iterRan IS 0.

    FROM { LOCAL iter IS 0. } UNTIL iter >= maxIter STEP { SET iter TO iter + 1. } DO {
        SET iterRan TO iter + 1.
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
                        IF trial["SAFE"] AND trial["PATCH_OK"] {
                            mLog("  Lambert seed[" + iter + "] "
                                + axis + "=" + ROUND(trialVal,2)
                                + " patch acquired Pe="
                                + ROUND(trial["PATCH_PE"]/1000,1)
                                + "km dV=" + ROUND(nd:DELTAV:MAG,1)).
                            RETURN trial["PATCH"].
                        }
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
            LOCAL prevCaKm IS best["CA"]["distance"] / 1000.
            _nodeAxisSet(nd, bestAxis, bestValue).
            WAIT 0.02.
            SET best TO _lambertPatchEval(nd, targetBody, arriveUt).
            LOCAL newCaKm IS best["CA"]["distance"] / 1000.
            mLog("  Lambert seed[" + iter + "] " + bestAxis + "="
                + ROUND(bestValue,2)
                + " CA " + ROUND(prevCaKm,1)
                + "->" + ROUND(newCaKm,1)
                + "km patch=" + (best["PATCH"] <> 0)
                + " safe=" + best["SAFE"]
                + " dV=" + ROUND(nd:DELTAV:MAG,1)).
            IF best["PATCH_OK"] {
                RETURN best["PATCH"].
            }
            IF prevCaKm - newCaKm < 1 {
                SET stalls TO stalls + 1.
            } ELSE {
                SET stalls TO 0.
            }
            IF stalls >= stallLimit {
                mLogWarn("Lambert patch refine: progress stalled after "
                    + iterRan + " iterations.").
                BREAK.
            }
        } ELSE {
            FOR axis IN axes {
                SET steps[axis] TO steps[axis] / 2.
            }
            SET stalls TO stalls + 1.
            LOCAL small IS TRUE.
            FOR axis IN axes {
                IF steps[axis] >= mins[axis] { SET small TO FALSE. }
            }
            IF stalls >= stallLimit {
                mLogWarn("Lambert patch refine: no improving axis for "
                    + stalls + " passes; stopping.").
                BREAK.
            }
            IF small { BREAK. }
        }
    }

    mLogWarn("STATS lambert-patch-refine target=" + targetBody:NAME
        + " finalCaKm=" + ROUND(best["CA"]["distance"]/1000,1)
        + " patch=" + (best["PATCH"] <> 0)
        + " patchOk=" + best["PATCH_OK"]
        + " iterations=" + iterRan
        + " maxIter=" + maxIter
        + " dv=" + ROUND(nd:DELTAV:MAG,1)).
    IF best["PATCH_OK"] { RETURN best["PATCH"]. }
    RETURN 0.
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

    LOCAL state IS _localOrbitState(burnUt).
    LOCAL localR IS state["r"].
    LOCAL localVel IS state["v"].
    LOCAL rHat IS state["rh"].
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
    LOCAL state IS _localOrbitState(burnUt).
    LOCAL localR IS state["r"].
    LOCAL localVel IS state["v"].
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
    LOCAL state IS _localOrbitState(nd:TIME).
    LOCAL localR IS state["r"].
    LOCAL localVel IS state["v"].
    LOCAL progradeHat IS localVel:NORMALIZED.
    LOCAL normalHat IS VCRS(localR:NORMALIZED, progradeHat):NORMALIZED.
    LOCAL radialHat IS VCRS(progradeHat, normalHat):NORMALIZED.

    RETURN nd:PROGRADE * progradeHat
        + nd:NORMAL * normalHat
        + nd:RADIALOUT * radialHat.
}

LOCAL FUNCTION _localOrbitVelocityVector {
    PARAMETER t.

    LOCAL state IS _localOrbitState(t).
    RETURN state["v"].
}

LOCAL FUNCTION _localOrbitState {
    PARAMETER t.

    LOCAL r0 IS SHIP:POSITION - BODY:POSITION.
    LOCAL v0 IS SHIP:VELOCITY:ORBIT.
    IF v0:MAG < 1e-6 {
        SET v0 TO VELOCITYAT(SHIP, TIME:SECONDS):ORBIT.
    }

    LOCAL hHat IS VCRS(r0, v0).
    IF hHat:MAG < 1e-6 {
        SET hHat TO BODY:ANGULARVEL.
    }
    SET hHat TO hHat:NORMALIZED.

    LOCAL phase IS 0.
    IF SHIP:ORBIT:PERIOD > 0 {
        SET phase TO 360 * (t - TIME:SECONDS) / SHIP:ORBIT:PERIOD.
        UNTIL phase >= 0 { SET phase TO phase + 360. }
        UNTIL phase < 360 { SET phase TO phase - 360. }
    }

    LOCAL sma IS SHIP:ORBIT:SEMIMAJORAXIS.
    IF sma <= 0 { SET sma TO r0:MAG. }
    LOCAL rMag IS sma.
    LOCAL rHat IS (ANGLEAXIS(phase, hHat) * r0):NORMALIZED.
    LOCAL vHat IS VCRS(hHat, rHat):NORMALIZED.
    LOCAL speed2 IS BODY:MU * (2 / rMag
        - 1 / sma).
    LOCAL speed IS SHIP:VELOCITY:ORBIT:MAG.
    IF speed2 > 0 {
        SET speed TO SQRT(speed2).
    }
    RETURN LEXICON(
        "r", rHat * rMag,
        "v", vHat * speed,
        "rh", rHat
    ).
}
