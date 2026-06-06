// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
// ============================================================

LOCAL COMPLETE_FRAC        IS 0.001.
LOCAL ABS_CUTOFF           IS 0.0001.
LOCAL ALIGN_TOLERANCE      IS 2.0.
LOCAL HIBERNATE_THRESHOLD  IS 300.
LOCAL HIBERNATE_WAKE_LEAD  IS 180.
LOCAL MCC_DV_CAP           IS 120.

GLOBAL FUNCTION executeManeuver {
    WAIT 0.1.
    IF NOT HASNODE {
        mLogError("executeManeuver: no node on flight plan.").
        HUDTEXT("ERROR: No maneuver node!", 5, 2, 18, RED, FALSE).
        RETURN FALSE.
    }

    LOCAL nd    IS NEXTNODE.
    LOCAL burnDV  IS nd:DELTAV:MAG.
    LOCAL startTime IS _calcStartTime(nd).

    IF burnDV < 10 { _setThrustLimit(0.25). }
    IF burnDV < 2  { _setThrustLimit(0.10). }
    IF burnDV < 0.5 { _setThrustLimit(0.05). }

    IF startTime < TIME:SECONDS {
        mLogWarn("Burn window already passed by " + ROUND(TIME:SECONDS - startTime, 0) + "s — removing node.").
        HUDTEXT("Burn window missed — replanning", 5, 2, 15, YELLOW, FALSE).
        REMOVE nd.
        RETURN FALSE.
    }

    mLog("Maneuver: dV=" + ROUND(burnDV,1) + " m/s  ETA=" + ROUND(startTime - TIME:SECONDS,1) + "s").

    // Set a KAC alarm to kill warp before the burn starts.
    // Alarm fires 60s before burn start to allow alignment time.
    LOCAL kacAlarmId IS "".
    IF ADDONS:KAC:AVAILABLE {
        LOCAL alarmUt IS startTime - 60.
        IF alarmUt > TIME:SECONDS {
            LOCAL alm IS ADDALARM("Raw", alarmUt, "Burn: " + ROUND(burnDV,1) + "m/s", "Auto-created by executeManeuver").
            SET alm:ACTION TO "KillWarp".
            SET kacAlarmId TO alm:ID.
            mLog("KAC alarm set for burn in " + ROUND(alarmUt - TIME:SECONDS, 0) + "s.").
        }
    }

    SET SAS TO FALSE.
    WAIT 0.1.
    LOCK STEERING TO nd:BURNVECTOR.
    mLog("Aligning to burn vector...").

    LOCAL wakeTime IS startTime - HIBERNATE_WAKE_LEAD.
    IF TIME:SECONDS < wakeTime - HIBERNATE_THRESHOLD {
        mLog("Hibernating for coast (" + ROUND(wakeTime - TIME:SECONDS, 0) + "s).").
        HUDTEXT("Hibernated. Burn in " + ROUND(startTime - TIME:SECONDS, 0) + "s", 5, 2, 13, CYAN, FALSE).
        _hibernateCmd().
        WAIT MAX(0, wakeTime - TIME:SECONDS).
        _wakeCmd().
        SET WARP TO 0.
        mLog("Awake — " + ROUND(startTime - TIME:SECONDS, 0) + "s to burn.").
        HUDTEXT("Core awake — burn in " + ROUND(startTime - TIME:SECONDS, 0) + "s", 5, 2, 13, GREEN, FALSE).
    }

    WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ALIGN_TOLERANCE
            OR TIME:SECONDS >= (startTime - 30).

    IF VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) >= ALIGN_TOLERANCE {
        mLogWarn("Burn starting with " + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR),1) + "° misalignment.").
    } ELSE {
        mLog("Aligned. Waiting for burn window...").
    }

    WAIT UNTIL TIME:SECONDS >= (startTime - 10).
    HUDTEXT("Burn in T-10", 3, 2, 15, WHITE, FALSE).
    countdown(9).

    WAIT UNTIL TIME:SECONDS >= startTime.
    mLog("Burn start. dV=" + ROUND(burnDV,1) + " m/s").

    LOCAL origBurnVec IS nd:BURNVECTOR.

    UNTIL _isComplete(nd, burnDV) {
        LOCK STEERING TO nd:BURNVECTOR.

        IF _needsStage() {
            HUDTEXT("Staging!", 2, 2, 15, YELLOW, FALSE).
            mLog("Auto-stage triggered.").
            LOCK THROTTLE TO 0.
            WAIT 0.3.
            STAGE.
            WAIT 0.7.
        }

        LOCAL remaining IS nd:DELTAV:MAG.
        LOCAL maxAcc    IS _safeMaxAcc().
        LOCAL dotCheck IS VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED).

        IF dotCheck < 0 { LOCK THROTTLE TO 0. BREAK. }

        IF remaining > 5.0 {
            LOCK THROTTLE TO 1.0.
        } ELSE IF remaining > 0.5 {
            LOCAL timeToStop IS remaining / maxAcc.
            LOCK THROTTLE TO MAX(0.02, MIN(0.5, timeToStop)).
        } ELSE IF remaining >= 0.04 {
            LOCK THROTTLE TO 0.01.
        } ELSE {
            LOCK THROTTLE TO 0.
            BREAK.
        }
        WAIT 0.01.
    }

    LOCAL residual IS nd:DELTAV:MAG.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    REMOVE nd.
    SET SAS TO TRUE.
    _setThrustLimit(1.0).

    // Clean up the KAC alarm now that the burn is done.
    IF kacAlarmId <> "" {
        DELETEALARM(kacAlarmId).
    }

    mLog("Burn complete. Residual dV ~" + ROUND(residual, 2) + " m/s.").
    HUDTEXT("Burn complete", 3, 2, 15, GREEN, FALSE).
    RETURN TRUE.
}

