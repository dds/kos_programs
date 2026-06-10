// ============================================================
// xfer_local.ks — 2D porkchop transfer planner for local (same-SOI) transfers
// lib/xfer_local.ks
//
// Replaces _planLocalTransfer with a proper 2D search over
// (departure_time × time_of_flight) using the Lambert solver to
// produce a geometrically correct departure burn for each candidate.
// This directly controls all five capture orbit elements:
//
//   PE  — prograde dV (Lambert seed + Newton polish)
//   AP  — handled downstream by RAISE/ELLIPTICAL phases
//   INC — normal dV component (Lambert seed + Newton polish)
//   LAN — departure timing: which orbit period you leave on
//   AOP — approach direction: the TOF axis of the 2D scan
//
// The old 1D scan (departure_time only, fixed Hohmann TOF) cannot
// control AOP because AOP is a function of both departure_time AND
// TOF together. Scanning both axes gives the solver a basin that
// already has roughly correct geometry before element polishing.
//
// Pipeline:
//   1. Hohmann seed     → initial (departure_time, TOF) estimate
//   2. Porkchop scan    → N_T × N_TOF grid, Lambert dV per cell,
//                         score all requested elements
//   3. 2D hillclimb     → coordinate descent in (departure_time, TOF),
//                         step-halving until convergence
//   4. PE polish        → Newton on prograde dV
//   5. INC polish       → Newton on normal dV (if CAPTURE_INC set)
//   6. LAN orbit scan   → slide departure by ship periods (if CAPTURE_LAN)
//   7. AOP TOF scan     → narrow TOF scan around current best (if CAPTURE_AOP)
//   8. Final coupled    → _targetPatchElementsCoupled for final cleanup
// ============================================================

@LAZYGLOBAL OFF.

