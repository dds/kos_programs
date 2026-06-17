// ============================================================
// maneuver_transfer.ks — raw transfer planning
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL CAPTURE_PE IS -1.
GLOBAL CAPTURE_INC IS -1.
GLOBAL CAPTURE_LAN IS -1.
GLOBAL CAPTURE_AOP IS -1.
GLOBAL CAPTURE_DIR IS "".
GLOBAL ESCAPE_PE IS -1.
GLOBAL ESCAPE_LAN IS -1.
GLOBAL ESCAPE_AOP IS -1.
GLOBAL ESCAPE_KSC_TARGET IS 0.
GLOBAL TRANSFER_SCAN_SAMPLES_PER_ORBIT IS 24.
GLOBAL TRANSFER_SCAN_LOOKAHEAD_HOURS IS 6.
GLOBAL TRANSFER_SCAN_STEP_MINUTES IS 20.
GLOBAL TRANSFER_PREVIEW_SHORTLIST IS 6.
GLOBAL TRANSFER_DEFERRED_INC_ERR_TOL IS 45.


// ============================================================
// planTransfer — plan a transfer burn to targetBody.
//
// Pipeline:
//   1. Build raw node  (_planLocalTransfer or planInterplanetaryTransfer)
//      Local:  closest-approach optimization — Hohmann seed, then scan
//              departure time + prograde dV to minimize distance to target.
//              Smooth POSITIONAT objective, no binary encounter search.
//      Interplanetary:  Lambert grid scan, full 3-axis node, conic validation
//   2. Arrival pretargeting — target the requested B-plane when
//      a capture inclination is configured, otherwise center-mass.
//
// Global config keys consumed:
//   CAPTURE_DIR  — "PROGRADE" / "POLAR" / "RETROPOLAR" / "RETROGRADE"
//   CAPTURE_INC  — explicit inclination (overrides CAPTURE_DIR)
// ============================================================
GLOBAL FUNCTION planTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER lanTarget IS -1.
    PARAMETER aopTarget IS -1.

    LOCAL centralBody IS BODY.
    LOCAL mu          IS centralBody:MU.

    // AoP is only meaningful when LAN is also specified — together
    // they fully orient the orbit. Without LAN the ascending node
    // is unconstrained, so AoP has no absolute meaning. The departure
    // planner no longer targets these angles, but preserving this setup
    // keeps the raw-node builders' existing inputs stable.
    IF aopTarget >= 0 AND lanTarget < 0 {
        mLog("Ignoring CAPTURE_AOP without CAPTURE_LAN (AoP alone is unconstrained).").
        SET aopTarget TO -1.
    }

    LOCAL isLocal IS (targetBody:BODY = BODY).
    LOCAL isEscape IS (targetBody = BODY:BODY).
    mLogWarn("STATS transfer setup target=" + targetBody:NAME
        + " local=" + isLocal + " escape=" + isEscape
        + " mode=dumb-departure"
        + " targetPeKm=0"
        + " requestedCapturePeKm=" + ROUND(targetPe/1000,1)).

    // Resolve capture orbit direction before seeding the raw transfer
    // so the raw planners can keep their existing scoring inputs. Exact
    // capture geometry belongs to BPLANE/SHAPE, not this departure phase.
    LOCAL captureInc IS -1.
    IF CAPTURE_DIR <> "" {
        LOCAL dir IS CAPTURE_DIR.
        IF dir = "PROGRADE"   { SET captureInc TO 0. }
        IF dir = "POLAR"      { SET captureInc TO 90. }
        IF dir = "RETROPOLAR" { SET captureInc TO 90. }
        IF dir = "RETROGRADE" { SET captureInc TO 180. }
    }
    IF CAPTURE_INC >= 0 { SET captureInc TO CAPTURE_INC. }

    // --- 1. Build raw node ---
    LOCAL nd IS 0.
    IF isEscape {
        SET nd TO _planEscapeTransfer(targetBody, targetPe, captureInc, lanTarget, aopTarget, centralBody, mu).
    } ELSE IF isLocal {
        SET nd TO _planLocalTransfer(targetBody, targetPe, captureInc, lanTarget, aopTarget, centralBody, mu).
    } ELSE {
        SET nd TO planInterplanetaryTransfer(targetBody, targetPe, captureInc, lanTarget, aopTarget, centralBody, mu).
    }

    IF nd = 0 OR NOT nd:ISTYPE("Node") { RETURN. }

    // --- 2. Arrival pretargeting ---
    // If a capture plane is requested, shape the ejection node directly
    // toward the target B-plane. Otherwise keep the old center-mass
    // targeting to maximize SOI intercept margin.
    LOCAL firstPatch IS _firstPatchBodyName(nd).
    LOCAL firstPatchOk IS firstPatch = "none" OR firstPatch = targetBody:NAME.
    IF firstPatch <> "none" AND BODY:BODY <> 0 AND firstPatch = BODY:BODY:NAME {
        SET firstPatchOk TO TRUE.
    }
    IF firstPatch <> "none" AND targetBody:BODY <> 0 AND firstPatch = targetBody:BODY:NAME {
        SET firstPatchOk TO TRUE.
    }
    IF NOT firstPatchOk {
        mLogError("planTransfer: Node intercepts " + firstPatch
            + " instead of " + targetBody:NAME + ". Transfer blocked.").
        mLogWarn("STATS transfer result target=" + targetBody:NAME
            + " status=blocked-by-obstacle"
            + " obstacle=" + firstPatch
            + " dv=" + ROUND(nd:DELTAV:MAG,1)).
        IF HASNODE { REMOVE nd. }
        RETURN.
    }
    IF captureInc >= 0 {
        _refineEjectionTarget(nd, targetBody, targetPe, captureInc, lanTarget).
    } ELSE IF isEscape {
        newtonTarget(nd, targetBody, "PE", 0).
    } ELSE {
        newtonTarget(nd, targetBody, "PE", 0).
    }

    // --- Final report ---
    LOCAL finalPatch IS _getTargetPatch(nd, targetBody).
    IF finalPatch = 0 {
        mLogError("planTransfer: no direct encounter after arrival targeting.").
        mLogWarn("STATS transfer result target=" + targetBody:NAME
            + " status=no-direct-encounter"
            + " dv=" + ROUND(nd:DELTAV:MAG,1)).
        RETURN.
    }

    LOCAL arrivalEta IS -1.
    LOCAL p IS nd:ORBIT.
    UNTIL NOT p:HASNEXTPATCH {
        LOCAL transitionEta IS p:NEXTPATCHETA.
        SET p TO p:NEXTPATCH.
        IF p:BODY:NAME = targetBody:NAME {
            SET arrivalEta TO transitionEta.
            BREAK.
        }
    }

    mLog("Transfer -> " + targetBody:NAME
        + ": dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s  rawPe=" + ROUND(finalPatch:PERIAPSIS/1000,1) + "km"
        + "  arrivalETA=" + ROUND(arrivalEta,0) + "s").

    LOCAL transferMode IS "dumb-departure".
    IF captureInc >= 0 { SET transferMode TO "targeted-bplane". }
    mLogWarn("STATS transfer result target=" + targetBody:NAME
        + " status=planned"
        + " mode=" + transferMode
        + " dv=" + ROUND(nd:DELTAV:MAG,1)
        + " PeKm=" + ROUND(finalPatch:PERIAPSIS/1000,1)
        + " arrivalEta=" + ROUND(arrivalEta,0)).

    maneuverUiArchiveLog("transfer").
    RETURN nd.
}