LOCAL FUNCTION _setThrustLimit {
    PARAMETER pct.
    FOR eng IN SHIP:ENGINES {
        SET eng:THRUSTLIMIT TO pct * 100.
    }
}

GLOBAL FUNCTION planCircularize {
    LOCAL etaApo IS ETA:APOAPSIS.
    LOCAL mu  IS SHIP:ORBIT:BODY:MU.
    LOCAL vCirc IS SQRT(mu / (SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS)).
    LOCAL vNow  IS VELOCITYAT(SHIP, TIME:SECONDS + etaApo):ORBIT:MAG.
    LOCAL dv    IS vCirc - vNow.

    LOCAL nd IS NODE(TIME:SECONDS + etaApo, 0, 0, dv).
    ADD nd.
    mLog("Circularize node: dV=" + ROUND(dv,1) + " m/s at Ap in " + ROUND(etaApo,0) + "s").
    RETURN nd.
}

LOCAL FUNCTION _findEncounter {
    PARAMETER testNode.
    PARAMETER targetBody.
    PARAMETER centerTime.
    PARAMETER searchRadius.
    PARAMETER step.

    LOCAL offset IS 0.
    UNTIL offset > searchRadius {
        LOCAL tryTimes IS LIST(centerTime + offset).
        IF offset > 0 { tryTimes:ADD(centerTime - offset). }
        FOR t IN tryTimes {
            IF t > TIME:SECONDS + 30 {
                SET testNode:TIME TO t.
                WAIT 0.02.
                LOCAL patch IS _getTargetPatch(testNode, targetBody).
                IF patch <> 0 AND patch:PERIAPSIS > 0 {
                    RETURN t.
                }
            }
        }
        SET offset TO offset + step.
    }
    RETURN -1.
}

// ============================================================
// planTransfer — plan a transfer burn to targetBody.
//
// Pipeline:
//   1. Build raw node  (_planLocalTransfer or _planInterplanetaryTransfer)
//      Local:  Hohmann dV + phase angle timing, prograde-only, no Lambert
//      Interplanetary:  Lambert grid scan, full 3-axis node
//   2. Validate encounter via KSP patched conics (_findEncounter)
//   3. Optional LAN scan (_scanForLan) — slide departure across orbits
//   4. Newton PE targeting (_newtonPeTarget) — prograde dV
//   5. Newton INC targeting (_newtonIncTarget) — normal dV, if CAPTURE_DIR set
//   6. PE cleanup — re-run PE to correct drift from normal changes
//
// CFG keys consumed:
//   CAPTURE_DIR  — "PROGRADE" / "POLAR" / "RETROPOLAR" / "RETROGRADE"
//   CAPTURE_INC  — explicit inclination (overrides CAPTURE_DIR)
//   LAN_ERR_TOL  — LAN tolerance for scan (default 0.5°)
// ============================================================
GLOBAL FUNCTION planTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER lanTarget IS -1.
    PARAMETER aopTarget IS -1.

    LOCAL centralBody IS BODY.
    LOCAL mu          IS centralBody:MU.

    LOCAL isLocal IS (targetBody:BODY = BODY).

    LOCAL nd IS 0.
    IF isLocal {
        SET nd TO _planLocalTransfer(targetBody, targetPe, lanTarget, centralBody, mu).
    } ELSE {
        SET nd TO _planInterplanetaryTransfer(targetBody, targetPe, lanTarget, centralBody, mu).
    }

    IF nd = 0 OR NOT nd:ISTYPE("Node") { RETURN. }

    // --- Resolve orbit direction from CFG ---
    // CAPTURE_DIR: high-level orbit type (PROGRADE, POLAR, RETROPOLAR, RETROGRADE)
    // CAPTURE_INC: overrides CAPTURE_DIR with an exact inclination value
    LOCAL captureInc IS -1.
    LOCAL normalBias IS 0.
    IF CFG:HASKEY("CAPTURE_DIR") {
        LOCAL dir IS CFG["CAPTURE_DIR"]:TOUPPER.
        IF dir = "PROGRADE"   { SET captureInc TO 0. }
        IF dir = "POLAR"      { SET captureInc TO 90.  SET normalBias TO 1. }
        IF dir = "RETROPOLAR" { SET captureInc TO 90.  SET normalBias TO -1. }
        IF dir = "RETROGRADE" { SET captureInc TO 180. }
    }
    IF CFG:HASKEY("CAPTURE_INC") { SET captureInc TO CFG["CAPTURE_INC"]. }

    // --- Newton-Raphson PE targeting ---
    newtonTarget(nd, targetBody, "PE", targetPe).

    // --- Inclination targeting ---
    // normalBias seeds the solver: +1 prograde-side polar,
    // -1 retrograde-side polar (different LAN via opposite normal dV).
    IF captureInc >= 0 {
        LOCAL incOpts IS LEXICON().
        IF normalBias <> 0 { incOpts:ADD("BIAS", normalBias * 5). }
        newtonTarget(nd, targetBody, "INC", captureInc, incOpts).
        // Re-run PE to correct drift from normal dV changes
        newtonTarget(nd, targetBody, "PE", targetPe).
    }

    // --- Final report ---
    LOCAL finalPatch IS _getTargetPatch(nd, targetBody).
    IF finalPatch = 0 {
        mLogError("planTransfer: no encounter after targeting.").
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
    }
    mLog(logMsg).
    RETURN nd.
}