// ============================================================
// planLocalXfer — plan a departure node to a local body.
//
// Parameters:
//   targetBody — destination body (must share SOI with ship)
//   opts       — LEXICON with keys:
//     CAPTURE_PE    [m]   target periapsis (required)
//     CAPTURE_INC   [°]   target inclination (-1 = unconstrained)
//     CAPTURE_LAN   [°]   target LAN (-1 = unconstrained)
//     CAPTURE_AOP   [°]   target AOP (-1 = unconstrained)
//     SCAN_TIME_ORBITS    departure scan half-width in ship orbits (default 12)
//     SCAN_TOF_RANGE      TOF scan half-width as fraction of Hohmann TOF (default 0.35)
//     SCAN_TIME_STEPS     departure grid steps (default 18)
//     SCAN_TOF_STEPS      TOF grid steps (default 10)
//     REFINE_ITER         hillclimb max iterations (default 40)
//     MAX_DV_RATIO        reject Lambert cells with dV > ratio×Hohmann (default 4.0)
//
// Returns: maneuver node, or 0 on failure.
// ============================================================
GLOBAL FUNCTION planLocalXfer {
    PARAMETER targetBody.
    PARAMETER opts IS LEXICON().

    LOCAL centralBody IS BODY.
    LOCAL mu          IS centralBody:MU.

    LOCAL targetPe  IS CHOOSE opts["CAPTURE_PE"]  IF opts:HASKEY("CAPTURE_PE")  ELSE 10000.
    LOCAL captureInc IS CHOOSE opts["CAPTURE_INC"] IF opts:HASKEY("CAPTURE_INC") ELSE -1.
    LOCAL lanTarget  IS CHOOSE opts["CAPTURE_LAN"] IF opts:HASKEY("CAPTURE_LAN") ELSE -1.
    LOCAL aopTarget  IS CHOOSE opts["CAPTURE_AOP"] IF opts:HASKEY("CAPTURE_AOP") ELSE -1.

    LOCAL scanTimeOrbits IS CHOOSE opts["SCAN_TIME_ORBITS"] IF opts:HASKEY("SCAN_TIME_ORBITS") ELSE 12.
    LOCAL scanTofRange   IS CHOOSE opts["SCAN_TOF_RANGE"]   IF opts:HASKEY("SCAN_TOF_RANGE")   ELSE 0.35.
    LOCAL scanTimeSteps  IS CHOOSE opts["SCAN_TIME_STEPS"]  IF opts:HASKEY("SCAN_TIME_STEPS")  ELSE 18.
    LOCAL scanTofSteps   IS CHOOSE opts["SCAN_TOF_STEPS"]   IF opts:HASKEY("SCAN_TOF_STEPS")   ELSE 10.
    LOCAL refineIter     IS CHOOSE opts["REFINE_ITER"]      IF opts:HASKEY("REFINE_ITER")      ELSE 40.
    LOCAL maxDvRatio     IS CHOOSE opts["MAX_DV_RATIO"]     IF opts:HASKEY("MAX_DV_RATIO")     ELSE 4.0.

    LOCAL shipPeriod   IS SHIP:ORBIT:PERIOD.
    LOCAL targetPeriod IS targetBody:ORBIT:PERIOD.

    // ---- Hohmann seed ----
    LOCAL rShip   IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL rTarget IS targetBody:ORBIT:SEMIMAJORAXIS.
    LOCAL hohmannA   IS (rShip + rTarget) / 2.
    LOCAL hohmannTof IS CONSTANT:PI * SQRT(hohmannA^3 / mu).
    LOCAL vShip      IS SQRT(mu / rShip).
    LOCAL vDepart    IS SQRT(mu * (2/rShip - 1/hohmannA)).
    LOCAL hohmannDv  IS vDepart - vShip.

    mLog("planLocalXfer " + targetBody:NAME
        + " Hohmann dV=" + ROUND(hohmannDv,1) + " m/s"
        + " TOF=" + ROUND(hohmannTof/3600,2) + "hr"
        + " Pe=" + ROUND(targetPe/1000,1) + "km"
        + CHOOSE " INC=" + ROUND(captureInc,1) IF captureInc >= 0 ELSE ""
        + CHOOSE " LAN=" + ROUND(lanTarget,1) IF lanTarget >= 0 ELSE ""
        + CHOOSE " AOP=" + ROUND(aopTarget,1) IF aopTarget >= 0 ELSE "").

    // ---- Phase angle estimate for seed departure time ----
    LOCAL targetMeanMotion IS 360 / targetPeriod.
    LOCAL idealPhaseAngle  IS 180 - targetMeanMotion * hohmannTof.
    SET TARGET TO targetBody.
    WAIT 0.1.
    LOCAL currentPhase IS phaseAngle().
    LOCAL synodicPeriod IS ABS(shipPeriod * targetPeriod / (shipPeriod - targetPeriod)).
    LOCAL phaseDiff IS idealPhaseAngle - currentPhase.
    IF phaseDiff < 0 { SET phaseDiff TO phaseDiff + 360. }
    LOCAL relativeRate IS (360 / shipPeriod) - (360 / targetPeriod).
    LOCAL seedWait IS phaseDiff / ABS(relativeRate).
    IF seedWait < 60 { SET seedWait TO seedWait + synodicPeriod. }
    LOCAL seedDepartUt IS TIME:SECONDS + seedWait.

    mLog("Phase seed: current=" + ROUND(currentPhase,1)
        + " ideal=" + ROUND(idealPhaseAngle,1)
        + " wait=" + ROUND(seedWait,0) + "s").

    // Place a placeholder node (will be replaced by porkchop)
    LOCAL nd IS NODE(seedDepartUt, 0, 0, hohmannDv).
    ADD nd.
    WAIT 0.1.

    // ---- Stage 1: Porkchop grid scan ----
    // Scan a 2D grid over departure_time × TOF.
    // Lambert dV is computed analytically for each cell; the node is placed
    // only to read KSP's patched-conic elements for scoring.
    LOCAL tofMin  IS hohmannTof * (1.0 - scanTofRange).
    LOCAL tofMax  IS hohmannTof * (1.0 + scanTofRange).
    LOCAL tofStep IS (tofMax - tofMin) / MAX(1, scanTofSteps - 1).
    LOCAL timeStep IS shipPeriod / MAX(1, scanTimeSteps).
    LOCAL halfT    IS FLOOR(scanTimeOrbits * scanTimeSteps / 2).
    LOCAL maxDv    IS hohmannDv * maxDvRatio.

    LOCAL bestCost    IS 9e15.
    LOCAL bestDepart  IS seedDepartUt.
    LOCAL bestTof     IS hohmannTof.
    LOCAL bestDvPro   IS hohmannDv.
    LOCAL bestDvNorm  IS 0.
    LOCAL bestDvRad   IS 0.
    LOCAL totalEvals  IS 0.
    LOCAL hitCount    IS 0.

    mLog("Porkchop: " + (2 * halfT + 1) + "×" + scanTofSteps + " grid"
        + " T±" + ROUND(halfT * timeStep / 3600, 1) + "hr"
        + " TOF " + ROUND(tofMin/3600,2) + "-" + ROUND(tofMax/3600,2) + "hr").

    FROM { LOCAL ti IS -halfT. } UNTIL ti <= halfT STEP { SET ti TO ti + 1. } DO {
        LOCAL tryDepart IS seedDepartUt + ti * timeStep.
        IF tryDepart > TIME:SECONDS + 60 {
            FROM { LOCAL tfi IS 0. } UNTIL tfi < scanTofSteps STEP { SET tfi TO tfi + 1. } DO {
                LOCAL tryTof IS tofMin + tfi * tofStep.
                LOCAL dv IS _xlLambertDv(tryDepart, tryDepart + tryTof, targetBody, centralBody, mu).
                IF dv["OK"] AND ABS(dv["PRO"]) < maxDv {
                    SET nd:TIME     TO tryDepart.
                    SET nd:PROGRADE TO dv["PRO"].
                    SET nd:NORMAL   TO dv["NORM"].
                    SET nd:RADIALOUT TO dv["RAD"].
                    WAIT 0.02.
                    SET totalEvals TO totalEvals + 1.
                    LOCAL patch IS _getTargetPatch(nd, targetBody).
                    IF patch <> 0 {
                        SET hitCount TO hitCount + 1.
                        LOCAL cost IS _xlCost(patch, targetPe, captureInc, lanTarget, aopTarget, nd:DELTAV:MAG).
                        IF cost < bestCost {
                            SET bestCost   TO cost.
                            SET bestDepart TO tryDepart.
                            SET bestTof    TO tryTof.
                            SET bestDvPro  TO dv["PRO"].
                            SET bestDvNorm TO dv["NORM"].
                            SET bestDvRad  TO dv["RAD"].
                        }
                    }
                }
            }
        }
    }

    mLog("Porkchop: " + hitCount + "/" + totalEvals + " encounters"
        + " bestCost=" + ROUND(bestCost,2)
        + " departT+" + ROUND(bestDepart - TIME:SECONDS,0) + "s"
        + " TOF=" + ROUND(bestTof/3600,2) + "hr").

    IF hitCount = 0 {
        mLogError("planLocalXfer: no encounter in porkchop grid — aborting.").
        IF HASNODE { REMOVE nd. }
        RETURN 0.
    }

    // Restore best
    SET nd:TIME     TO bestDepart.
    SET nd:PROGRADE TO bestDvPro.
    SET nd:NORMAL   TO bestDvNorm.
    SET nd:RADIALOUT TO bestDvRad.
    WAIT 0.1.

    // ---- Stage 2: 2D hillclimb in (departure_time, TOF) ----
    LOCAL hillDepart  IS bestDepart.
    LOCAL hillTof     IS bestTof.
    LOCAL hillCost    IS bestCost.
    LOCAL hillTimeStep IS timeStep / 2.
    LOCAL hillTofStep  IS tofStep / 2.
    LOCAL hillMinTime  IS 20.
    LOCAL hillMinTof   IS 30.

    mLog("Hillclimb 2D: initStep T=" + ROUND(hillTimeStep,0) + "s"
        + " TOF=" + ROUND(hillTofStep,0) + "s").

    FROM { LOCAL hi IS 0. } UNTIL hi >= refineIter STEP { SET hi TO hi + 1. } DO {
        LOCAL improved IS FALSE.
        LOCAL dirs IS LIST(
            LEXICON("DT", -hillTimeStep, "DTOF", 0),
            LEXICON("DT",  hillTimeStep, "DTOF", 0),
            LEXICON("DT", 0, "DTOF", -hillTofStep),
            LEXICON("DT", 0, "DTOF",  hillTofStep)
        ).
        FOR dir IN dirs {
            LOCAL tryDepart IS hillDepart + dir["DT"].
            LOCAL tryTof    IS hillTof    + dir["DTOF"].
            IF tryDepart > TIME:SECONDS + 60 AND tryTof > 120 {
                LOCAL dv IS _xlLambertDv(tryDepart, tryDepart + tryTof, targetBody, centralBody, mu).
                IF dv["OK"] AND ABS(dv["PRO"]) < maxDv {
                    SET nd:TIME     TO tryDepart.
                    SET nd:PROGRADE TO dv["PRO"].
                    SET nd:NORMAL   TO dv["NORM"].
                    SET nd:RADIALOUT TO dv["RAD"].
                    WAIT 0.02.
                    LOCAL patch IS _getTargetPatch(nd, targetBody).
                    IF patch <> 0 {
                        LOCAL tryCost IS _xlCost(patch, targetPe, captureInc, lanTarget, aopTarget, nd:DELTAV:MAG).
                        IF tryCost < hillCost {
                            SET hillCost   TO tryCost.
                            SET hillDepart TO tryDepart.
                            SET hillTof    TO tryTof.
                            SET improved   TO TRUE.
                        }
                    }
                }
            }
        }

        // Restore current best after each round
        LOCAL dvBest IS _xlLambertDv(hillDepart, hillDepart + hillTof, targetBody, centralBody, mu).
        IF dvBest["OK"] {
            SET nd:TIME     TO hillDepart.
            SET nd:PROGRADE TO dvBest["PRO"].
            SET nd:NORMAL   TO dvBest["NORM"].
            SET nd:RADIALOUT TO dvBest["RAD"].
            WAIT 0.02.
        }

        IF NOT improved {
            SET hillTimeStep TO hillTimeStep / 2.
            SET hillTofStep  TO hillTofStep  / 2.
            IF hillTimeStep < hillMinTime AND hillTofStep < hillMinTof { BREAK. }
        }
    }

    LOCAL hillPatch IS _getTargetPatch(nd, targetBody).
    mLog("Hillclimb done: cost=" + ROUND(hillCost,2)
        + " departT+" + ROUND(nd:TIME - TIME:SECONDS,0) + "s"
        + " TOF=" + ROUND(hillTof/3600,2) + "hr"
        + " dV=" + ROUND(nd:DELTAV:MAG,1) + " m/s"
        + CHOOSE " Pe=" + ROUND(hillPatch:PERIAPSIS/1000,1) + "km" IF hillPatch <> 0 ELSE " (no patch)").
    IF hillPatch <> 0 {
        mLogWarn("STATS xfer-local hillclimb target=" + targetBody:NAME
            + " Pe=" + ROUND(hillPatch:PERIAPSIS/1000,1)
            + " INC=" + ROUND(hillPatch:INCLINATION,1)
            + " LAN=" + ROUND(hillPatch:LAN,1)
            + " AOP=" + ROUND(hillPatch:ARGUMENTOFPERIAPSIS,1)
            + " dV=" + ROUND(nd:DELTAV:MAG,1)).
    }

    // ---- Stage 3: PE polish via Newton ----
    newtonTarget(nd, targetBody, "PE", targetPe).

    // ---- Stage 4: INC polish via Newton ----
    IF captureInc >= 0 {
        newtonTarget(nd, targetBody, "INC", captureInc).
    }

    // ---- Stage 5: LAN — slide departure by ship orbital periods ----
    IF lanTarget >= 0 {
        LOCAL lanTol IS 0.5.
        IF CFG:HASKEY("LAN_ERR_TOL") { SET lanTol TO CFG["LAN_ERR_TOL"]. }
        LOCAL curPatch IS _getTargetPatch(nd, targetBody).
        LOCAL curLanErr IS 999.
        IF curPatch <> 0 {
            SET curLanErr TO ABS(_angleError(curPatch:LAN, lanTarget)).
        }
        IF curLanErr > lanTol {
            SET nd TO _xlLanOrbitScan(nd, targetBody, lanTarget, hillDepart, hillTof, shipPeriod, centralBody, mu, maxDv).
        } ELSE {
            mLog("LAN already within tolerance err=" + ROUND(curLanErr,2) + "°").
        }
    }

    // ---- Stage 6: AOP — narrow TOF scan around current best ----
    IF aopTarget >= 0 {
        LOCAL aopTol IS 15.
        IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }
        LOCAL curPatch IS _getTargetPatch(nd, targetBody).
        LOCAL curAopErr IS 999.
        IF curPatch <> 0 {
            SET curAopErr TO ABS(_angleError(curPatch:ARGUMENTOFPERIAPSIS, aopTarget)).
        }
        IF curAopErr > aopTol {
            SET nd TO _xlAopTofScan(nd, targetBody, aopTarget, nd:TIME, hillTof, centralBody, mu, maxDv).
        } ELSE {
            mLog("AOP already within tolerance err=" + ROUND(curAopErr,2) + "°").
        }
    }

    // ---- Stage 7: Final coupled polish ----
    LOCAL finalTargets IS LEXICON().
    finalTargets:ADD("PE", targetPe).
    finalTargets:ADD("PE_FLOOR", -25000).
    IF captureInc >= 0 { finalTargets:ADD("INC", captureInc). }
    IF lanTarget  >= 0 { finalTargets:ADD("LAN", lanTarget). }
    IF aopTarget  >= 0 { finalTargets:ADD("AOP", aopTarget). }

    LOCAL finalOpts IS LEXICON().
    finalOpts:ADD("STEP_PROGRADE", 5.0).
    finalOpts:ADD("STEP_NORMAL", 5.0).
    finalOpts:ADD("STEP_RADIAL", 5.0).
    finalOpts:ADD("STEP_TIME", 30.0).
    finalOpts:ADD("MIN_STEP", 0.05).
    finalOpts:ADD("MAX_ITER", 80).
    _targetPatchElementsCoupled(nd, targetBody, finalTargets, finalOpts).

    // ---- Final report ----
    LOCAL finalPatch IS _getTargetPatch(nd, targetBody).
    IF finalPatch = 0 {
        mLogError("planLocalXfer: lost encounter in final polish.").
        IF HASNODE { REMOVE nd. }
        RETURN 0.
    }

    mLog("planLocalXfer result:"
        + " dV=" + ROUND(nd:DELTAV:MAG,1) + " m/s"
        + " Pe=" + ROUND(finalPatch:PERIAPSIS/1000,1) + "km"
        + " INC=" + ROUND(finalPatch:INCLINATION,1) + "°"
        + " LAN=" + ROUND(finalPatch:LAN,1) + "°"
        + " AOP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1) + "°"
        + " departT+" + ROUND(nd:TIME - TIME:SECONDS,0) + "s").
    mLogWarn("STATS xfer-local result target=" + targetBody:NAME
        + " dV=" + ROUND(nd:DELTAV:MAG,1)
        + " PeKm=" + ROUND(finalPatch:PERIAPSIS/1000,1)
        + " INC=" + ROUND(finalPatch:INCLINATION,1)
        + " LAN=" + ROUND(finalPatch:LAN,1)
        + " AOP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).

    RETURN nd.
}