LOCAL FUNCTION _refineEjectionTarget {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER captureInc.
    PARAMETER captureLan.

    LOCAL fdStep IS 0.5.
    LOCAL stepCap IS 10.
    LOCAL maxIter IS 8.
    LOCAL tol IS 2000.
    LOCAL converged IS FALSE.

    mLog("Targeted TMI: refining ejection to B-plane Pe="
        + ROUND(targetPe / 1000, 1)
        + "km inc=" + ROUND(captureInc, 1)
        + " lan=" + ROUND(captureLan, 1) + ".").

    FROM { LOCAL i IS 0. } UNTIL i >= maxIter STEP { SET i TO i + 1. } DO {
        LOCAL meas IS measureArrival(nd, targetBody).
        IF meas = 0 {
            mLogWarn("Targeted TMI[" + i + "]: no measurable "
                + targetBody:NAME + " arrival patch.").
            BREAK.
        }

        LOCAL tgt IS targetBplaneVector(
            targetBody, meas, targetPe, captureInc, captureLan, TRUE).
        LOCAL errT IS tgt["bt"] - meas["bt"].
        LOCAL errR IS tgt["br"] - meas["br"].
        LOCAL errMag IS SQRT(errT ^ 2 + errR ^ 2).
        LOCAL qT IS meas["bt"] - tgt["bt"].
        LOCAL qR IS meas["br"] - tgt["br"].

        mLog("  Targeted TMI[" + i + "] dBT="
            + ROUND(errT / 1000, 1)
            + "km dBR=" + ROUND(errR / 1000, 1)
            + "km Pe=" + ROUND(meas["pe"] / 1000, 1)
            + "km inc=" + ROUND(meas["inc"], 1)
            + " dv=" + ROUND(nd:DELTAV:MAG, 1)).

        IF errMag <= tol {
            SET converged TO TRUE.
            BREAK.
        }

        LOCAL r0 IS nd:RADIALOUT.
        LOCAL n0 IS nd:NORMAL.

        SET nd:RADIALOUT TO r0 + fdStep. WAIT 0.02.
        LOCAL mRad IS measureArrival(nd, targetBody).
        SET nd:RADIALOUT TO r0. WAIT 0.02.

        SET nd:NORMAL TO n0 + fdStep. WAIT 0.02.
        LOCAL mNrm IS measureArrival(nd, targetBody).
        SET nd:NORMAL TO n0. WAIT 0.02.

        IF mRad = 0 OR mNrm = 0 {
            mLogWarn("Targeted TMI[" + i + "]: probe lost encounter — stopping.").
            BREAK.
        }

        LOCAL tRad IS targetBplaneVector(
            targetBody, mRad, targetPe, captureInc, captureLan, TRUE).
        LOCAL tNrm IS targetBplaneVector(
            targetBody, mNrm, targetPe, captureInc, captureLan, TRUE).

        LOCAL j11 IS ((mRad["bt"] - tRad["bt"]) - qT) / fdStep.
        LOCAL j21 IS ((mRad["br"] - tRad["br"]) - qR) / fdStep.
        LOCAL j12 IS ((mNrm["bt"] - tNrm["bt"]) - qT) / fdStep.
        LOCAL j22 IS ((mNrm["br"] - tNrm["br"]) - qR) / fdStep.
        LOCAL det IS j11 * j22 - j12 * j21.
        IF ABS(det) < 1e-3 {
            mLogWarn("Targeted TMI[" + i + "]: singular Jacobian det="
                + ROUND(det, 5) + ".").
            BREAK.
        }

        LOCAL dRad IS ( j22 * errT - j12 * errR) / det.
        LOCAL dNrm IS (-j21 * errT + j11 * errR) / det.
        LOCAL stepMag IS SQRT(dRad ^ 2 + dNrm ^ 2).
        IF stepMag > stepCap {
            SET dRad TO dRad * stepCap / stepMag.
            SET dNrm TO dNrm * stepCap / stepMag.
        }

        SET nd:RADIALOUT TO r0 + dRad.
        SET nd:NORMAL TO n0 + dNrm.
        WAIT 0.02.
    }

    LOCAL finalMeas IS measureArrival(nd, targetBody).
    LOCAL finalPe IS -1.
    LOCAL finalInc IS -1.
    IF finalMeas <> 0 {
        SET finalPe TO finalMeas["pe"].
        SET finalInc TO finalMeas["inc"].
    }
    mLogWarn("STATS targeted-tmi target=" + targetBody:NAME
        + " converged=" + converged
        + " dv=" + ROUND(nd:DELTAV:MAG, 1)
        + " PeKm=" + ROUND(finalPe / 1000, 1)
        + " inc=" + ROUND(finalInc, 1)).

    RETURN converged.
}

