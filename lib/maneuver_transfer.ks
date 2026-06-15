// ============================================================
// maneuver_transfer.ks — transfer planning and mid-course correction
// ============================================================

@LAZYGLOBAL OFF.

// TRUE when the mission sequence carries BPLANE (arrival corridor)
// or SHAPE (closed-form final orbit) — the phases that own exact
// plane/AoP work in the new pipeline.
LOCAL FUNCTION _angularWorkDeferred {
    LOCAL seqRaw IS stateGet("mission_cfg_SEQUENCE", "").
    RETURN seqRaw:CONTAINS("BPLANE") OR seqRaw:CONTAINS("SHAPE").
}

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
        IF aopTarget >= 0 { planeOpts:ADD("AOP_GUIDE_STALL_ITER", 15). }
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
            // With BPLANE/SHAPE downstream the capture plane and exact
            // periapsis are THEIR job. This is especially important for
            // missed-burn rescue: XING may find a cheap near-term patch
            // whose PE/INC are rough, but BPLANE can move that smooth
            // hyperbolic aim point. Keep the element solver in the loop
            // because it improves the handoff, then accept a real patch
            // inside a broad BPLANE correction envelope.
            LOCAL deferred IS _angularWorkDeferred().
            IF deferred {
                SET peTol  TO MAX(peTol, 50000).
                SET incTol TO MAX(incTol, 45).
                IF CFG:HASKEY("TRANSFER_DEFERRED_PE_ERR_TOL") {
                    SET peTol TO CFG["TRANSFER_DEFERRED_PE_ERR_TOL"].
                }
                IF CFG:HASKEY("TRANSFER_DEFERRED_INC_ERR_TOL") {
                    SET incTol TO CFG["TRANSFER_DEFERRED_INC_ERR_TOL"].
                }
            }
            IF ABS(planeResult["PE_ERR"]) <= peTol {
                SET planeOk TO TRUE.
                IF captureInc >= 0 AND ABS(planeResult["INC_ERR"]) > incTol { SET planeOk TO FALSE. }
                IF aopTarget >= 0 AND NOT deferred
                        AND ABS(planeResult["AOP_ERR"]) > aopTol { SET planeOk TO FALSE. }
            }
            IF planeOk {
                mLogWarn("planTransfer: accepting transfer plane within tolerance"
                    + _elementErrorSummary(planeResult, planeTargets)
                    + " PeTolKm=" + ROUND(peTol/1000,1)
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

        // With BPLANE/SHAPE downstream, exact LAN/AoP are THEIR job:
        // LAN at the target is set by the departure window (already
        // preferred by the seed scan), not by node tweaks — the hard
        // solve below can burn minutes failing to move LAN at all.
        IF lanTarget >= 0 AND _angularWorkDeferred() {
            mLogWarn("planTransfer: LAN/AoP exactness deferred to"
                + " BPLANE/SHAPE downstream — skipping hard LAN solve.").
        } ELSE IF lanTarget >= 0 {
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
            IF aopTarget >= 0 { lanOpts:ADD("AOP_GUIDE_STALL_ITER", 15). }
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
            IF _angularWorkDeferred() {
                mLogWarn("planTransfer: AoP off by " + ROUND(aopErr,1)
                    + " — accepted, SHAPE corrects it post-capture.").
            } ELSE {
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
LOCAL FUNCTION _localInterceptEval {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER hohmannTof.

    LOCAL ca IS _findClosestApproach(targetBody,
        nd:TIME + hohmannTof * 0.3,
        nd:TIME + hohmannTof * 2.0,
        45).
    LOCAL patch IS _getTargetPatch(nd, targetBody).
    LOCAL score IS ca["distance"] + nd:DELTAV:MAG * 100.
    IF patch <> 0 {
        // Any real SOI patch is better than a near miss. BPLANE can
        // move a rough patch; it cannot correct a non-encounter.
        SET score TO score - targetBody:SOIRADIUS * 2.
    }
    RETURN LEXICON(
        "SCORE", score,
        "CA", ca,
        "PATCH", patch <> 0
    ).
}

LOCAL FUNCTION _refineLocalSoiIntercept {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER hohmannTof.

    LOCAL best IS _localInterceptEval(nd, targetBody, hohmannTof).
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
                    LOCAL trial IS _localInterceptEval(nd, targetBody, hohmannTof).
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
            SET best TO _localInterceptEval(nd, targetBody, hohmannTof).
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

    LOCAL final IS _localInterceptEval(nd, targetBody, hohmannTof).
    mLogWarn("STATS soi-refine target=" + targetBody:NAME
        + " startCaKm=" + ROUND(startCA / 1000, 1)
        + " finalCaKm=" + ROUND(final["CA"]["distance"] / 1000, 1)
        + " startPatch=" + startPatch
        + " finalPatch=" + final["PATCH"]
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

    // --- Hohmann estimate (seed) ---
    LOCAL rShip   IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL rTarget IS targetBody:ORBIT:SEMIMAJORAXIS.
    LOCAL seed IS _hohmannSeed(rShip, rTarget, mu, targetPeriod).
    LOCAL hohmannTof IS seed["TOF"].
    LOCAL hohmannDv IS seed["DV"].

    mLog("Local transfer to " + targetBody:NAME
        + ": Hohmann dV=" + ROUND(hohmannDv, 1) + " m/s"
        + "  TOF=" + ROUND(hohmannTof, 0) + "s").

    // --- Phase angle estimate for initial departure time ---
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

    // --- Place prograde-only node ---
    LOCAL nd IS NODE(departUt, 0, 0, hohmannDv).
    ADD nd.
    WAIT 0.1.

    // --- Scan departure time to minimize closest approach ---
    // Search a near-term lookahead window from NOW, not ±N full ship
    // orbits around the phase seed. This matters after a missed burn:
    // the current orbit may be a long transfer ellipse, and "a few
    // orbits" can mean days. XING as a rescue/reacquire phase should
    // look for a correction in the next few hours.
    // Each sample tries one ejection point in the parking orbit. For an
    // inclined target the ejection longitude is the dominant lever (it
    // orients the transfer ellipse and its apoapsis), so 4/orbit (every
    // 90deg) steps right over good windows. 12/orbit = every 30deg.
    LOCAL samplesPerOrbit IS 12.
    IF CFG:HASKEY("TRANSFER_SCAN_SAMPLES_PER_ORBIT") {
        SET samplesPerOrbit TO MAX(4, CFG["TRANSFER_SCAN_SAMPLES_PER_ORBIT"]).
    }
    LOCAL scanHours IS 6.
    IF CFG:HASKEY("TRANSFER_SCAN_LOOKAHEAD_HOURS") {
        SET scanHours TO MAX(0.25, CFG["TRANSFER_SCAN_LOOKAHEAD_HOURS"]).
    }
    LOCAL maxScanStep IS 600.
    IF CFG:HASKEY("TRANSFER_SCAN_STEP_MINUTES") {
        SET maxScanStep TO MAX(60, CFG["TRANSFER_SCAN_STEP_MINUTES"] * 60).
    }
    LOCAL scanStart IS TIME:SECONDS + 30.
    LOCAL scanEnd IS TIME:SECONDS + scanHours * 3600.
    LOCAL scanDt IS MIN(shipPeriod / samplesPerOrbit, maxScanStep).
    SET scanDt TO MAX(30, scanDt).
    LOCAL scanSteps IS MAX(1, CEILING((scanEnd - scanStart) / scanDt)).

    LOCAL bestTime IS MAX(scanStart, MIN(scanEnd, departUt)).
    SET nd:TIME TO bestTime.
    WAIT 0.1.
    LOCAL bestCA IS _findClosestApproach(targetBody, bestTime + hohmannTof * 0.5, bestTime + hohmannTof * 1.5, 40).
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
        + " steps over next " + ROUND(scanHours, 2) + "h"
        + "  step=" + ROUND(scanDt, 0) + "s"
        + "  phaseSeed T+" + ROUND(departUt - TIME:SECONDS, 0) + "s"
        + "  samples/orbit=" + samplesPerOrbit).

    FROM { LOCAL si IS 0. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTime IS scanStart + si * scanDt.
        IF tryTime <= scanEnd {
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
        LOCAL tA IS MAX(scanStart, bestTime - scanDt).
        LOCAL tB IS MIN(scanEnd, bestTime + scanDt).
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

        // --- Scan normal dV to close out-of-plane miss ---
        // A prograde-only transfer stays in the parking-orbit plane, but
        // Minmus is inclined ~6deg to Kerbin's equator: from a near-equatorial
        // parking orbit the closest approach is bounded by the target's
        // out-of-plane position at arrival, which can fall *outside* the SOI.
        // No patch then forms and the downstream coupled elements solver has
        // no gradient to follow (the "no-patch" PeErr=10000km failure). The
        // departure-time scan can't fix this: its +-N orbit window is hours
        // long, far too short to reach a Minmus node crossing (~6 day cadence).
        // So when the encounter is not comfortably inside the SOI, give the
        // smooth CA objective a normal degree of freedom to pull it in. For
        // coplanar targets (the Mun) the encounter is already inside, so the
        // gate skips this and costs nothing.
        LOCAL gateCA IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
        IF gateCA["distance"] > targetBody:SOIRADIUS * 0.7 {
            LOCAL vInj IS SQRT(mu / rShip) + ABS(nd:PROGRADE).
            LOCAL relIncEst IS ABS(targetBody:ORBIT:INCLINATION) + ABS(SHIP:ORBIT:INCLINATION).
            LOCAL nrmRange IS MAX(50, 2 * vInj * SIN(relIncEst / 2)).
            LOCAL nrmSteps IS 20.
            LOCAL nrmStep IS nrmRange * 2 / nrmSteps.
            LOCAL bestNrm IS nd:NORMAL.
            SET bestCA TO gateCA.
            SET bestSeed TO _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, bestCA["distance"], nd:DELTAV:MAG).

            FROM { LOCAL ni IS 0. } UNTIL ni > nrmSteps STEP { SET ni TO ni + 1. } DO {
                LOCAL tryNrm IS bestNrm - nrmRange + ni * nrmStep.
                SET nd:NORMAL TO tryNrm.
                WAIT 0.02.
                LOCAL tryCa IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
                LOCAL trySeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, tryCa["distance"], nd:DELTAV:MAG).
                IF trySeed["SCORE"] < bestSeed["SCORE"] {
                    SET bestCA TO tryCa.
                    SET bestSeed TO trySeed.
                    SET bestNrm TO tryNrm.
                }
            }
            SET nd:NORMAL TO bestNrm.
            WAIT 0.1.

            // Golden section refine normal
            LOCAL nrmA IS bestNrm - nrmStep.
            LOCAL nrmB IS bestNrm + nrmStep.
            FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
                LOCAL nrmC IS nrmB - (nrmB - nrmA) / gr.
                LOCAL nrmD IS nrmA + (nrmB - nrmA) / gr.

                SET nd:NORMAL TO nrmC. WAIT 0.02.
                LOCAL caC IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
                LOCAL seedC IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, caC["distance"], nd:DELTAV:MAG).
                SET nd:NORMAL TO nrmD. WAIT 0.02.
                LOCAL caD IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
                LOCAL seedD IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, caD["distance"], nd:DELTAV:MAG).

                IF seedC["SCORE"] < seedD["SCORE"] {
                    SET nrmB TO nrmD.
                } ELSE {
                    SET nrmA TO nrmC.
                }
            }
            SET nd:NORMAL TO (nrmA + nrmB) / 2.
            WAIT 0.1.

            // Re-refine prograde to recouple the in-plane solution: once the
            // transfer plane is tilted, the best prograde (arrival distance)
            // shifts slightly. Cheap golden pass around the current value.
            LOCAL reDvSpan IS MAX(10, ABS(hohmannDv) * 0.05).
            LOCAL reDvA IS nd:PROGRADE - reDvSpan.
            LOCAL reDvB IS nd:PROGRADE + reDvSpan.
            FROM { LOCAL gj IS 0. } UNTIL gj >= 12 STEP { SET gj TO gj + 1. } DO {
                LOCAL dvE IS reDvB - (reDvB - reDvA) / gr.
                LOCAL dvF IS reDvA + (reDvB - reDvA) / gr.

                SET nd:PROGRADE TO dvE. WAIT 0.02.
                LOCAL caE IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
                LOCAL seedE IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, caE["distance"], nd:DELTAV:MAG).
                SET nd:PROGRADE TO dvF. WAIT 0.02.
                LOCAL caF IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).
                LOCAL seedF IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, caF["distance"], nd:DELTAV:MAG).

                IF seedE["SCORE"] < seedF["SCORE"] {
                    SET reDvB TO dvF.
                } ELSE {
                    SET reDvA TO dvE.
                }
            }
            SET nd:PROGRADE TO (reDvA + reDvB) / 2.
            WAIT 0.1.

            LOCAL postNrmCA IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
            mLog("Normal scan: CA " + ROUND(gateCA["distance"]/1000, 1) + "km -> "
                + ROUND(postNrmCA["distance"]/1000, 1) + "km"
                + "  normal=" + ROUND(nd:NORMAL, 1) + " m/s"
                + "  prograde=" + ROUND(nd:PROGRADE, 1)
                + "  (range +-" + ROUND(nrmRange, 0)
                + ", SOI=" + ROUND(targetBody:SOIRADIUS/1000, 0) + "km)").
        }
    } ELSE {
        // AoP-constrained: skip golden section (drifts out of basin) but
        // still scan prograde dV to minimize closest approach. Score by
        // CA distance only (not full seed score) so the scan doesn't
        // trade encounter proximity for element alignment — downstream
        // solvers handle elements. Reject candidates that leave the AoP
        // tolerance band.
        mLog("AoP-constrained dV scan: preserving scan basin.").
        LOCAL dvRange IS MAX(10, ABS(hohmannDv) * 0.2).
        LOCAL dvSteps IS 20.
        LOCAL dvStep IS dvRange * 2 / dvSteps.
        LOCAL bestDv IS hohmannDv.
        LOCAL aopFilterTol IS 35.
        IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopFilterTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }
        SET bestCA TO _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
        LOCAL bestCaDist IS bestCA["distance"].

        FROM { LOCAL di IS 0. } UNTIL di > dvSteps STEP { SET di TO di + 1. } DO {
            LOCAL tryDv IS hohmannDv - dvRange + di * dvStep.
            SET nd:PROGRADE TO tryDv.
            WAIT 0.02.
            LOCAL tryCa IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
            IF tryCa["distance"] < bestCaDist {
                LOCAL tryPatch IS _getTargetPatch(nd, targetBody).
                LOCAL aopOk IS TRUE.
                IF tryPatch <> 0 {
                    LOCAL tryAopErr IS ABS(_angleError(tryPatch:ARGUMENTOFPERIAPSIS, aopTarget)).
                    IF tryAopErr > aopFilterTol { SET aopOk TO FALSE. }
                }
                IF aopOk {
                    SET bestCA TO tryCa.
                    SET bestCaDist TO tryCa["distance"].
                    SET bestDv TO tryDv.
                }
            }
        }
        SET nd:PROGRADE TO bestDv.
        WAIT 0.1.
        SET bestSeed TO _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, bestCA["distance"], nd:DELTAV:MAG).
    }

    LOCAL interceptCheck IS _localInterceptEval(nd, targetBody, hohmannTof).
    IF (NOT interceptCheck["PATCH"]) OR interceptCheck["CA"]["distance"] > targetBody:SOIRADIUS * 0.85 {
        SET interceptCheck TO _refineLocalSoiIntercept(nd, targetBody, hohmannTof).
    }

    LOCAL finalCA IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.3, nd:TIME + hohmannTof * 2.0, 60).
    LOCAL finalSeed IS _transferPreviewSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, finalCA["distance"], nd:DELTAV:MAG).
    IF (captureInc >= 0 OR lanTarget >= 0) AND aopTarget < 0 AND NOT _angularWorkDeferred() {
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
    } ELSE IF (captureInc >= 0 OR lanTarget >= 0) AND aopTarget < 0 {
        SET finalSeed TO _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, finalCA["distance"], nd:DELTAV:MAG).
        mLog("Skipping constrained preview seed: BPLANE/SHAPE owns exact arrival elements.").
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