// ============================================================
// _xlLambertDv — compute Lambert departure dV decomposed into
// the kOS maneuver node frame (prograde / normal / radial) at
// the departure time. Returns LEXICON with OK, PRO, NORM, RAD.
//
// Frame at departure:
//   prograde = velocity direction (v / |v|)
//   normal   = angular momentum direction ((r × v) / |r × v|)
//   radial   = prograde × normal  (≈ radially outward, exact for circular)
//
// For a near-circular parking orbit all three are orthonormal so the
// dot-product decomposition is exact. This matches kOS nd:PROGRADE /
// nd:NORMAL / nd:RADIALOUT and RSVP's maneuver_node_vector_projection.
// ============================================================
LOCAL FUNCTION _xlLambertDv {
    PARAMETER departUt.
    PARAMETER arrivalUt.
    PARAMETER targetBody.
    PARAMETER centralBody.
    PARAMETER mu.

    IF arrivalUt <= departUt + 30 { RETURN LEXICON("OK", FALSE). }

    LOCAL tof IS arrivalUt - departUt.
    LOCAL r1  IS POSITIONAT(SHIP, departUt)   - centralBody:POSITION.
    LOCAL r2  IS POSITIONAT(targetBody, arrivalUt) - centralBody:POSITION.
    LOCAL v1  IS VELOCITYAT(SHIP, departUt):ORBIT.

    // Guard: both positions must be non-zero
    IF r1:MAG < 1 OR r2:MAG < 1 { RETURN LEXICON("OK", FALSE). }

    LOCAL sol IS lambertSolve(r1, r2, tof, mu, FALSE).
    LOCAL dvVec IS sol["v1"] - v1.

    // Frenet frame at departure (matches kOS node frame for circular orbit)
    LOCAL progrHat IS v1:NORMALIZED.
    LOCAL hVec     IS VCRS(r1, v1).
    IF hVec:MAG < 1e-6 { RETURN LEXICON("OK", FALSE). }
    LOCAL normalHat IS hVec:NORMALIZED.
    LOCAL radialHat IS VCRS(progrHat, normalHat):NORMALIZED.

    RETURN LEXICON(
        "OK",   TRUE,
        "PRO",  VDOT(dvVec, progrHat),
        "NORM", VDOT(dvVec, normalHat),
        "RAD",  VDOT(dvVec, radialHat),
        "MAG",  dvVec:MAG
    ).
}