// ============================================================
// Local transfer (Mun, Minmus) — closest-approach optimization.
//
// Instead of relying on phase angle math (which assumes circular
// coplanar orbits), we use the Hohmann estimate as a seed, then
// optimize departure time and prograde dV to minimize closest
// approach distance to the target body via POSITIONAT. This is
// a smooth, continuous objective — no binary "encounter or not"
// cliff — so the optimizer converges reliably.
//
// Pipeline:
//   1. Hohmann dV + TOF estimate (seed values)
//   2. Coarse scan of departure times (one per orbit, ±N orbits)
//   3. Golden section refine departure time
//   4. Coarse scan of prograde dV (±20% of Hohmann)
//   5. Golden section refine dV
//   6. Optional normal dV scan for inclined target SOI intercepts
// ============================================================
LOCAL FUNCTION _localInterceptEval {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER hohmannTof.
    PARAMETER captureInc IS -1.

    LOCAL ca IS _findClosestApproach(targetBody,
        nd:TIME + hohmannTof * 0.3,
        nd:TIME + hohmannTof * 2.0,
        45).
    LOCAL patch IS _getTargetPatch(nd, targetBody).
    LOCAL score IS ca["distance"] + nd:DELTAV:MAG * 100.
    LOCAL incErr IS 999.
    LOCAL obstacleName IS _firstPatchBodyName(nd).
    IF obstacleName <> "none" AND obstacleName <> targetBody:NAME {
        SET score TO score + 50000000.
    }
    IF patch <> 0 {
        // Any real SOI patch is better than a near miss. BPLANE can
        // move a rough patch; it cannot correct a non-encounter.
        SET score TO score - targetBody:SOIRADIUS * 2.
        IF captureInc >= 0 {
            SET incErr TO ABS(_angleError(patch:INCLINATION, captureInc)).
            IF incErr > TRANSFER_DEFERRED_INC_ERR_TOL {
                SET score TO score
                    + ((incErr - TRANSFER_DEFERRED_INC_ERR_TOL) / 5) ^ 2
                    * 20000.
            }
        }
    }
    RETURN LEXICON(
        "SCORE", score,
        "CA", ca,
        "PATCH", patch <> 0,
        "INC_ERR", incErr,
        "OBSTACLE", obstacleName,
        "DV", nd:DELTAV:MAG
    ).
}

LOCAL FUNCTION _firstPatchBodyName {
    PARAMETER nd.

    LOCAL p IS nd:ORBIT.
    IF p:HASNEXTPATCH {
        SET p TO p:NEXTPATCH.
        RETURN p:BODY:NAME.
    }
    RETURN "none".
}