// ============================================================
// Local transfer (Mun, Minmus) — Hohmann + conic validation
// Prograde-only, no Lambert solver needed.
// ============================================================
LOCAL FUNCTION _planLocalTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER lanTarget.
    PARAMETER centralBody.
    PARAMETER mu.

    LOCAL shipPeriod IS SHIP:ORBIT:PERIOD.
    LOCAL targetPeriod IS targetBody:ORBIT:PERIOD.

    // --- Hohmann estimate ---
    // vis-viva: dV to raise apoapsis from current orbit to target orbit
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

    // --- Phase angle for Hohmann intercept ---
    // The ideal phase angle is 180° minus the angle the target sweeps during TOF
    LOCAL targetMeanMotion IS 360 / targetPeriod.
    LOCAL targetSweep IS targetMeanMotion * hohmannTof.
    LOCAL idealPhaseAngle IS 180 - targetSweep.

    // Compute current phase angle using lib_navigation
    // phaseAngle() requires TARGET to be set
    SET TARGET TO targetBody.
    WAIT 0.1.
    LOCAL currentPhase IS phaseAngle().

    // Synodic period — how often the phase angle repeats
    LOCAL synodicPeriod IS ABS(1 / (1/shipPeriod - 1/targetPeriod)) * shipPeriod.

    // Time until the phase angle is right
    LOCAL phaseDiff IS idealPhaseAngle - currentPhase.
    IF phaseDiff < 0 { SET phaseDiff TO phaseDiff + 360. }
    LOCAL shipAngRate IS 360 / shipPeriod.
    LOCAL targetAngRate IS 360 / targetPeriod.
    LOCAL relativeRate IS shipAngRate - targetAngRate.
    LOCAL waitTime IS phaseDiff / ABS(relativeRate).

    // Ensure we depart at least 60s from now
    IF waitTime < 60 { SET waitTime TO waitTime + synodicPeriod. }

    LOCAL departUt IS TIME:SECONDS + waitTime.

    mLog("Phase: current=" + ROUND(currentPhase, 1)
        + "  ideal=" + ROUND(idealPhaseAngle, 1)
        + "  wait=" + ROUND(waitTime, 0) + "s").

    // --- Place prograde-only node ---
    LOCAL nd IS NODE(departUt, 0, 0, hohmannDv).
    ADD nd.
    WAIT 0.1.

    // --- Validate encounter via KSP conics ---
    // If no encounter at the estimated time, use _findEncounter to slide
    LOCAL patch IS _getTargetPatch(nd, targetBody).
    IF patch = 0 OR patch:PERIAPSIS < 0 {
        mLog("No encounter at Hohmann estimate, searching nearby...").
        LOCAL foundTime IS _findEncounter(nd, targetBody, departUt, shipPeriod * 2, shipPeriod / 8).
        IF foundTime < 0 {
            // Widen the search
            SET foundTime TO _findEncounter(nd, targetBody, departUt, shipPeriod * 6, shipPeriod / 4).
        }
        IF foundTime < 0 {
            mLogError("planTransfer: no encounter found near Hohmann estimate.").
            REMOVE nd.
            RETURN 0.
        }
        SET nd:TIME TO foundTime.
        WAIT 0.1.
        mLog("Encounter found at T+" + ROUND(foundTime - TIME:SECONDS, 0) + "s").
    } ELSE {
        mLog("Encounter confirmed at Hohmann estimate. Pe=" + ROUND(patch:PERIAPSIS/1000, 1) + "km").
    }

    // --- Optional LAN scan ---
    // If lanTarget is specified, scan across multiple orbits to find the departure
    // that produces the closest LAN at the target body (read from KSP's conics).
    IF lanTarget >= 0 {
        SET nd TO _scanForLan(nd, targetBody, lanTarget, shipPeriod).
    }

    RETURN nd.
}