// ============================================================
// _xlCost — element-weighted cost function for scoring porkchop
// candidates. All terms are dimensionless and comparable in scale.
// ============================================================
LOCAL FUNCTION _xlCost {
    PARAMETER patch.
    PARAMETER targetPe.
    PARAMETER captureInc.
    PARAMETER lanTarget.
    PARAMETER aopTarget.
    PARAMETER dvMag.

    IF patch = 0 { RETURN 9e15. }

    LOCAL cost IS 0.

    // PE: 5 km scale → 5km error = cost 1
    LOCAL peErr IS (patch:PERIAPSIS - targetPe) / 5000.
    SET cost TO cost + peErr^2.

    // INC: 2° scale
    IF captureInc >= 0 {
        LOCAL incErr IS _angleError(patch:INCLINATION, captureInc).
        SET cost TO cost + (incErr / 2.0)^2.
    }

    // LAN: 3° scale with bonus penalty beyond 5°
    IF lanTarget >= 0 {
        LOCAL lanErr IS _angleError(patch:LAN, lanTarget).
        SET cost TO cost + (lanErr / 3.0)^2.
        IF ABS(lanErr) > 5 { SET cost TO cost + ((ABS(lanErr) - 5) / 2.0)^2. }
    }

    // AOP: 5° scale with bonus penalty beyond 15°
    IF aopTarget >= 0 {
        LOCAL aopErr IS _angleError(patch:ARGUMENTOFPERIAPSIS, aopTarget).
        SET cost TO cost + (aopErr / 5.0)^2.
        IF ABS(aopErr) > 15 { SET cost TO cost + ((ABS(aopErr) - 15) / 3.0)^2. }
    }

    // Light dV penalty (keeps solver from drifting to identical-cost high-dV solutions)
    SET cost TO cost + dvMag * 0.0005.

    RETURN cost.
}