LOCAL FUNCTION _refineLocalSoiIntercept {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER hohmannTof.
    PARAMETER captureInc IS -1.

    LOCAL best IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
    IF best["PATCH"] AND best["CA"]["distance"] < targetBody:SOIRADIUS * 0.85 {
        RETURN best.
    }

    LOCAL axes IS LIST("PROGRADE", "NORMAL", "RADIALOUT", "TIME").
    LOCAL steps IS LEXICON(
        "PROGRADE", 8.0,
        "NORMAL", 30.0,
        "RADIALOUT", 12.0,
        "TIME", 240.0
    ).
    LOCAL mins IS LEXICON(
        "PROGRADE", 0.25,
        "NORMAL", 0.25,
        "RADIALOUT", 0.25,
        "TIME", 5.0
    ).
    LOCAL signs IS LIST(1, -1).

    LOCAL startCA IS best["CA"]["distance"].
    LOCAL startPatch IS best["PATCH"].
    mLog("SOI intercept refine: start CA=" + ROUND(startCA / 1000, 1)
        + "km patch=" + startPatch
        + " SOI=" + ROUND(targetBody:SOIRADIUS / 1000, 0) + "km").

    FROM { LOCAL iter IS 0. } UNTIL iter >= 32 STEP { SET iter TO iter + 1. } DO {
        LOCAL bestAxis IS "".
        LOCAL bestValue IS 0.
        LOCAL bestTrial IS best.

        FOR axis IN axes {
            LOCAL oldVal IS _nodeAxisGet(nd, axis).
            FOR sgn IN signs {
                LOCAL trialVal IS oldVal + sgn * steps[axis].
                LOCAL timeOk IS TRUE.
                IF axis = "TIME" AND trialVal <= TIME:SECONDS + 30 { SET timeOk TO FALSE. }
                IF timeOk {
                    _nodeAxisSet(nd, axis, trialVal).
                    WAIT 0.02.
                    LOCAL trial IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
                    IF trial["SCORE"] < bestTrial["SCORE"] {
                        SET bestTrial TO trial.
                        SET bestAxis TO axis.
                        SET bestValue TO trialVal.
                    }
                }
            }
            _nodeAxisSet(nd, axis, oldVal).
            WAIT 0.01.
        }

        IF bestAxis <> "" {
            _nodeAxisSet(nd, bestAxis, bestValue).
            WAIT 0.02.
            SET best TO _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
            mLog("  SOI[" + iter + "] " + bestAxis + "="
                + ROUND(bestValue, 2)
                + " CA=" + ROUND(best["CA"]["distance"] / 1000, 1)
                + "km patch=" + best["PATCH"]
                + " dV=" + ROUND(nd:DELTAV:MAG, 1)).
            IF best["PATCH"] AND best["CA"]["distance"] < targetBody:SOIRADIUS * 0.6 {
                BREAK.
            }
        } ELSE {
            FOR axis IN axes {
                SET steps[axis] TO steps[axis] / 2.
            }
            mLog("  SOI[" + iter + "] refining steps: P="
                + ROUND(steps["PROGRADE"], 2)
                + " N=" + ROUND(steps["NORMAL"], 2)
                + " R=" + ROUND(steps["RADIALOUT"], 2)
                + " T=" + ROUND(steps["TIME"], 1)).

            LOCAL small IS TRUE.
            FOR axis IN axes {
                IF steps[axis] >= mins[axis] { SET small TO FALSE. }
            }
            IF small { BREAK. }
        }
    }

    LOCAL final IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
    mLogWarn("STATS soi-refine target=" + targetBody:NAME
        + " startCaKm=" + ROUND(startCA / 1000, 1)
        + " finalCaKm=" + ROUND(final["CA"]["distance"] / 1000, 1)
        + " startPatch=" + startPatch
        + " finalPatch=" + final["PATCH"]
        + " incErr=" + ROUND(final["INC_ERR"], 1)
        + " prograde=" + ROUND(nd:PROGRADE, 1)
        + " normal=" + ROUND(nd:NORMAL, 1)
        + " radial=" + ROUND(nd:RADIALOUT, 1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS, 0)).
    RETURN final.
}