// ============================================================
// Interplanetary transfer — Lambert scan + conic validation
// Requires lambert.ks to be loaded.
// ============================================================
LOCAL FUNCTION _planInterplanetaryTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER lanTarget.
    PARAMETER centralBody.
    PARAMETER mu.

    LOCAL hohmannA    IS (SHIP:ORBIT:SEMIMAJORAXIS + targetBody:ORBIT:SEMIMAJORAXIS) / 2.
    LOCAL hohmannTof  IS CONSTANT:PI * SQRT(hohmannA^3 / mu).

    LOCAL shipPeriod  IS SHIP:ORBIT:PERIOD.
    LOCAL nDepart     IS 12.   // how many departure slots to try (one per orbit)
    LOCAL nTof        IS 9.    // TOF samples per departure (odd number, centred)
    LOCAL tofSpread   IS hohmannTof * 0.3. // ±30% around Hohmann TOF

    LOCAL bestDv      IS 9999999.
    LOCAL bestDepart  IS -1.
    LOCAL bestArrive  IS -1.
    LOCAL bestLanErr  IS 999.

    LOCAL lanTol IS 0.5.
    IF CFG:HASKEY("LAN_ERR_TOL") { SET lanTol TO CFG["LAN_ERR_TOL"]. }

    mLog("Lambert scan: " + nDepart + " departures x " + nTof + " TOFs, hohmannTof=" + ROUND(hohmannTof,0) + "s").

    FROM { LOCAL di IS 0. } UNTIL di >= nDepart STEP { SET di TO di + 1. } DO {

        LOCAL departUt IS TIME:SECONDS + 60 + di * shipPeriod.
        LOCAL r1 IS POSITIONAT(SHIP, departUt) - POSITIONAT(centralBody, departUt).
        LOCAL v1Ship IS VELOCITYAT(SHIP, departUt):ORBIT.

        FROM { LOCAL ti IS 0. } UNTIL ti >= nTof STEP { SET ti TO ti + 1. } DO {

            LOCAL tofFrac   IS (ti / (nTof - 1)) - 0.5. // -0.5 to +0.5
            LOCAL tof       IS hohmannTof + tofFrac * tofSpread * 2.
            IF tof < 60 { SET tof TO 60. }

            LOCAL arriveUt  IS departUt + tof.
            LOCAL r2        IS POSITIONAT(targetBody, arriveUt) - POSITIONAT(centralBody, arriveUt).

            LOCAL result IS lambertSolve(r1, r2, tof, mu, FALSE).
            LOCAL v1Lambert IS result["v1"].
            LOCAL dvVec     IS v1Lambert - v1Ship.
            LOCAL dvMag     IS dvVec:MAG.

            // Only evaluate competitive solutions for LAN
            IF dvMag < bestDv * 1.05 {
                LOCAL lanErr IS 999.
                IF lanTarget >= 0 {
                    // Geometric LAN estimate from Lambert arrival velocity
                    LOCAL v2Lambert IS result["v2"].
                    LOCAL captureNormal IS VCRS(r2, v2Lambert):NORMALIZED.
                    LOCAL northPole IS V(0, 1, 0).
                    LOCAL nodeVec   IS VCRS(northPole, captureNormal):NORMALIZED.
                    LOCAL estimatedLan IS ARCTAN2(nodeVec:Y, nodeVec:X).
                    IF estimatedLan < 0 { SET estimatedLan TO estimatedLan + 360. }

                    SET lanErr TO lanTarget - estimatedLan.
                    IF lanErr >  180 { SET lanErr TO lanErr - 360. }
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
                    SET bestDv     TO dvMag.
                    SET bestDepart TO departUt.
                    SET bestArrive TO arriveUt.
                    SET bestLanErr TO lanErr.
                    mLog("Lambert[d=" + di + ",t=" + ti + "] dV=" + ROUND(dvMag,1)
                        + " LAN err=" + ROUND(lanErr,1)
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

    // --- Build the maneuver node from the best Lambert solution ---
    LOCAL r1Best    IS POSITIONAT(SHIP, bestDepart) - centralBody:POSITION.
    LOCAL r2Best    IS POSITIONAT(targetBody, bestArrive) - centralBody:POSITION.
    LOCAL result    IS lambertSolve(r1Best, r2Best, bestArrive - bestDepart, mu, FALSE).
    LOCAL dvVec     IS result["v1"] - VELOCITYAT(SHIP, bestDepart):ORBIT.

    // Decompose dvVec into prograde/normal/radial at departure
    LOCAL progradeHat IS VELOCITYAT(SHIP, bestDepart):ORBIT:NORMALIZED.
    LOCAL normalHat   IS VCRS(r1Best, progradeHat):NORMALIZED.
    LOCAL radialHat   IS VCRS(normalHat, progradeHat):NORMALIZED.

    LOCAL dvPro IS VDOT(dvVec, progradeHat).
    LOCAL dvNor IS VDOT(dvVec, normalHat).
    LOCAL dvRad IS VDOT(dvVec, radialHat).

    LOCAL nd IS NODE(bestDepart, dvRad, dvNor, dvPro).
    ADD nd.
    WAIT 0.1.

    // --- Validate encounter via KSP conics ---
    LOCAL patch IS _getTargetPatch(nd, targetBody).
    IF patch = 0 OR patch:PERIAPSIS < 0 {
        mLog("Lambert node has no encounter, searching nearby...").
        LOCAL foundTime IS _findEncounter(nd, targetBody, bestDepart, SHIP:ORBIT:PERIOD * 2, SHIP:ORBIT:PERIOD / 8).
        IF foundTime < 0 {
            mLogWarn("No encounter found near Lambert solution — proceeding anyway.").
        } ELSE {
            SET nd:TIME TO foundTime.
            WAIT 0.1.
            mLog("Encounter found at T+" + ROUND(foundTime - TIME:SECONDS, 0) + "s").
        }
    } ELSE {
        mLog("Encounter confirmed. Pe=" + ROUND(patch:PERIAPSIS/1000, 1) + "km").
    }

    // --- LAN refinement from conics ---
    // For the top solution, check actual LAN from KSP's patched conics
    // and scan nearby orbits if LAN targeting is active.
    IF lanTarget >= 0 {
        SET nd TO _scanForLan(nd, targetBody, lanTarget, SHIP:ORBIT:PERIOD).
    }

    RETURN nd.
}

// ============================================================
// LAN scan — shared by local and interplanetary paths
// Slides departure time across orbits, reads actual LAN from
// KSP's patched conics, picks the orbit with lowest LAN error.
// ============================================================
LOCAL FUNCTION _scanForLan {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER lanTarget.
    PARAMETER shipPeriod.

    LOCAL targetPeriod IS targetBody:ORBIT:PERIOD.
    LOCAL nScan IS MAX(6, CEILING(targetPeriod / shipPeriod)).
    LOCAL centerTime IS nd:TIME.
    LOCAL bestLanErr IS 999.
    LOCAL bestTime IS centerTime.
    LOCAL baseDv IS nd:PROGRADE.

    LOCAL lanTol IS 0.5.
    IF CFG:HASKEY("LAN_ERR_TOL") { SET lanTol TO CFG["LAN_ERR_TOL"]. }

    mLog("LAN scan: " + (2 * nScan + 1) + " orbits around departure, target LAN=" + ROUND(lanTarget, 1)).

    FROM { LOCAL oi IS -nScan. } UNTIL oi > nScan STEP { SET oi TO oi + 1. } DO {
        LOCAL tryTime IS centerTime + oi * shipPeriod.
        IF tryTime > TIME:SECONDS + 30 {
            SET nd:TIME TO tryTime.
            SET nd:PROGRADE TO baseDv.
            WAIT 0.02.
            LOCAL patch IS _getTargetPatch(nd, targetBody).
            IF patch <> 0 AND patch:PERIAPSIS > 0 {
                LOCAL lanErr IS ABS(patch:LAN - lanTarget).
                IF lanErr > 180 { SET lanErr TO 360 - lanErr. }
                IF lanErr < bestLanErr {
                    SET bestLanErr TO lanErr.
                    SET bestTime TO tryTime.
                    mLog("LAN[" + oi + "] LAN=" + ROUND(patch:LAN, 1)
                        + " err=" + ROUND(lanErr, 1)
                        + " Pe=" + ROUND(patch:PERIAPSIS/1000, 1) + "km").
                }
            }
        }
    }

    SET nd:TIME TO bestTime.
    SET nd:PROGRADE TO baseDv.
    WAIT 0.1.

    // Verify the chosen orbit still has an encounter
    LOCAL verifyPatch IS _getTargetPatch(nd, targetBody).
    IF verifyPatch = 0 OR verifyPatch:PERIAPSIS < 0 {
        mLogWarn("LAN scan: chosen orbit lost encounter, searching nearby...").
        LOCAL foundTime IS _findEncounter(nd, targetBody, bestTime, shipPeriod / 2, shipPeriod / 16).
        IF foundTime >= 0 {
            SET nd:TIME TO foundTime.
            WAIT 0.1.
        }
    }

    mLog("LAN scan: best err=" + ROUND(bestLanErr, 1) + "°  depart T+" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    RETURN nd.
}

// ============================================================
// Newton-Raphson PE targeting — shared by both paths
// Proportional clamp: large errors allow larger steps.
// ============================================================
// ============================================================
// newtonTarget — unified Newton-Raphson for any orbital param.
//
// param: "PE" (prograde), "INC" (normal), "LAN" (normal), "AOP" (radial)
// opts (optional LEXICON):
//   BIAS    — seed value for the axis when it's zero (e.g. ±5 for polar)
//   DV_CAP  — max total node dV; aborts if exceeded (used by MCC)
//   TOL     — convergence tolerance (default: 500m for PE, 0.5° for angles)
//   DAMP    — damping factor (default: 0.5 for PE, 0.7 for angles)
// ============================================================
GLOBAL FUNCTION newtonTarget {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER param.
    PARAMETER targetVal.
    PARAMETER opts IS LEXICON().

    LOCAL isAngle IS (param <> "PE").
    LOCAL eps     IS CHOOSE 0.5 IF isAngle ELSE 0.1.
    LOCAL damp    IS CHOOSE 0.7 IF isAngle ELSE 0.5.
    LOCAL tol     IS CHOOSE 0.5 IF isAngle ELSE 500.
    LOCAL maxIter IS 35.
    LOCAL dvCap   IS -1.
    LOCAL bias    IS 0.

    IF opts:HASKEY("DAMP")     { SET damp    TO opts["DAMP"]. }
    IF opts:HASKEY("TOL")      { SET tol     TO opts["TOL"]. }
    IF opts:HASKEY("MAX_ITER") { SET maxIter TO opts["MAX_ITER"]. }
    IF opts:HASKEY("DV_CAP")   { SET dvCap   TO opts["DV_CAP"]. }
    IF opts:HASKEY("BIAS")     { SET bias    TO opts["BIAS"]. }

    // Seed bias (e.g. ±5 m/s normal for polar vs retropolar)
    IF bias <> 0 AND _ntGetAxis(nd, param) = 0 {
        _ntSetAxis(nd, param, bias).
        WAIT 0.02.
    }

    LOCAL label IS param.
    LOCAL fmtVal IS ROUND(targetVal, CHOOSE 1 IF isAngle ELSE 0).
    IF bias <> 0 {
        mLog(label + ": targeting " + fmtVal + " (bias=" + bias + ")").
    } ELSE {
        mLog(label + ": targeting " + fmtVal).
    }

    LOCAL lastGood  IS _ntGetAxis(nd, param).
    LOCAL stepScale IS 1.0.

    FROM { LOCAL i IS 0. } UNTIL i >= maxIter STEP { SET i TO i + 1. } DO {
        LOCAL p IS _getTargetPatch(nd, targetBody).
        IF p = 0 OR p:PERIAPSIS < 0 {
            // Backtrack: try halfway between current and last good
            LOCAL midVal IS (_ntGetAxis(nd, param) + lastGood) / 2.
            _ntSetAxis(nd, param, midVal).
            WAIT 0.02.
            LOCAL pMid IS _getTargetPatch(nd, targetBody).
            IF pMid <> 0 AND pMid:PERIAPSIS > 0 {
                SET lastGood TO midVal.
                SET stepScale TO stepScale * 0.5.
                mLog("  " + label + "[" + i + "]: backtracked.").
            } ELSE {
                _ntSetAxis(nd, param, lastGood).
                SET stepScale TO stepScale * 0.5.
                IF stepScale < 0.1 {
                    mLog("  " + label + "[" + i + "]: step too small, stopping.").
                    BREAK.
                }
                mLog("  " + label + "[" + i + "]: reverted.").
            }
        } ELSE {
            SET lastGood TO _ntGetAxis(nd, param).
            LOCAL current IS _ntReadParam(p, param).
            LOCAL err IS targetVal - current.
            IF isAngle {
                IF err >  180 { SET err TO err - 360. }
                IF err < -180 { SET err TO err + 360. }
            }

            IF ABS(err) < tol {
                mLog("  " + label + "[" + i + "] converged: " + ROUND(current, 1)).
                BREAK.
            }

            // Finite difference for sensitivity
            LOCAL oldVal IS _ntGetAxis(nd, param).
            _ntSetAxis(nd, param, oldVal + eps).
            WAIT 0.02.
            LOCAL p2 IS _getTargetPatch(nd, targetBody).
            _ntSetAxis(nd, param, oldVal).
            IF p2 = 0 OR p2:PERIAPSIS < 0 { BREAK. }

            LOCAL current2 IS _ntReadParam(p2, param).
            LOCAL delta IS current2 - current.
            IF isAngle {
                IF delta >  180 { SET delta TO delta - 360. }
                IF delta < -180 { SET delta TO delta + 360. }
            }

            LOCAL sens IS delta / eps.
            IF ABS(sens) < 0.001 { BREAK. }

            LOCAL correction IS (err / sens) * damp.
            LOCAL maxStep IS CHOOSE MAX(5.0, ABS(err) / 3) IF isAngle ELSE MAX(3.0, ABS(err) / 5000).
            SET maxStep TO maxStep * stepScale.
            IF correction >  maxStep { SET correction TO  maxStep. }
            IF correction < -maxStep { SET correction TO -maxStep. }

            _ntSetAxis(nd, param, oldVal + correction).
            WAIT 0.02.

            // dV cap check (MCC)
            IF dvCap >= 0 AND nd:DELTAV:MAG > dvCap {
                _ntSetAxis(nd, param, lastGood).
                mLog("  " + label + "[" + i + "]: dV cap (" + dvCap + " m/s) reached.").
                BREAK.
            }

            // Verify encounter survives the correction
            LOCAL pCheck IS _getTargetPatch(nd, targetBody).
            IF pCheck = 0 OR pCheck:PERIAPSIS < 0 {
                _ntSetAxis(nd, param, oldVal + correction / 2).
                WAIT 0.02.
                LOCAL pHalf IS _getTargetPatch(nd, targetBody).
                IF pHalf = 0 OR pHalf:PERIAPSIS < 0 {
                    _ntSetAxis(nd, param, lastGood).
                    SET stepScale TO stepScale * 0.5.
                }
            }

            mLog("  " + label + "[" + i + "] " + ROUND(current, 1) + " corr=" + ROUND(correction, 2) + " m/s").
        }
    }
}

// Helpers for newtonTarget — map param name to patch field and node axis.
// PE → PROGRADE, INC → NORMAL, LAN → NORMAL, AOP → RADIALOUT
LOCAL FUNCTION _ntReadParam {
    PARAMETER p, param.
    IF param = "PE"  { RETURN p:PERIAPSIS. }
    IF param = "INC" { RETURN p:INCLINATION. }
    IF param = "LAN" { RETURN p:LAN. }
    IF param = "AOP" { RETURN p:ARGUMENTOFPERIAPSIS. }
    RETURN 0.
}

LOCAL FUNCTION _ntGetAxis {
    PARAMETER nd, param.
    IF param = "PE"  { RETURN nd:PROGRADE. }
    IF param = "INC" { RETURN nd:NORMAL. }
    IF param = "LAN" { RETURN nd:NORMAL. }
    IF param = "AOP" { RETURN nd:RADIALOUT. }
    RETURN 0.
}

LOCAL FUNCTION _ntSetAxis {
    PARAMETER nd, param, val.
    IF param = "PE"  { SET nd:PROGRADE   TO val. }
    IF param = "INC" { SET nd:NORMAL     TO val. }
    IF param = "LAN" { SET nd:NORMAL     TO val. }
    IF param = "AOP" { SET nd:RADIALOUT  TO val. }
}

GLOBAL FUNCTION planCapture {
    PARAMETER targetBody.
    PARAMETER targetAlt.
    LOCAL mu    IS targetBody:MU.
    LOCAL rPe   IS targetBody:RADIUS + SHIP:PERIAPSIS.
    LOCAL rAp   IS targetBody:RADIUS + targetAlt.
    LOCAL tSMA  IS (rPe + rAp) / 2.
    LOCAL vCapture IS SQRT(mu * (2/rPe - 1/tSMA)).
    LOCAL vAtPe    IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG.
    LOCAL dv       IS vCapture - vAtPe.
    LOCAL nd IS NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, dv).
    ADD nd.
    RETURN nd.
}

GLOBAL FUNCTION planRaisePeNow {
    PARAMETER targetPe.
    LOCAL mu   IS SHIP:ORBIT:BODY:MU.
    LOCAL rNow IS SHIP:ORBIT:BODY:RADIUS + SHIP:ALTITUDE.
    LOCAL rPe  IS SHIP:ORBIT:BODY:RADIUS + targetPe.
    LOCAL vNow IS SHIP:VELOCITY:ORBIT:MAG.
    LOCAL tSMA IS (rNow + rPe) / 2.
    LOCAL vNew IS SQRT(mu * (2/rNow - 1/tSMA)).
    LOCAL dv   IS vNew - vNow.
    LOCAL lead IS 60.
    IF ABS(dv) > 100 { SET lead TO 90. }
    IF ABS(dv) > 300 { SET lead TO 120. }
    LOCAL nd IS NODE(TIME:SECONDS + lead, 0, 0, dv).
    ADD nd.
    RETURN nd.
}

GLOBAL FUNCTION planAoPChange {
    PARAMETER targetAoP.
    LOCAL currentAoP IS SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    LOCAL deltaAoP IS targetAoP - currentAoP.
    IF deltaAoP > 180  { SET deltaAoP TO deltaAoP - 360. }
    IF deltaAoP < -180 { SET deltaAoP TO deltaAoP + 360. }
    IF ABS(deltaAoP) < 2 { RETURN 0. }
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL a  IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL e  IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL h  IS SQRT(mu * a * (1 - e^2)).
    LOCAL dvMag IS 2 * (mu / h) * e * SIN(ABS(deltaAoP) / 2).
    LOCAL ta1 IS deltaAoP / 2.
    LOCAL ta2 IS ta1 + 180.
    LOCAL eta1 IS etaToTrueAnomaly(ta1).
    LOCAL eta2 IS etaToTrueAnomaly(ta2).
    LOCAL burnETA IS eta1.
    LOCAL dvSign IS -1.
    IF eta2 < eta1 {
        SET burnETA TO eta2.
        SET dvSign TO 1.
    }
    LOCAL dvRadial IS dvSign * dvMag.
    LOCAL burnUT IS TIME:SECONDS + burnETA.
    LOCAL nd IS NODE(burnUT, dvRadial, 0, 0).
    ADD nd.
    RETURN nd.
}

// ============================================================
// phaseMidCourse — mid-course correction during transfer coast.
// Fires at coast midpoint (local) or 1h past SOI (interplanetary).
// Uses phased Newton: INC → AoP → PE → LAN → PE cleanup.
// Total dV capped at MCC_DV_CAP (50 m/s).
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
        LOCAL dir IS CFG["CAPTURE_DIR"]:TOUPPER.
        IF dir = "PROGRADE"   { SET targetInc TO 0. }
        IF dir = "POLAR"      { SET targetInc TO 90. }
        IF dir = "RETROPOLAR" { SET targetInc TO 90. }
        IF dir = "RETROGRADE" { SET targetInc TO 180. }
    }
    IF CFG:HASKEY("CAPTURE_INC") { SET targetInc TO CFG["CAPTURE_INC"]. }
    IF CFG:HASKEY("CAPTURE_LAN") { SET targetLan TO CFG["CAPTURE_LAN"]. }
    IF CFG:HASKEY("CAPTURE_AOP") { SET targetAoP TO CFG["CAPTURE_AOP"]. }

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

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + waitTime, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    LOCAL mccOpts IS LEXICON("DV_CAP", MCC_DV_CAP, "TOL", 1.0).

    // Phased optimization: plane first, then energy
    IF targetInc >= 0 { newtonTarget(nd, target, "INC", targetInc, mccOpts). }
    IF targetAoP >= 0 { newtonTarget(nd, target, "AOP", targetAoP, mccOpts). }
    newtonTarget(nd, target, "PE", targetPe, mccOpts).
    IF targetLan >= 0 {
        newtonTarget(nd, target, "LAN", targetLan, mccOpts).
        newtonTarget(nd, target, "PE", targetPe, mccOpts).
    }

    WAIT 0.1.

    LOCAL totalDv IS nd:DELTAV:MAG.
    LOCAL finalPatch IS _getTargetPatch(nd, target).

    IF totalDv < 0.1 OR finalPatch = 0 {
        mLog("Encounter on target. Skipping MCC burn.").
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

LOCAL FUNCTION _calcStartTime {
    PARAMETER nd.
    LOCAL halfBurn IS 0.
    IF ADDONS:KE:AVAILABLE {
        SET halfBurn TO ADDONS:KE:NODEHALFBURNTIME.
    } ELSE {
        SET halfBurn TO nd:BURNTIME / 2.
    }
    LOCAL lead IS MIN(2.0, halfBurn * 0.02).
    RETURN nd:TIME - halfBurn - lead.
}

LOCAL FUNCTION _safeMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

LOCAL FUNCTION _isComplete {
    PARAMETER nd, origDV.
    LOCAL remaining IS nd:DELTAV:MAG.
    LOCAL threshold IS MAX(ABS_CUTOFF, origDV * COMPLETE_FRAC).
    LOCAL dotCheck IS VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED).
    IF remaining < 1.0 {
        RETURN remaining < threshold OR dotCheck < COS(ALIGN_TOLERANCE).
    }
    RETURN remaining < threshold OR dotCheck < 0.
}

LOCAL FUNCTION _needsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _findCmdModule {
    IF CORE:PART:HASMODULE("ModuleCommand") {
        RETURN CORE:PART:GETMODULE("ModuleCommand").
    }
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleCommand") {
            RETURN p:GETMODULE("ModuleCommand").
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _hibernateCmd {
    LOCAL cm IS _findCmdModule().
    IF cm = 0 { RETURN. }
    IF cm:HASFIELD("hibernation") { cm:SETFIELD("hibernation", TRUE). }
}

LOCAL FUNCTION _wakeCmd {
    LOCAL cm IS _findCmdModule().
    IF cm = 0 { RETURN. }
    IF cm:HASFIELD("hibernation") { cm:SETFIELD("hibernation", FALSE). }
}

GLOBAL FUNCTION _getTargetPatch {
    PARAMETER originTarget.
    PARAMETER targetBody.
    LOCAL p IS originTarget:ORBIT.
    UNTIL NOT p:HASNEXTPATCH {
        SET p TO p:NEXTPATCH.
        IF p:BODY:NAME = targetBody:NAME { RETURN p. }
    }
    RETURN 0.
}