// ============================================================
// _xlLanOrbitScan — find the departure orbit (multiple of ship
// period from current best) that minimises LAN error at the
// target body. Keeps TOF fixed so AOP is not disturbed.
// ============================================================
LOCAL FUNCTION _xlLanOrbitScan {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER lanTarget.
    PARAMETER curDepart.
    PARAMETER curTof.
    PARAMETER shipPeriod.
    PARAMETER centralBody.
    PARAMETER mu.
    PARAMETER maxDv.

    LOCAL nScan IS MAX(6, CEILING(targetBody:ORBIT:PERIOD / shipPeriod)).
    LOCAL bestLanErr IS 999.
    LOCAL bestDepart IS curDepart.
    LOCAL bestDvPro  IS nd:PROGRADE.
    LOCAL bestDvNorm IS nd:NORMAL.
    LOCAL bestDvRad  IS nd:RADIALOUT.

    LOCAL lanTol IS 0.5.
    IF CFG:HASKEY("LAN_ERR_TOL") { SET lanTol TO CFG["LAN_ERR_TOL"]. }

    mLog("LAN orbit scan: ±" + nScan + " orbits, target=" + ROUND(lanTarget,1) + "°").

    FROM { LOCAL oi IS -nScan. } UNTIL oi <= nScan STEP { SET oi TO oi + 1. } DO {
        LOCAL tryDepart IS curDepart + oi * shipPeriod.
        IF tryDepart > TIME:SECONDS + 60 {
            LOCAL dv IS _xlLambertDv(tryDepart, tryDepart + curTof, targetBody, centralBody, mu).
            IF dv["OK"] AND ABS(dv["PRO"]) < maxDv {
                SET nd:TIME     TO tryDepart.
                SET nd:PROGRADE TO dv["PRO"].
                SET nd:NORMAL   TO dv["NORM"].
                SET nd:RADIALOUT TO dv["RAD"].
                WAIT 0.02.
                LOCAL patch IS _getTargetPatch(nd, targetBody).
                IF patch <> 0 {
                    LOCAL lanErr IS ABS(_angleError(patch:LAN, lanTarget)).
                    IF lanErr < bestLanErr {
                        SET bestLanErr TO lanErr.
                        SET bestDepart TO tryDepart.
                        SET bestDvPro  TO dv["PRO"].
                        SET bestDvNorm TO dv["NORM"].
                        SET bestDvRad  TO dv["RAD"].
                        mLog("  LAN[" + oi + "] err=" + ROUND(lanErr,1)
                            + "° LAN=" + ROUND(patch:LAN,1)
                            + "° depart T+" + ROUND(tryDepart - TIME:SECONDS,0) + "s").
                    }
                }
            }
        }
    }

    SET nd:TIME     TO bestDepart.
    SET nd:PROGRADE TO bestDvPro.
    SET nd:NORMAL   TO bestDvNorm.
    SET nd:RADIALOUT TO bestDvRad.
    WAIT 0.1.

    mLog("LAN scan done: err=" + ROUND(bestLanErr,1) + "°"
        + " depart T+" + ROUND(nd:TIME - TIME:SECONDS,0) + "s").
    mLogWarn("STATS xfer-local lan-scan target=" + targetBody:NAME
        + " target=" + ROUND(lanTarget,1) + " err=" + ROUND(bestLanErr,1)).

    RETURN nd.
}