LOCAL FUNCTION _planLocalTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER captureInc.
    PARAMETER lanTarget.
    PARAMETER aopTarget.
    PARAMETER centralBody.
    PARAMETER mu.

    LOCAL shipPeriod IS SHIP:ORBIT:PERIOD.
    LOCAL targetPeriod IS targetBody:ORBIT:PERIOD.

    LOCAL rShip   IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL rTarget IS targetBody:ORBIT:SEMIMAJORAXIS.
    LOCAL seed IS _hohmannSeed(rShip, rTarget, mu, targetPeriod).
    LOCAL hohmannTof IS seed["TOF"].
    LOCAL hohmannDv IS seed["DV"].

    mLog("Local transfer to " + targetBody:NAME
        + ": Hohmann dV=" + ROUND(hohmannDv, 1) + " m/s"
        + "  TOF=" + ROUND(hohmannTof, 0) + "s").

    LOCAL idealPhaseAngle IS seed["IDEAL_PHASE"].

    SET TARGET TO targetBody.
    WAIT 0.1.
    LOCAL currentPhase IS phaseAngle().

    LOCAL phasePlan IS _hohmannPhaseWait(currentPhase, idealPhaseAngle,
        shipPeriod, targetPeriod, 60).
    LOCAL synodicPeriod IS phasePlan["SYNODIC"].
    LOCAL waitTime IS phasePlan["WAIT"].

    LOCAL departUt IS TIME:SECONDS + waitTime.

    mLog("Phase: current=" + ROUND(currentPhase, 1)
        + "  ideal=" + ROUND(idealPhaseAngle, 1)
        + "  diff=" + ROUND(phasePlan["DIFF"], 1)
        + "  wait=" + ROUND(waitTime, 0) + "s").

    LOCAL nd IS NODE(departUt, 0, 0, hohmannDv).
    ADD nd.
    WAIT 0.1.

    LOCAL samplesPerOrbit IS MAX(4, TRANSFER_SCAN_SAMPLES_PER_ORBIT).
    LOCAL scanHours IS MAX(0.25, TRANSFER_SCAN_LOOKAHEAD_HOURS).
    LOCAL maxScanStep IS MAX(60, TRANSFER_SCAN_STEP_MINUTES * 60).
    LOCAL scanStart IS TIME:SECONDS + 30.
    LOCAL scanEnd IS TIME:SECONDS + scanHours * 3600.
    LOCAL scanDt IS MIN(shipPeriod / samplesPerOrbit, maxScanStep).
    SET scanDt TO MAX(30, scanDt).
    LOCAL scanSteps IS MAX(1, CEILING((scanEnd - scanStart) / scanDt)).

    LOCAL bestTime IS MAX(scanStart, MIN(scanEnd, departUt)).
    SET nd:TIME TO bestTime.
    WAIT 0.1.
    LOCAL bestEval IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
    LOCAL bestCA IS bestEval["CA"].
    LOCAL bestSeed IS bestEval.
    LOCAL encounterCount IS 0.
    IF bestSeed["PATCH"] { SET encounterCount TO 1. }
    LOCAL previewShortlist IS MAX(1, TRANSFER_PREVIEW_SHORTLIST).
    LOCAL scanTimes IS LIST().
    LOCAL scanCAs IS LIST().
    LOCAL scanSeeds IS LIST().
    FROM { LOCAL siInit IS 0. } UNTIL siInit >= previewShortlist STEP { SET siInit TO siInit + 1. } DO {
        scanTimes:ADD(0).
        scanCAs:ADD(0).
        scanSeeds:ADD(LEXICON("SCORE", 999999999)).
    }
    SET scanTimes[0] TO bestTime.
    SET scanCAs[0] TO bestCA.
    SET scanSeeds[0] TO bestSeed.

    mLog("Raw transfer scan: " + scanSteps
        + " steps over next " + ROUND(scanHours, 2) + "h"
        + "  step=" + ROUND(scanDt, 0) + "s"
        + "  phaseSeed T+" + ROUND(departUt - TIME:SECONDS, 0) + "s"
        + "  samples/orbit=" + samplesPerOrbit).

    FROM { LOCAL si IS 0. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTime IS scanStart + si * scanDt.
        IF tryTime <= scanEnd {
            SET nd:TIME TO tryTime.
            WAIT 0.02.
            LOCAL tryEval IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
            LOCAL tryCa IS tryEval["CA"].
            LOCAL trySeed IS tryEval.
            LOCAL insertAt IS -1.
            FROM { LOCAL ti IS 0. } UNTIL ti >= previewShortlist STEP { SET ti TO ti + 1. } DO {
                IF insertAt < 0 AND trySeed["SCORE"] < scanSeeds[ti]["SCORE"] {
                    SET insertAt TO ti.
                }
            }
            IF insertAt >= 0 {
                FROM { LOCAL tj IS previewShortlist - 1. } UNTIL tj <= insertAt STEP { SET tj TO tj - 1. } DO {
                    SET scanTimes[tj] TO scanTimes[tj - 1].
                    SET scanCAs[tj] TO scanCAs[tj - 1].
                    SET scanSeeds[tj] TO scanSeeds[tj - 1].
                }
                SET scanTimes[insertAt] TO tryTime.
                SET scanCAs[insertAt] TO tryCa.
                SET scanSeeds[insertAt] TO trySeed.
            }
            IF trySeed["SCORE"] < bestSeed["SCORE"] {
                SET bestCA TO tryCa.
                SET bestSeed TO trySeed.
                SET bestTime TO tryTime.
            }
            IF trySeed["PATCH"] {
                SET encounterCount TO encounterCount + 1.
                IF encounterCount >= 6
                        AND (captureInc < 0
                            OR bestSeed["INC_ERR"] <= TRANSFER_DEFERRED_INC_ERR_TOL) {
                    mLog("Raw transfer scan: found " + encounterCount
                        + " target encounters; ending scan early.").
                    BREAK.
                }
            }
        }
    }
    SET nd:TIME TO bestTime.
    WAIT 0.1.
    mLog("Time scan: best CA=" + ROUND(bestCA["distance"]/1000, 1) + "km"
        + " score=" + ROUND(bestSeed["SCORE"], 2)
        + " encounters=" + encounterCount
        + " at T+" + ROUND(bestCA["time"] - TIME:SECONDS, 0) + "s"
        + "  depart T+" + ROUND(bestTime - TIME:SECONDS, 0) + "s").
    _logLocalTransferShortlist(scanTimes, scanCAs, scanSeeds, previewShortlist).

    // --- Golden section refine departure time + dV ---
    LOCAL tA IS MAX(scanStart, bestTime - scanDt).
    LOCAL tB IS MIN(scanEnd, bestTime + scanDt).
    LOCAL gr IS (SQRT(5) + 1) / 2.

    FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
        LOCAL tC IS tB - (tB - tA) / gr.
        LOCAL tD IS tA + (tB - tA) / gr.

        SET nd:TIME TO tC. WAIT 0.02.
        LOCAL seedC IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
        SET nd:TIME TO tD. WAIT 0.02.
        LOCAL seedD IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).

        IF seedC["SCORE"] < seedD["SCORE"] {
            SET tB TO tD.
        } ELSE {
            SET tA TO tC.
        }
    }
    SET nd:TIME TO (tA + tB) / 2.
    WAIT 0.1.

    LOCAL dvRange IS MAX(10, ABS(hohmannDv) * 0.2).
    LOCAL dvSteps IS 20.
    LOCAL dvStep IS dvRange * 2 / dvSteps.
    LOCAL bestDv IS hohmannDv.
    SET bestEval TO _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
    SET bestCA TO bestEval["CA"].
    SET bestSeed TO bestEval.

    FROM { LOCAL di IS 0. } UNTIL di > dvSteps STEP { SET di TO di + 1. } DO {
        LOCAL tryDv IS hohmannDv - dvRange + di * dvStep.
        SET nd:PROGRADE TO tryDv.
        WAIT 0.02.
        LOCAL trySeed IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
        LOCAL tryCa IS trySeed["CA"].
        IF trySeed["SCORE"] < bestSeed["SCORE"] {
            SET bestCA TO tryCa.
            SET bestSeed TO trySeed.
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
        LOCAL seedC IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
        SET nd:PROGRADE TO dvD. WAIT 0.02.
        LOCAL seedD IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).

        IF seedC["SCORE"] < seedD["SCORE"] {
            SET dvB TO dvD.
        } ELSE {
            SET dvA TO dvC.
        }
    }
    SET nd:PROGRADE TO (dvA + dvB) / 2.
    WAIT 0.1.

    LOCAL gateCA IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
    IF gateCA["distance"] > targetBody:SOIRADIUS * 0.7 {
        LOCAL vInj IS SQRT(mu / rShip) + ABS(nd:PROGRADE).
        LOCAL relIncEst IS ABS(targetBody:ORBIT:INCLINATION) + ABS(SHIP:ORBIT:INCLINATION).
        LOCAL nrmRange IS MAX(50, 2 * vInj * SIN(relIncEst / 2)).
        LOCAL nrmSteps IS 20.
        LOCAL nrmStep IS nrmRange * 2 / nrmSteps.
        LOCAL bestNrm IS nd:NORMAL.
        LOCAL nrmGoodEnough IS FALSE.
        SET bestCA TO gateCA.
        SET bestEval TO _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
        SET bestSeed TO bestEval.

        FROM { LOCAL ni IS 0. } UNTIL ni > nrmSteps STEP { SET ni TO ni + 1. } DO {
            LOCAL tryNrm IS bestNrm - nrmRange + ni * nrmStep.
            SET nd:NORMAL TO tryNrm.
            WAIT 0.02.
            LOCAL trySeed IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
            LOCAL tryCa IS trySeed["CA"].
            IF trySeed["SCORE"] < bestSeed["SCORE"] {
                SET bestCA TO tryCa.
                SET bestSeed TO trySeed.
                SET bestNrm TO tryNrm.
            }
            IF tryCa["distance"] < targetBody:SOIRADIUS * 0.7 {
                SET bestCA TO tryCa.
                SET bestSeed TO trySeed.
                SET bestNrm TO tryNrm.
                SET nrmGoodEnough TO TRUE.
                BREAK.
            }
        }
        SET nd:NORMAL TO bestNrm.
        WAIT 0.1.

        IF NOT nrmGoodEnough {
            LOCAL nrmA IS bestNrm - nrmStep.
            LOCAL nrmB IS bestNrm + nrmStep.
            FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
                LOCAL nrmC IS nrmB - (nrmB - nrmA) / gr.
                LOCAL nrmD IS nrmA + (nrmB - nrmA) / gr.

                SET nd:NORMAL TO nrmC. WAIT 0.02.
                LOCAL seedC IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
                SET nd:NORMAL TO nrmD. WAIT 0.02.
                LOCAL seedD IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).

                IF seedC["SCORE"] < seedD["SCORE"] {
                    SET nrmB TO nrmD.
                } ELSE {
                    SET nrmA TO nrmC.
                }
            }
            SET nd:NORMAL TO (nrmA + nrmB) / 2.
            WAIT 0.1.
        }

        LOCAL postNrmCA IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
        mLog("Normal scan: CA " + ROUND(gateCA["distance"]/1000, 1) + "km -> "
            + ROUND(postNrmCA["distance"]/1000, 1) + "km"
            + "  normal=" + ROUND(nd:NORMAL, 1) + " m/s"
            + "  prograde=" + ROUND(nd:PROGRADE, 1)
            + "  goodEnough=" + nrmGoodEnough
            + "  (range +-" + ROUND(nrmRange, 0)
            + ", SOI=" + ROUND(targetBody:SOIRADIUS/1000, 0) + "km)").
    }

    LOCAL interceptCheck IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
    IF (NOT interceptCheck["PATCH"]) OR interceptCheck["CA"]["distance"] > targetBody:SOIRADIUS * 0.85 {
        SET interceptCheck TO _refineLocalSoiIntercept(nd, targetBody, hohmannTof, captureInc).
    }

    LOCAL finalSeed IS _localInterceptEval(nd, targetBody, hohmannTof, captureInc).
    LOCAL finalCA IS finalSeed["CA"].
    mLog("Optimized: CA=" + ROUND(finalCA["distance"]/1000, 1) + "km"
        + " score=" + ROUND(finalSeed["SCORE"], 2)
        + "  dV=" + ROUND(nd:DELTAV:MAG, 1) + " m/s"
        + "  depart T+" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    mLogWarn("STATS local-transfer target=" + targetBody:NAME
        + " caKm=" + ROUND(finalCA["distance"]/1000,1)
        + " score=" + ROUND(finalSeed["SCORE"],2)
        + " patch=" + finalSeed["PATCH"]
        + " incErr=" + ROUND(finalSeed["INC_ERR"],1)
        + " firstPatch=" + _firstPatchBodyName(nd)
        + " obstacle=" + finalSeed["OBSTACLE"]
        + " prograde=" + ROUND(nd:PROGRADE,1)
        + " normal=" + ROUND(nd:NORMAL,1)
        + " radial=" + ROUND(nd:RADIALOUT,1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).

    RETURN nd.
}

LOCAL FUNCTION _logLocalTransferShortlist {
    PARAMETER scanTimes.
    PARAMETER scanCAs.
    PARAMETER scanSeeds.
    PARAMETER count.

    LOCAL shown IS 0.
    FROM { LOCAL qi IS 0. } UNTIL qi >= count STEP { SET qi TO qi + 1. } DO {
        IF scanSeeds[qi]["SCORE"] < 999999999 {
            SET shown TO shown + 1.
            LOCAL ca IS scanCAs[qi].
            LOCAL seed IS scanSeeds[qi].
            mLogWarn("STATS local-candidate rank=" + shown
                + " departT=" + ROUND(scanTimes[qi] - TIME:SECONDS, 0)
                + " caKm=" + ROUND(ca["distance"] / 1000, 1)
                + " closestT=" + ROUND(ca["time"] - TIME:SECONDS, 0)
                + " score=" + ROUND(seed["SCORE"], 2)
                + " patch=" + seed["PATCH"]
                + " incErr=" + ROUND(seed["INC_ERR"], 1)
                + " obstacle=" + seed["OBSTACLE"]
                + " dv=" + ROUND(seed["DV"], 1)).
        }
    }
}

// Estimate KSC longitude penalty for a candidate escape node.
// Uses the Kerbin patch's orbital elements + Kerbin rotation to
// estimate surface longitude of periapsis. Returns a penalty
// score term (0 = perfect alignment).
LOCAL FUNCTION _escapeKscPenalty {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER departTime.
    PARAMETER transitA.
    PARAMETER muParent.
    PARAMETER kscLng.

    LOCAL patch IS _getTargetPatch(nd, targetBody).
    IF patch = 0 { RETURN 0. }

    LOCAL peLngInertial IS patch:LAN + patch:ARGUMENTOFPERIAPSIS.
    LOCAL transitTime IS CONSTANT:PI * SQRT(transitA^3 / muParent).
    LOCAL arrivalUt IS departTime + transitTime.
    LOCAL kerbinRotDeg IS (arrivalUt / targetBody:ROTATIONPERIOD) * 360.
    LOCAL peLngSurface IS MOD(peLngInertial - kerbinRotDeg, 360).
    IF peLngSurface > 180 { SET peLngSurface TO peLngSurface - 360. }
    IF peLngSurface < -180 { SET peLngSurface TO peLngSurface + 360. }
    LOCAL lngErr IS ABS(peLngSurface - kscLng).
    IF lngErr > 180 { SET lngErr TO 360 - lngErr. }
    RETURN (lngErr / 10)^2.
}

// ============================================================
// Escape transfer (Mun/Minmus -> Kerbin) — two-level vis-viva seed
// with departure scan, optional KSC longitude scoring.
//
// Pipeline:
//   1. Two-level vis-viva seed for escape dV
//   2. Departure time scan (one ship orbital period, KSC scoring)
//   3. Golden section refine departure time
//   4. dV scan ±20%
//   5. Golden section refine dV
// ============================================================
LOCAL FUNCTION _planEscapeTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER captureInc.
    PARAMETER lanTarget.
    PARAMETER aopTarget.
    PARAMETER centralBody.
    PARAMETER mu.

    LOCAL shipPeriod IS SHIP:ORBIT:PERIOD.
    LOCAL muParent IS targetBody:MU.
    LOCAL muMoon IS mu.

    // --- Two-level vis-viva seed ---
    // Outer level (parent frame): velocity at moon's orbit for desired PE
    LOCAL rMoon IS BODY:ORBIT:SEMIMAJORAXIS.
    LOCAL vMoon IS SQRT(muParent / rMoon).
    LOCAL rTarget IS targetBody:RADIUS + targetPe.
    LOCAL aTransfer IS (rMoon + rTarget) / 2.
    LOCAL vNeeded IS SQRT(muParent * (2/rMoon - 1/aTransfer)).
    LOCAL vInf IS ABS(vMoon - vNeeded).

    // Inner level (moon frame): prograde burn at periapsis
    LOCAL rShipPe IS BODY:RADIUS + SHIP:PERIAPSIS.
    LOCAL aShip IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL vEscape IS SQRT(2 * muMoon / rShipPe).
    LOCAL vBurn IS SQRT(vInf^2 + vEscape^2).
    LOCAL vAtPe IS SQRT(muMoon * (2/rShipPe - 1/aShip)).
    LOCAL escapeDv IS vBurn - vAtPe.

    mLog("Escape transfer to " + targetBody:NAME
        + ": vis-viva dV=" + ROUND(escapeDv, 1) + " m/s"
        + "  vInf=" + ROUND(vInf, 1) + " m/s"
        + "  shipPe=" + ROUND(SHIP:PERIAPSIS/1000, 1) + "km").

    // --- Place initial node at next periapsis ---
    LOCAL departUt IS TIME:SECONDS + ETA:PERIAPSIS.
    IF departUt < TIME:SECONDS + 30 { SET departUt TO departUt + shipPeriod. }
    LOCAL nd IS NODE(departUt, 0, 0, escapeDv).
    ADD nd.
    WAIT 0.1.

    // --- KSC targeting setup ---
    LOCAL kscTarget IS ESCAPE_KSC_TARGET <> 0.
    LOCAL KSC_LNG IS -74.6.
    LOCAL kscTransitA IS (rMoon + targetBody:RADIUS + targetPe) / 2.

    // --- Departure time scan ---
    // Scan future departure times to find best ejection angle.
    // If KSC targeting, scan enough forward orbits for Kerbin to
    // rotate once. The old ± scan spent about half its nominal
    // range in the past and could miss the actual return window.
    LOCAL nScanOrbits IS 1.
    IF kscTarget {
        SET nScanOrbits TO MAX(6, CEILING(targetBody:ROTATIONPERIOD / shipPeriod)).
    }
    SET nScanOrbits TO MAX(nScanOrbits, 1).

    LOCAL samplesPerOrbit IS 12.
    LOCAL scanSteps IS nScanOrbits * samplesPerOrbit.
    LOCAL scanDt IS shipPeriod / samplesPerOrbit.
    LOCAL scanStart IS departUt.
    LOCAL scanEnd IS departUt + nScanOrbits * shipPeriod.

    LOCAL bestTime IS departUt.
    LOCAL bestScore IS 999999999.

    mLog("Escape departure scan: " + (scanSteps + 1) + " steps"
        + " over next " + nScanOrbits + " orbits"
        + "  KSC=" + kscTarget).

    FROM { LOCAL si IS 0. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTime IS departUt + si * scanDt.
        IF tryTime > TIME:SECONDS + 30 {
            SET nd:TIME TO tryTime.
            WAIT 0.02.
            LOCAL trySeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).
            LOCAL score IS trySeed["SCORE"].

            // KSC longitude scoring
            IF kscTarget AND trySeed["PATCH"] {
                SET score TO score + _escapeKscPenalty(nd, targetBody, tryTime, kscTransitA, muParent, KSC_LNG).
            }

            IF score < bestScore {
                SET bestScore TO score.
                SET bestTime TO tryTime.
            }
        }
    }

    SET nd:TIME TO bestTime.
    WAIT 0.1.

    mLog("Time scan: best score=" + ROUND(bestScore, 2)
        + "  depart T+" + ROUND(bestTime - TIME:SECONDS, 0) + "s").

    // --- Golden section refine departure time ---
    LOCAL tA IS MAX(scanStart, bestTime - scanDt).
    LOCAL tB IS MIN(scanEnd, bestTime + scanDt).
    LOCAL gr IS (SQRT(5) + 1) / 2.

    FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
        LOCAL tC IS tB - (tB - tA) / gr.
        LOCAL tD IS tA + (tB - tA) / gr.

        SET nd:TIME TO tC. WAIT 0.02.
        LOCAL seedC IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).
        LOCAL scoreC IS seedC["SCORE"].
        IF kscTarget AND seedC["PATCH"] {
            SET scoreC TO scoreC + _escapeKscPenalty(nd, targetBody, tC, kscTransitA, muParent, KSC_LNG).
        }

        SET nd:TIME TO tD. WAIT 0.02.
        LOCAL seedD IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).
        LOCAL scoreD IS seedD["SCORE"].
        IF kscTarget AND seedD["PATCH"] {
            SET scoreD TO scoreD + _escapeKscPenalty(nd, targetBody, tD, kscTransitA, muParent, KSC_LNG).
        }

        IF scoreC < scoreD {
            SET tB TO tD.
        } ELSE {
            SET tA TO tC.
        }
    }
    SET nd:TIME TO (tA + tB) / 2.
    WAIT 0.1.

    // --- dV scan ±20% ---
    LOCAL dvRange IS MAX(10, ABS(escapeDv) * 0.2).
    LOCAL dvSteps IS 20.
    LOCAL dvStep IS dvRange * 2 / dvSteps.
    LOCAL bestDv IS escapeDv.
    LOCAL bestDvSeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).
    LOCAL bestDvScore IS bestDvSeed["SCORE"].
    IF kscTarget AND bestDvSeed["PATCH"] {
        SET bestDvScore TO bestDvScore + _escapeKscPenalty(nd, targetBody, nd:TIME, kscTransitA, muParent, KSC_LNG).
    }

    FROM { LOCAL di IS 0. } UNTIL di > dvSteps STEP { SET di TO di + 1. } DO {
        LOCAL tryDv IS escapeDv - dvRange + di * dvStep.
        SET nd:PROGRADE TO tryDv.
        WAIT 0.02.
        LOCAL trySeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).
        LOCAL tryScore IS trySeed["SCORE"].
        IF kscTarget AND trySeed["PATCH"] {
            SET tryScore TO tryScore + _escapeKscPenalty(nd, targetBody, nd:TIME, kscTransitA, muParent, KSC_LNG).
        }
        IF tryScore < bestDvScore {
            SET bestDvScore TO tryScore.
            SET bestDv TO tryDv.
        }
    }
    SET nd:PROGRADE TO bestDv.
    WAIT 0.1.

    // Golden section refine dV
    LOCAL dvA IS MAX(bestDv - dvStep, escapeDv - dvRange).
    LOCAL dvB IS MIN(bestDv + dvStep, escapeDv + dvRange).

    FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
        LOCAL dvC IS dvB - (dvB - dvA) / gr.
        LOCAL dvD IS dvA + (dvB - dvA) / gr.

        SET nd:PROGRADE TO dvC. WAIT 0.02.
        LOCAL seedC IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).
        LOCAL scoreC IS seedC["SCORE"].
        IF kscTarget AND seedC["PATCH"] {
            SET scoreC TO scoreC + _escapeKscPenalty(nd, targetBody, nd:TIME, kscTransitA, muParent, KSC_LNG).
        }
        SET nd:PROGRADE TO dvD. WAIT 0.02.
        LOCAL seedD IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).
        LOCAL scoreD IS seedD["SCORE"].
        IF kscTarget AND seedD["PATCH"] {
            SET scoreD TO scoreD + _escapeKscPenalty(nd, targetBody, nd:TIME, kscTransitA, muParent, KSC_LNG).
        }

        IF scoreC < scoreD {
            SET dvB TO dvD.
        } ELSE {
            SET dvA TO dvC.
        }
    }
    SET nd:PROGRADE TO (dvA + dvB) / 2.
    WAIT 0.1.

    LOCAL finalSeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).
    mLog("Escape optimized: dV=" + ROUND(nd:PROGRADE, 1) + " m/s"
        + " score=" + ROUND(finalSeed["SCORE"], 2)
        + " patch=" + finalSeed["PATCH"]
        + " depart T+" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    mLogWarn("STATS escape-transfer target=" + targetBody:NAME
        + " dv=" + ROUND(nd:PROGRADE,1)
        + " score=" + ROUND(finalSeed["SCORE"],2)
        + " patch=" + finalSeed["PATCH"]
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).

    RETURN nd.
}
