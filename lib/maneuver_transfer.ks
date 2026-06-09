// ============================================================
// maneuver_transfer.ks — transfer planning and mid-course correction
// ============================================================

@LAZYGLOBAL OFF.

LOCAL MCC_DV_CAP           IS 50.
LOCAL MCC_MIN_DV           IS 2.0.
LOCAL MCC_LATE_MIN_DV      IS 3.0.
LOCAL MCC_LATE_ETA         IS 7200.
LOCAL MAX_RETRIES          IS 5.

// ============================================================
// planTransfer — plan a transfer burn to targetBody.
//
// Pipeline:
//   1. Build raw node  (_planLocalTransfer or planInterplanetaryTransfer)
//      Local:  closest-approach optimization — Hohmann seed, then scan
//              departure time + prograde dV to minimize distance to target.
//              Smooth POSITIONAT objective, no binary encounter search.
//      Interplanetary:  Lambert grid scan, full 3-axis node, conic validation
//   2. Element-aware seed scoring — prefer departure windows that
//      already produce the requested PE/INC/LAN/AoP geometry.
//   3. PE pretargeting (prograde) — unconstrained transfers first
//      converge PE to zero for encounter margin. AoP-guided transfers
//      target the requested capture Pe instead, preserving the selected
//      apsidal branch while keeping the coupled solver near its target.
//   4. Coupled PE/INC targeting — solve periapsis and capture plane
//      together. PE and INC are tightly coupled on local moon transfers,
//      so a scalar Newton pass can report false "low sensitivity" while
//      a larger normal/radial/prograde coordinate search still converges.
//   5. Angular gate — LAN is hard-solved when requested; AoP is only
//      accepted/rejected here because it is best selected by departure
//      timing and refined later by MCC/ELLIPTICAL.
//
// MCC (phaseMidCourse) fires mid-coast to fine-tune any drift
// from burn execution errors. It runs the same INC/PE/AoP/LAN
// passes but with a per-axis dV cap since it's corrective only.
//
// CFG keys consumed:
//   CAPTURE_DIR  — "PROGRADE" / "POLAR" / "RETROPOLAR" / "RETROGRADE"
//   CAPTURE_INC  — explicit inclination (overrides CAPTURE_DIR)
//   LAN_ERR_TOL  — LAN tolerance for scan (default 0.5°)
//   TRANSFER_AOP_ERR_TOL — max accepted transfer AoP error (default 35°)
//   TRANSFER_INC_ERR_TOL — max accepted transfer INC error (default 1°)
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
    // is unconstrained, so AoP has no absolute meaning.
    IF aopTarget >= 0 AND lanTarget < 0 {
        mLog("Ignoring CAPTURE_AOP without CAPTURE_LAN (AoP alone is unconstrained).").
        SET aopTarget TO -1.
    }

    LOCAL isLocal IS (targetBody:BODY = BODY).
    LOCAL isEscape IS (targetBody = BODY:BODY).
    mLogWarn("STATS transfer setup target=" + targetBody:NAME
        + " local=" + isLocal + " escape=" + isEscape
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " lan=" + ROUND(lanTarget,1)
        + " aop=" + ROUND(aopTarget,1)).

    // Resolve capture orbit direction before seeding the raw transfer
    // so the coarse departure scans can prefer windows that already
    // arrive near the requested capture plane.
    LOCAL captureInc IS -1.
    LOCAL normalBias IS 0.
    IF CFG:HASKEY("CAPTURE_DIR") {
        LOCAL dir IS CFG["CAPTURE_DIR"].
        IF dir = "PROGRADE"   { SET captureInc TO 0. }
        IF dir = "POLAR"      { SET captureInc TO 90.  SET normalBias TO 1. }
        IF dir = "RETROPOLAR" { SET captureInc TO 90.  SET normalBias TO -1. }
        IF dir = "RETROGRADE" { SET captureInc TO 180. }
    }
    IF CFG:HASKEY("CAPTURE_INC") { SET captureInc TO CFG["CAPTURE_INC"]. }

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

    // --- 2. PE pretargeting ---
    // For plain transfers, converge PE to zero (dead-center collision
    // course) first. This gives the widest possible encounter margin
    // before later normal dV. For AoP-guided transfers, target the real
    // capture Pe instead: pushing all the way to collision can move the
    // patch onto the wrong apsidal branch, while skipping PE leaves the
    // coupled solver dominated by a huge periapsis error.
    IF aopTarget >= 0 {
        mLogWarn("STATS transfer stage=guided-pe targetPeKm=" + ROUND(targetPe/1000,1)).
        newtonTarget(nd, targetBody, "PE", targetPe).
    } ELSE {
        newtonTarget(nd, targetBody, "PE", 0).
    }

    // --- 3. Safe injection targeting waterfall ---
    // Scan-time objectives may include AoP and LAN. Injection-time
    // targets are narrower: always PE, optionally INC, optionally LAN.
    // AoP is intentionally not included here; it selects the departure
    // basin and is then accepted/rejected by the final angular gate.
    IF captureInc < 0 AND lanTarget < 0 AND aopTarget < 0 {
        newtonTarget(nd, targetBody, "PE", targetPe).
    } ELSE {
        // Seed normal bias for polar/retropolar before the solver starts
        IF normalBias <> 0 AND nd:NORMAL = 0 {
            SET nd:NORMAL TO normalBias * 5.
            WAIT 0.02.
        }

        LOCAL planeTargets IS LEXICON().
        planeTargets:ADD("PE", targetPe).
        planeTargets:ADD("PE_FLOOR", -25000).
        IF captureInc >= 0 { planeTargets:ADD("INC", captureInc). }
        IF aopTarget >= 0 { planeTargets:ADD("AOP_GUIDE", aopTarget). }

        LOCAL planeOpts IS LEXICON().
        planeOpts:ADD("STEP_NORMAL", 40.0).
        planeOpts:ADD("STEP_PROGRADE", 20.0).
        planeOpts:ADD("STEP_RADIAL", 20.0).
        planeOpts:ADD("STEP_TIME", CHOOSE 5.0 IF aopTarget >= 0 ELSE 60.0).
        planeOpts:ADD("MIN_STEP", 0.05).
        planeOpts:ADD("MAX_ITER", 120).
        IF aopTarget >= 0 { planeOpts:ADD("MIN_ITER", 40). }
        IF aopTarget >= 0 { planeOpts:ADD("AOP_GUIDE_STALL_ITER", 5). }
        IF aopTarget >= 0 { planeOpts:ADD("AOP_GUIDE_STALL_MIN_IMPROVE", 2.0). }
        mLogWarn("STATS elements stage=plane-pe-inc before angular targeting.").
        LOCAL planeResult IS _targetPatchElementsCoupled(nd, targetBody, planeTargets, planeOpts).
        IF planeResult:HASKEY("SOLVED") AND NOT planeResult["SOLVED"] {
            LOCAL planeOk IS FALSE.
            LOCAL incTol IS 1.
            LOCAL aopTol IS 35.
            IF CFG:HASKEY("TRANSFER_INC_ERR_TOL") { SET incTol TO CFG["TRANSFER_INC_ERR_TOL"]. }
            IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }
            // AoP-constrained transfers couple PE and AoP — the solver
            // trades PE accuracy for AoP convergence. MCC corrects PE.
            LOCAL peTol IS CHOOSE 5000 IF aopTarget >= 0 ELSE 1000.
            IF ABS(planeResult["PE_ERR"]) <= peTol {
                SET planeOk TO TRUE.
                IF captureInc >= 0 AND ABS(planeResult["INC_ERR"]) > incTol { SET planeOk TO FALSE. }
                IF aopTarget >= 0 AND ABS(planeResult["AOP_ERR"]) > aopTol { SET planeOk TO FALSE. }
            }
            IF planeOk {
                mLogWarn("planTransfer: accepting transfer plane within tolerance"
                    + _elementErrorSummary(planeResult, planeTargets)
                    + " IncTol=" + ROUND(incTol,2)
                    + " AopTol=" + ROUND(aopTol,1)).
            } ELSE {
                mLogError("planTransfer: PE/INC targeting failed; refusing bad transfer node.").
                mLogWarn("STATS transfer result target=" + targetBody:NAME
                    + " status=plane-elements-failed"
                    + _elementErrorSummary(planeResult, planeTargets)).
                IF HASNODE { REMOVE nd. }
                RETURN.
            }
        }

        IF lanTarget >= 0 {
            LOCAL lanTargets IS LEXICON().
            lanTargets:ADD("PE", targetPe).
            lanTargets:ADD("PE_FLOOR", -25000).
            IF captureInc >= 0 { lanTargets:ADD("INC", captureInc). }
            lanTargets:ADD("LAN", lanTarget).
            IF aopTarget >= 0 { lanTargets:ADD("AOP_GUIDE", aopTarget). }

            LOCAL lanOpts IS LEXICON().
            lanOpts:ADD("STEP_NORMAL", CHOOSE 10.0 IF captureInc >= 0 ELSE 5.0).
            lanOpts:ADD("STEP_PROGRADE", CHOOSE 5.0 IF captureInc >= 0 ELSE 2.0).
            lanOpts:ADD("STEP_RADIAL", CHOOSE 10.0 IF captureInc >= 0 ELSE 5.0).
            lanOpts:ADD("STEP_TIME", CHOOSE 5.0 IF aopTarget >= 0 ELSE 60.0).
            lanOpts:ADD("MIN_STEP", 0.05).
            lanOpts:ADD("MAX_ITER", 100).
            IF aopTarget >= 0 { lanOpts:ADD("MIN_ITER", 30). }
            IF aopTarget >= 0 { lanOpts:ADD("AOP_GUIDE_STALL_ITER", 5). }
            IF aopTarget >= 0 { lanOpts:ADD("AOP_GUIDE_STALL_MIN_IMPROVE", 2.0). }
            mLogWarn("STATS elements stage=lan after plane-pe-inc.").
            LOCAL lanResult IS _targetPatchElementsCoupled(nd, targetBody, lanTargets, lanOpts).
            IF lanResult:HASKEY("SOLVED") AND NOT lanResult["SOLVED"] {
                mLogError("planTransfer: LAN targeting failed; refusing bad transfer node.").
                mLogWarn("STATS transfer result target=" + targetBody:NAME
                    + " status=lan-elements-failed"
                    + _elementErrorSummary(lanResult, lanTargets)).
                IF HASNODE { REMOVE nd. }
                RETURN.
            }
        }
    }

    // --- Final report ---
    LOCAL finalPatch IS _getTargetPatch(nd, targetBody).
    IF finalPatch = 0 {
        mLogError("planTransfer: no encounter after targeting.").
        mLogWarn("STATS transfer result target=" + targetBody:NAME + " status=no-encounter").
        RETURN.
    }

    LOCAL logMsg IS "Transfer -> " + targetBody:NAME
        + ": dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s  Pe=" + ROUND(finalPatch:PERIAPSIS/1000,1) + "km"
        + "  inc=" + ROUND(finalPatch:INCLINATION,1) + "°"
        + "  ETA=" + ROUND(nd:TIME - TIME:SECONDS,0) + "s".
    IF lanTarget >= 0 {
        LOCAL lanErr IS ABS(finalPatch:LAN - lanTarget).
        IF lanErr > 180 { SET lanErr TO 360 - lanErr. }
        SET logMsg TO logMsg + "  LAN=" + ROUND(finalPatch:LAN,1) + "(err " + ROUND(lanErr,1) + ")".
    }
    IF aopTarget >= 0 {
        LOCAL aopErr IS ABS(finalPatch:ARGUMENTOFPERIAPSIS - aopTarget).
        IF aopErr > 180 { SET aopErr TO 360 - aopErr. }
        SET logMsg TO logMsg + "  AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1) + "(err " + ROUND(aopErr,1) + ")".
        LOCAL aopTol IS 35.
        IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }
        IF aopErr > aopTol {
            mLogError("planTransfer: AoP misaligned; refusing transfer node.").
            mLogWarn("STATS transfer result target=" + targetBody:NAME
                + " status=aop-misaligned"
                + " AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1)
                + " targetAoP=" + ROUND(aopTarget,1)
                + " AopErr=" + ROUND(aopErr,1)
                + " tol=" + ROUND(aopTol,1)).
            IF HASNODE { REMOVE nd. }
            RETURN.
        }
    }
    mLog(logMsg).
    mLogWarn("STATS transfer result target=" + targetBody:NAME
        + " status=planned dv=" + ROUND(nd:DELTAV:MAG,1)
        + " PeKm=" + ROUND(finalPatch:PERIAPSIS/1000,1)
        + " inc=" + ROUND(finalPatch:INCLINATION,1)
        + " LAN=" + ROUND(finalPatch:LAN,1)
        + " AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1)).
    archivePlannedManeuverLog("transfer").
    RETURN nd.
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
//   6. Optional LAN scan
// ============================================================
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

    // --- Hohmann estimate (seed) ---
    LOCAL rShip   IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL rTarget IS targetBody:ORBIT:SEMIMAJORAXIS.
    LOCAL hohmannA IS (rShip + rTarget) / 2.
    LOCAL hohmannTof IS CONSTANT:PI * SQRT(hohmannA^3 / mu).
    LOCAL vShip   IS SQRT(mu / rShip).
    LOCAL vDepart IS SQRT(mu * (2/rShip - 1/hohmannA)).
    LOCAL hohmannDv IS vDepart - vShip.

    mLog("Local transfer to " + targetBody:NAME
        + ": Hohmann dV=" + ROUND(hohmannDv, 1) + " m/s"
        + "  TOF=" + ROUND(hohmannTof, 0) + "s").

    // --- Phase angle estimate for initial departure time ---
    LOCAL targetMeanMotion IS 360 / targetPeriod.
    LOCAL targetSweep IS targetMeanMotion * hohmannTof.
    LOCAL idealPhaseAngle IS 180 - targetSweep.

    SET TARGET TO targetBody.
    WAIT 0.1.
    LOCAL currentPhase IS phaseAngle().

    LOCAL synodicPeriod IS ABS(shipPeriod * targetPeriod / (shipPeriod - targetPeriod)).

    LOCAL phaseDiff IS idealPhaseAngle - currentPhase.
    IF phaseDiff < 0 { SET phaseDiff TO phaseDiff + 360. }
    LOCAL shipAngRate IS 360 / shipPeriod.
    LOCAL targetAngRate IS 360 / targetPeriod.
    LOCAL relativeRate IS shipAngRate - targetAngRate.
    LOCAL waitTime IS phaseDiff / ABS(relativeRate).

    IF waitTime < 60 { SET waitTime TO waitTime + synodicPeriod. }

    LOCAL departUt IS TIME:SECONDS + waitTime.

    mLog("Phase: current=" + ROUND(currentPhase, 1)
        + "  ideal=" + ROUND(idealPhaseAngle, 1)
        + "  wait=" + ROUND(waitTime, 0) + "s").

    // --- Place prograde-only node ---
    LOCAL nd IS NODE(departUt, 0, 0, hohmannDv).
    ADD nd.
    WAIT 0.1.

    // --- Scan departure time to minimize closest approach ---
    // Scan multiple orbits around the phase angle estimate. The phase
    // angle math can be significantly off, so we search ±N orbits
    // where N covers at least one synodic period.
    LOCAL nScanOrbits IS MAX(6, CEILING(synodicPeriod / shipPeriod)).
    LOCAL samplesPerOrbit IS 4.
    IF lanTarget >= 0 OR aopTarget >= 0 { SET samplesPerOrbit TO 12. }
    IF CFG:HASKEY("TRANSFER_SCAN_SAMPLES_PER_ORBIT") {
        SET samplesPerOrbit TO MAX(4, CFG["TRANSFER_SCAN_SAMPLES_PER_ORBIT"]).
    }
    LOCAL scanSteps IS nScanOrbits * samplesPerOrbit.
    LOCAL scanDt IS shipPeriod / samplesPerOrbit.

    LOCAL bestTime IS departUt.
    LOCAL bestCA IS _findClosestApproach(targetBody, departUt + hohmannTof * 0.5, departUt + hohmannTof * 1.5, 40).
    LOCAL bestSeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, bestCA["distance"], nd:DELTAV:MAG).
    LOCAL previewShortlist IS 5.
    IF CFG:HASKEY("TRANSFER_PREVIEW_SHORTLIST") {
        SET previewShortlist TO MAX(1, CFG["TRANSFER_PREVIEW_SHORTLIST"]).
    }
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

    mLog("Element-aware transfer scan: " + scanSteps
        + " steps over ±" + nScanOrbits
        + " orbits  samples/orbit=" + samplesPerOrbit).

    FROM { LOCAL si IS -scanSteps. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTime IS departUt + si * scanDt.
        IF tryTime > TIME:SECONDS + 30 {
            SET nd:TIME TO tryTime.
            WAIT 0.02.
            LOCAL tryCa IS _findClosestApproach(targetBody, tryTime + hohmannTof * 0.5, tryTime + hohmannTof * 1.5, 40).
            LOCAL trySeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, tryCa["distance"], nd:DELTAV:MAG).
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
        }
    }
    SET nd:TIME TO bestTime.
    WAIT 0.1.
    mLog("Time scan: best CA=" + ROUND(bestCA["distance"]/1000, 1) + "km"
        + " score=" + ROUND(bestSeed["SCORE"], 2)
        + " AoPerr=" + ROUND(bestSeed["AOP_ERR"], 1)
        + " at T+" + ROUND(bestCA["time"] - TIME:SECONDS, 0) + "s"
        + "  depart T+" + ROUND(bestTime - TIME:SECONDS, 0) + "s").

    // --- AoP hard-filter: pick best AoP-acceptable candidate ---
    // AoP is a basin selection problem controlled by departure timing.
    // If the best raw candidate exceeds the AoP tolerance, search the
    // shortlist for the first acceptable one (already sorted by seed score).
    IF aopTarget >= 0 {
        LOCAL aopFilterTol IS 35.
        IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopFilterTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }
        IF ABS(bestSeed["AOP_ERR"]) > aopFilterTol {
            LOCAL found IS FALSE.
            FROM { LOCAL fi IS 0. } UNTIL fi >= previewShortlist STEP { SET fi TO fi + 1. } DO {
                IF scanSeeds[fi]["SCORE"] < 999999999
                    AND ABS(scanSeeds[fi]["AOP_ERR"]) <= aopFilterTol {
                    SET bestTime TO scanTimes[fi].
                    SET bestCA TO scanCAs[fi].
                    SET bestSeed TO scanSeeds[fi].
                    SET found TO TRUE.
                    BREAK.
                }
            }
            SET nd:TIME TO bestTime.
            WAIT 0.1.
            IF found {
                mLog("AoP filter: replaced best with AoP-acceptable candidate"
                    + " AoPerr=" + ROUND(bestSeed["AOP_ERR"], 1)
                    + " score=" + ROUND(bestSeed["SCORE"], 2)
                    + " depart T+" + ROUND(bestTime - TIME:SECONDS, 0) + "s").
            } ELSE {
                mLogWarn("AoP filter: no candidate within AoP tolerance " + ROUND(aopFilterTol, 1)
                    + "; proceeding with best raw seed AoPerr=" + ROUND(bestSeed["AOP_ERR"], 1)).
            }
        } ELSE {
            mLog("AoP filter: best raw candidate acceptable AoPerr=" + ROUND(bestSeed["AOP_ERR"], 1)).
        }
    }

    // --- Golden section refine departure time + dV ---
    // Skip when AoP is constrained: the raw scan found the correct
    // retrograde/prograde basin and golden section assumes unimodal
    // landscape. For retrograde targets (INC=180) the good geometry
    // is a narrow feature in time; golden section drifts into the
    // dominant prograde basin. The downstream coupled solver handles
    // PE/INC fine-tuning from the raw scan's departure time.
    IF aopTarget < 0 {
        LOCAL tA IS MAX(TIME:SECONDS + 30, bestTime - scanDt).
        LOCAL tB IS bestTime + scanDt.
        LOCAL gr IS (SQRT(5) + 1) / 2.

        FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
            LOCAL tC IS tB - (tB - tA) / gr.
            LOCAL tD IS tA + (tB - tA) / gr.

            SET nd:TIME TO tC. WAIT 0.02.
            LOCAL caC IS _findClosestApproach(targetBody, tC + hohmannTof * 0.4, tC + hohmannTof * 1.6, 30).
            LOCAL seedC IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, caC["distance"], nd:DELTAV:MAG).
            SET nd:TIME TO tD. WAIT 0.02.
            LOCAL caD IS _findClosestApproach(targetBody, tD + hohmannTof * 0.4, tD + hohmannTof * 1.6, 30).
            LOCAL seedD IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, caD["distance"], nd:DELTAV:MAG).

            IF seedC["SCORE"] < seedD["SCORE"] {
                SET tB TO tD.
            } ELSE {
                SET tA TO tC.
            }
        }
        SET nd:TIME TO (tA + tB) / 2.
        WAIT 0.1.

        // --- Scan prograde dV to refine transfer shape ---
        // ±20% of Hohmann dV (or ±10 m/s minimum)
        LOCAL dvRange IS MAX(10, ABS(hohmannDv) * 0.2).
        LOCAL dvSteps IS 20.
        LOCAL dvStep IS dvRange * 2 / dvSteps.
        LOCAL bestDv IS hohmannDv.
        SET bestCA TO _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
        SET bestSeed TO _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, bestCA["distance"], nd:DELTAV:MAG).

        FROM { LOCAL di IS 0. } UNTIL di > dvSteps STEP { SET di TO di + 1. } DO {
            LOCAL tryDv IS hohmannDv - dvRange + di * dvStep.
            SET nd:PROGRADE TO tryDv.
            WAIT 0.02.
            LOCAL tryCa IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
            LOCAL trySeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, tryCa["distance"], nd:DELTAV:MAG).
            IF trySeed["SCORE"] < bestSeed["SCORE"] {
                SET bestCA TO tryCa.
                SET bestSeed TO trySeed.
                SET bestDv TO tryDv.
            }
        }
        SET nd:PROGRADE TO bestDv.
        WAIT 0.1.

        // Golden section refine prograde
        LOCAL dvA IS MAX(bestDv - dvStep, hohmannDv - dvRange).
        LOCAL dvB IS MIN(bestDv + dvStep, hohmannDv + dvRange).

        FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
            LOCAL dvC IS dvB - (dvB - dvA) / gr.
            LOCAL dvD IS dvA + (dvB - dvA) / gr.

            SET nd:PROGRADE TO dvC. WAIT 0.02.
            LOCAL caC IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
            LOCAL seedC IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, caC["distance"], nd:DELTAV:MAG).
            SET nd:PROGRADE TO dvD. WAIT 0.02.
            LOCAL caD IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
            LOCAL seedD IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, caD["distance"], nd:DELTAV:MAG).

            IF seedC["SCORE"] < seedD["SCORE"] {
                SET dvB TO dvD.
            } ELSE {
                SET dvA TO dvC.
            }
        }
        SET nd:PROGRADE TO (dvA + dvB) / 2.
        WAIT 0.1.
    } ELSE {
        mLog("Skipping golden section (AoP constrained): preserving raw scan basin.").
    }

    LOCAL finalCA IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.3, nd:TIME + hohmannTof * 2.0, 60).
    LOCAL finalSeed IS _transferPreviewSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, finalCA["distance"], nd:DELTAV:MAG).
    IF (captureInc >= 0 OR lanTarget >= 0) AND aopTarget < 0 {
        _nodeAxisSet(nd, "TIME", finalSeed["NODE_TIME"]).
        _nodeAxisSet(nd, "PROGRADE", finalSeed["NODE_PROGRADE"]).
        _nodeAxisSet(nd, "NORMAL", finalSeed["NODE_NORMAL"]).
        _nodeAxisSet(nd, "RADIALOUT", finalSeed["NODE_RADIAL"]).
        WAIT 0.1.
        SET finalCA TO _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.3, nd:TIME + hohmannTof * 2.0, 60).
        SET finalSeed TO _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, finalCA["distance"], nd:DELTAV:MAG).
        mLog("Applied constrained preview seed: N="
            + ROUND(nd:NORMAL, 1)
            + " R=" + ROUND(nd:RADIALOUT, 1)
            + " dV=" + ROUND(nd:DELTAV:MAG, 1) + " m/s").
    }
    mLog("Optimized: CA=" + ROUND(finalCA["distance"]/1000, 1) + "km"
        + " score=" + ROUND(finalSeed["SCORE"], 2)
        + " AoPerr=" + ROUND(finalSeed["AOP_ERR"], 1)
        + "  dV=" + ROUND(nd:DELTAV:MAG, 1) + " m/s"
        + "  depart T+" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    mLogWarn("STATS local-transfer target=" + targetBody:NAME
        + " caKm=" + ROUND(finalCA["distance"]/1000,1)
        + " score=" + ROUND(finalSeed["SCORE"],2)
        + " patch=" + finalSeed["PATCH"]
        + " incErr=" + ROUND(finalSeed["INC_ERR"],1)
        + " lanErr=" + ROUND(finalSeed["LAN_ERR"],1)
        + " aopErr=" + ROUND(finalSeed["AOP_ERR"],1)
        + " prograde=" + ROUND(nd:PROGRADE,1)
        + " normal=" + ROUND(nd:NORMAL,1)
        + " radial=" + ROUND(nd:RADIALOUT,1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).

    // --- Optional LAN scan ---
    // If lanTarget is specified, scan across multiple orbits to find the departure
    // that produces the closest LAN at the target body (read from KSP's conics).
    IF lanTarget >= 0 AND aopTarget < 0 {
        SET nd TO _scanForLan(nd, targetBody, lanTarget, shipPeriod).
    }

    RETURN nd.
}

LOCAL FUNCTION _transferPreviewSeedScore {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER captureInc.
    PARAMETER lanTarget.
    PARAMETER aopTarget.
    PARAMETER caDist IS 0.
    PARAMETER dvMag IS 0.

    IF captureInc < 0 AND lanTarget < 0 AND aopTarget < 0 {
        RETURN _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, caDist, dvMag).
    }

    LOCAL origTime IS nd:TIME.
    LOCAL origPrograde IS nd:PROGRADE.
    LOCAL origNormal IS nd:NORMAL.
    LOCAL origRadial IS nd:RADIALOUT.

    LOCAL targets IS LEXICON().
    targets:ADD("PE", targetPe).
    targets:ADD("PE_FLOOR", -25000).
    IF captureInc >= 0 { targets:ADD("INC", captureInc). }
    IF lanTarget >= 0 { targets:ADD("LAN", lanTarget). }
    IF aopTarget >= 0 { targets:ADD("AOP_GUIDE", aopTarget). }

    LOCAL opts IS LEXICON().
    opts:ADD("STEP_NORMAL", 25.0).
    opts:ADD("STEP_PROGRADE", 12.0).
    opts:ADD("STEP_RADIAL", 12.0).
    opts:ADD("STEP_TIME", 45.0).
    opts:ADD("MIN_STEP", 1.0).
    opts:ADD("MAX_ITER", 18).
    opts:ADD("QUIET", TRUE).
    IF aopTarget >= 0 { opts:ADD("AOP_GUIDE_STALL_ITER", 5). }
    IF aopTarget >= 0 { opts:ADD("AOP_GUIDE_STALL_MIN_IMPROVE", 2.0). }

    LOCAL preview IS _targetPatchElementsCoupled(nd, targetBody, targets, opts).
    LOCAL previewDv IS nd:DELTAV:MAG.
    LOCAL previewTime IS nd:TIME.
    LOCAL previewPrograde IS nd:PROGRADE.
    LOCAL previewNormal IS nd:NORMAL.
    LOCAL previewRadial IS nd:RADIALOUT.
    LOCAL score IS preview["COST"] + (caDist / 250000)^2 + previewDv * 0.01.
    LOCAL aopTol IS 35.
    IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }
    IF preview["PATCH"] = 0 { SET score TO score + 10000000. }
    IF aopTarget >= 0 AND ABS(preview["AOP_ERR"]) > aopTol {
        SET score TO score + 100000 + ((ABS(preview["AOP_ERR"]) - aopTol) / 1.0)^2 * 500.
    }

    _nodeAxisSet(nd, "TIME", origTime).
    _nodeAxisSet(nd, "PROGRADE", origPrograde).
    _nodeAxisSet(nd, "NORMAL", origNormal).
    _nodeAxisSet(nd, "RADIALOUT", origRadial).
    WAIT 0.02.

    RETURN LEXICON(
        "SCORE", score,
        "PATCH", preview["PATCH"] = 1,
        "CA", caDist,
        "DV", previewDv,
        "PE_ERR", preview["PE_ERR"],
        "INC_ERR", preview["INC_ERR"],
        "LAN_ERR", preview["LAN_ERR"],
        "AOP_ERR", preview["AOP_ERR"],
        "NODE_TIME", previewTime,
        "NODE_PROGRADE", previewPrograde,
        "NODE_NORMAL", previewNormal,
        "NODE_RADIAL", previewRadial
    ).
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
//   6. Optional LAN scan
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
    LOCAL kscTarget IS CFG:HASKEY("ESCAPE_KSC_TARGET").
    LOCAL KSC_LNG IS -74.6.
    LOCAL kscTransitA IS (rMoon + targetBody:RADIUS + targetPe) / 2.

    // --- Departure time scan ---
    // Scan departure times to find best ejection angle.
    // If KSC targeting, scan enough orbits for Kerbin to rotate once.
    LOCAL nScanOrbits IS 1.
    IF kscTarget {
        SET nScanOrbits TO MAX(6, CEILING(targetBody:ROTATIONPERIOD / shipPeriod)).
    }
    IF lanTarget >= 0 OR aopTarget >= 0 {
        SET nScanOrbits TO MAX(nScanOrbits, CEILING(BODY:ORBIT:PERIOD / shipPeriod)).
    }
    SET nScanOrbits TO MAX(nScanOrbits, 1).

    LOCAL samplesPerOrbit IS 12.
    LOCAL scanSteps IS nScanOrbits * samplesPerOrbit.
    LOCAL scanDt IS shipPeriod / samplesPerOrbit.

    LOCAL bestTime IS departUt.
    LOCAL bestScore IS 999999999.

    mLog("Escape departure scan: " + (2 * scanSteps + 1) + " steps"
        + " over ±" + nScanOrbits + " orbits"
        + "  KSC=" + kscTarget).

    FROM { LOCAL si IS -scanSteps. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
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
    LOCAL tA IS MAX(TIME:SECONDS + 30, bestTime - scanDt).
    LOCAL tB IS bestTime + scanDt.
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

    FROM { LOCAL di IS 0. } UNTIL di > dvSteps STEP { SET di TO di + 1. } DO {
        LOCAL tryDv IS escapeDv - dvRange + di * dvStep.
        SET nd:PROGRADE TO tryDv.
        WAIT 0.02.
        LOCAL trySeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).
        IF trySeed["SCORE"] < bestDvScore {
            SET bestDvScore TO trySeed["SCORE"].
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
        SET nd:PROGRADE TO dvD. WAIT 0.02.
        LOCAL seedD IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget).

        IF seedC["SCORE"] < seedD["SCORE"] {
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
        + " PeErr=" + ROUND(finalSeed["PE_ERR"]/1000, 1) + "km"
        + " depart T+" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    mLogWarn("STATS escape-transfer target=" + targetBody:NAME
        + " dv=" + ROUND(nd:PROGRADE,1)
        + " score=" + ROUND(finalSeed["SCORE"],2)
        + " patch=" + finalSeed["PATCH"]
        + " peErr=" + ROUND(finalSeed["PE_ERR"],0)
        + " incErr=" + ROUND(finalSeed["INC_ERR"],1)
        + " lanErr=" + ROUND(finalSeed["LAN_ERR"],1)
        + " aopErr=" + ROUND(finalSeed["AOP_ERR"],1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).

    // --- Optional LAN scan ---
    IF lanTarget >= 0 AND NOT kscTarget {
        SET nd TO _scanForLan(nd, targetBody, lanTarget, shipPeriod, BODY:ORBIT:PERIOD).
    }

    RETURN nd.
}

// ============================================================
// phaseMidCourse — mid-course correction during transfer coast.
//
// Fires at coast midpoint (local) or 1h past SOI (interplanetary).
// This is a fine-tune pass — planTransfer handles the primary INC
// targeting at departure where normal dV is cheapest. MCC corrects
// drift from burn execution errors and refines the approach.
//
// Uses phased Newton: INC → AoP → PE → LAN → PE cleanup.
// Per-axis dV cap (MCC_DV_CAP) so axes don't compete for budget.
// ============================================================
GLOBAL FUNCTION phaseMidCourse {
    LOCAL target IS missionTargetBody().

    IF NOT CFG:HASKEY("CAPTURE_PE") {
        mLog("No CAPTURE_PE. Skipping MCC.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL targetPe  IS CFG["CAPTURE_PE"].
    LOCAL targetInc IS -1.
    LOCAL targetLan IS -1.
    LOCAL targetAoP IS -1.

    // Resolve CAPTURE_DIR to inclination
    IF CFG:HASKEY("CAPTURE_DIR") {
        LOCAL dir IS CFG["CAPTURE_DIR"].
        IF dir = "PROGRADE"   { SET targetInc TO 0. }
        IF dir = "POLAR"      { SET targetInc TO 90. }
        IF dir = "RETROPOLAR" { SET targetInc TO 90. }
        IF dir = "RETROGRADE" { SET targetInc TO 180. }
    }
    IF CFG:HASKEY("CAPTURE_INC") { SET targetInc TO CFG["CAPTURE_INC"]. }
    IF CFG:HASKEY("CAPTURE_LAN") { SET targetLan TO CFG["CAPTURE_LAN"]. }
    IF CFG:HASKEY("CAPTURE_AOP") { SET targetAoP TO CFG["CAPTURE_AOP"]. }
    IF targetAoP >= 0 AND targetLan < 0 {
        mLog("MCC: Ignoring CAPTURE_AOP without CAPTURE_LAN.").
        SET targetAoP TO -1.
    }

    LOCAL patch IS _getTargetPatch(SHIP, target).
    IF patch = 0 {
        mLogWarn("No encounter with " + target:NAME + ". Skipping MCC.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL waitTime IS 0.
    IF SHIP:ORBIT:NEXTPATCH:BODY:NAME <> target:NAME {
        SET waitTime TO ETA:TRANSITION + 3600.
        mLog("MCC: Interplanetary — coast " + ROUND(waitTime) + "s past SOI.").
    } ELSE {
        SET waitTime TO ETA:TRANSITION / 2.
        mLog("MCC: Local — coast to halfway (" + ROUND(waitTime) + "s).").
    }

    mLog("MCC: Pre-correction  Pe=" + ROUND(patch:PERIAPSIS/1000,1) + "km"
        + "  AoP=" + ROUND(patch:ARGUMENTOFPERIAPSIS,1)
        + "°  LAN=" + ROUND(patch:LAN,1) + "°.").
    mLogWarn("STATS mcc setup target=" + target:NAME
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " targetInc=" + ROUND(targetInc,1)
        + " targetLAN=" + ROUND(targetLan,1)
        + " targetAoP=" + ROUND(targetAoP,1)
        + " startPeKm=" + ROUND(patch:PERIAPSIS/1000,1)
        + " startInc=" + ROUND(patch:INCLINATION,1)
        + " startLAN=" + ROUND(patch:LAN,1)
        + " startAoP=" + ROUND(patch:ARGUMENTOFPERIAPSIS,1)).

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + waitTime, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    LOCAL mccOpts IS LEXICON("DV_CAP", MCC_DV_CAP).
    LOCAL elementTargets IS LEXICON().
    elementTargets:ADD("PE", targetPe).
    IF targetInc >= 0 { elementTargets:ADD("INC", targetInc). }
    IF targetLan >= 0 { elementTargets:ADD("LAN", targetLan). }
    IF targetAoP >= 0 { elementTargets:ADD("AOP", targetAoP). }
    LOCAL useElementSolver IS FALSE.
    IF targetLan >= 0 OR targetAoP >= 0 { SET useElementSolver TO TRUE. }

    // Local polar approaches couple PE and INC strongly. Running INC and
    // PE as independent Newton passes can turn a good 20km encounter into
    // a high flyby. LAN and AoP have the same problem, so when they are
    // requested we score all requested elements together. The unified
    // element solver handles PE-only, PE+INC, and PE+INC+LAN+AoP.
    LOCAL preCost IS 0.
    IF useElementSolver OR targetInc >= 0 {
        LOCAL preElemEval IS _patchElementsCostFromPatch(patch, elementTargets).
        SET preCost TO preElemEval["COST"].
        LOCAL elemOpts IS LEXICON().
        elemOpts:ADD("DV_CAP", MCC_DV_CAP).
        elemOpts:ADD("STEP_NORMAL", 2.0).
        elemOpts:ADD("STEP_PROGRADE", 1.0).
        elemOpts:ADD("STEP_RADIAL", 1.0).
        elemOpts:ADD("STEP_TIME", 120.0).
        elemOpts:ADD("MIN_STEP", 0.02).
        elemOpts:ADD("MAX_ITER", CHOOSE 100 IF useElementSolver ELSE 80).
        elemOpts:ADD("MIN_TIME", TIME:SECONDS + 60).
        _targetPatchElementsCoupled(nd, target, elementTargets, elemOpts).
    } ELSE {
        newtonTarget(nd, target, "PE", targetPe, mccOpts).
    }

    WAIT 0.1.

    LOCAL totalDv IS nd:DELTAV:MAG.
    LOCAL finalPatch IS _getTargetPatch(nd, target).
    LOCAL minMccDv IS MCC_MIN_DV.
    IF CFG:HASKEY("MCC_MIN_DV") { SET minMccDv TO CFG["MCC_MIN_DV"]. }
    IF ETA:TRANSITION < MCC_LATE_ETA {
        SET minMccDv TO MAX(minMccDv, MCC_LATE_MIN_DV).
        IF CFG:HASKEY("MCC_LATE_MIN_DV") { SET minMccDv TO CFG["MCC_LATE_MIN_DV"]. }
    }

    LOCAL worsened IS FALSE.
    IF (useElementSolver OR targetInc >= 0) AND finalPatch <> 0 {
        LOCAL finalElemEval IS _patchElementsCostFromPatch(finalPatch, elementTargets).
        LOCAL finalElemCost IS finalElemEval["COST"].
        IF finalElemCost > preCost * 1.05 { SET worsened TO TRUE. }
        IF ABS(finalElemEval["PE_ERR"]) > 100000 { SET worsened TO TRUE. }
    }

    IF totalDv < minMccDv OR finalPatch = 0 OR worsened {
        IF worsened {
            mLogWarn("MCC made approach worse; skipping correction node.").
        } ELSE IF totalDv < minMccDv {
            mLogWarn("MCC correction below threshold; skipping correction node.").
        }
        mLog("Encounter on target. Skipping MCC burn.").
        mLogWarn("STATS mcc result target=" + target:NAME
            + " status=skipped dv=" + ROUND(totalDv,1)
            + " minDv=" + ROUND(minMccDv,1)
            + " worsened=" + worsened).
        REMOVE nd.
    } ELSE {
        LOCAL logMsg IS "MCC planned: dV=" + ROUND(totalDv, 1)
            + " m/s  Pe=" + ROUND(finalPatch:PERIAPSIS/1000,1) + "km".
        IF targetInc >= 0 {
            SET logMsg TO logMsg + "  INC=" + ROUND(finalPatch:INCLINATION,1) + "°".
        }
        IF targetLan >= 0 {
            SET logMsg TO logMsg + "  LAN=" + ROUND(finalPatch:LAN,1) + "°".
        }
        IF targetAoP >= 0 {
            SET logMsg TO logMsg + "  AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1) + "°".
        }
        mLog(logMsg).
        mLogWarn("STATS mcc result target=" + target:NAME
            + " status=planned dv=" + ROUND(totalDv,1)
            + " PeKm=" + ROUND(finalPatch:PERIAPSIS/1000,1)
            + " inc=" + ROUND(finalPatch:INCLINATION,1)
            + " LAN=" + ROUND(finalPatch:LAN,1)
            + " AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1)).
        archivePlannedManeuverLog("mcc").
        LOCAL success IS FALSE.
        LOCAL retries IS 0.
        UNTIL success {
            SET success TO executeManeuver().
            IF NOT success {
                SET retries TO retries + 1.
                IF retries >= MAX_RETRIES {
                    mLogError("MCC failed. Abandoning.").
                    IF HASNODE { REMOVE NEXTNODE. }
                    BREAK.
                }
                WAIT 10.
            }
        }
    }
    orbitSummary().
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseMcc {
    phaseMidCourse().
}