// ============================================================
// _xlAopTofScan — fine-tune AOP by scanning TOF around the
// current best, keeping departure time fixed. AOP changes with
// TOF because it changes the direction of approach to the body.
// ============================================================
LOCAL FUNCTION _xlAopTofScan {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER aopTarget.
    PARAMETER curDepart.
    PARAMETER curTof.
    PARAMETER centralBody.
    PARAMETER mu.
    PARAMETER maxDv.

    // Scan ±20% of current TOF in 20 steps
    LOCAL scanFrac IS 0.20.
    LOCAL nSteps   IS 20.
    LOCAL tofRange IS curTof * scanFrac.
    LOCAL tofStep  IS tofRange * 2 / nSteps.

    LOCAL aopTol IS 15.
    IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }

    LOCAL bestAopErr IS 999.
    LOCAL curPatch IS _getTargetPatch(nd, targetBody).
    IF curPatch <> 0 {
        SET bestAopErr TO ABS(_angleError(curPatch:ARGUMENTOFPERIAPSIS, aopTarget)).
    }
    LOCAL bestTof    IS curTof.
    LOCAL bestDvPro  IS nd:PROGRADE.
    LOCAL bestDvNorm IS nd:NORMAL.
    LOCAL bestDvRad  IS nd:RADIALOUT.

    mLog("AOP TOF scan: ±" + ROUND(tofRange/3600,2) + "hr around TOF="
        + ROUND(curTof/3600,2) + "hr  target=" + ROUND(aopTarget,1) + "°").

    FROM { LOCAL si IS 0. } UNTIL si <= nSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTof IS curTof - tofRange + si * tofStep.
        IF tryTof > 120 {
            LOCAL dv IS _xlLambertDv(curDepart, curDepart + tryTof, targetBody, centralBody, mu).
            IF dv["OK"] AND ABS(dv["PRO"]) < maxDv {
                SET nd:TIME     TO curDepart.
                SET nd:PROGRADE TO dv["PRO"].
                SET nd:NORMAL   TO dv["NORM"].
                SET nd:RADIALOUT TO dv["RAD"].
                WAIT 0.02.
                LOCAL patch IS _getTargetPatch(nd, targetBody).
                IF patch <> 0 {
                    LOCAL aopErr IS ABS(_angleError(patch:ARGUMENTOFPERIAPSIS, aopTarget)).
                    IF aopErr < bestAopErr {
                        SET bestAopErr TO aopErr.
                        SET bestTof    TO tryTof.
                        SET bestDvPro  TO dv["PRO"].
                        SET bestDvNorm TO dv["NORM"].
                        SET bestDvRad  TO dv["RAD"].
                    }
                }
            }
        }
    }

    SET nd:TIME     TO curDepart.
    SET nd:PROGRADE TO bestDvPro.
    SET nd:NORMAL   TO bestDvNorm.
    SET nd:RADIALOUT TO bestDvRad.
    WAIT 0.1.

    mLog("AOP scan done: err=" + ROUND(bestAopErr,1) + "°"
        + " TOF=" + ROUND(bestTof/3600,2) + "hr").
    mLogWarn("STATS xfer-local aop-scan target=" + targetBody:NAME
        + " target=" + ROUND(aopTarget,1) + " err=" + ROUND(bestAopErr,1)).

    RETURN nd.
}
