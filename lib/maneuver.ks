// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
// ============================================================

@LAZYGLOBAL OFF.

LOCAL COMPLETE_FRAC        IS 0.001.
LOCAL ABS_CUTOFF           IS 0.0001.
LOCAL ALIGN_TOLERANCE      IS 2.0.
LOCAL HIBERNATE_THRESHOLD  IS 300.
LOCAL HIBERNATE_WAKE_LEAD  IS 180.
LOCAL MCC_DV_CAP           IS 50.

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
        SET SAS TO FALSE.
        WAIT 0.1.
        LOCK STEERING TO nd:BURNVECTOR.
        mLog("Awake — " + ROUND(startTime - TIME:SECONDS, 0) + "s to burn.").
        mLog("Re-aligning to burn vector after hibernation.").
        HUDTEXT("Core awake — burn in " + ROUND(startTime - TIME:SECONDS, 0) + "s", 5, 2, 13, GREEN, FALSE).
    }

    UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ALIGN_TOLERANCE
            OR TIME:SECONDS >= (startTime - 30) {
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT 0.1.
    }

    IF VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) >= ALIGN_TOLERANCE {
        mLogWarn("Burn starting with " + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR),1) + "° misalignment.").
    } ELSE {
        mLog("Aligned. Waiting for burn window...").
    }

    WAIT UNTIL TIME:SECONDS >= (startTime - 5).
    HUDTEXT("Burn in T-4", 3, 2, 15, WHITE, FALSE).
    countdown(4).

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

GLOBAL FUNCTION archivePlannedManeuverLog {
    PARAMETER label IS "maneuver".
    IF HAS_LINK {
        archiveLog().
        mLog("Planned maneuver log archived: " + label + ".").
    } ELSE {
        mLog("Planned maneuver log archive skipped: no KSC link (" + label + ").").
    }
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
    archivePlannedManeuverLog("circularize").
    RETURN nd.
}

GLOBAL FUNCTION _findEncounter {
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
//   1. Build raw node  (_planLocalTransfer or planInterplanetaryTransfer)
//      Local:  closest-approach optimization — Hohmann seed, then scan
//              departure time + prograde dV to minimize distance to target.
//              Smooth POSITIONAT objective, no binary encounter search.
//      Interplanetary:  Lambert grid scan, full 3-axis node, conic validation
//   2. Optional LAN scan (_scanForLan) — slide departure across orbits
//   3. Collision targeting (prograde) — converge PE to zero for the
//      widest possible encounter margin. A dead-center trajectory
//      survives large normal dV perturbations during INC targeting,
//      especially for local transfers where the SOI is narrow.
//   4. Coupled PE/INC targeting — solve periapsis and capture plane
//      together. PE and INC are tightly coupled on local moon transfers,
//      so a scalar Newton pass can report false "low sensitivity" while
//      a larger normal/radial/prograde coordinate search still converges.
//
// MCC (phaseMidCourse) fires mid-coast to fine-tune any drift
// from burn execution errors. It runs the same INC/PE/AoP/LAN
// passes but with a per-axis dV cap since it's corrective only.
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
    mLogWarn("STATS transfer setup target=" + targetBody:NAME
        + " local=" + isLocal
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " lan=" + ROUND(lanTarget,1)
        + " aop=" + ROUND(aopTarget,1)).

    // --- 1. Build raw node ---
    LOCAL nd IS 0.
    IF isLocal {
        SET nd TO _planLocalTransfer(targetBody, targetPe, lanTarget, centralBody, mu).
    } ELSE {
        SET nd TO planInterplanetaryTransfer(targetBody, targetPe, lanTarget, centralBody, mu).
    }

    IF nd = 0 OR NOT nd:ISTYPE("Node") { RETURN. }

    // --- 2. Collision targeting ---
    // Converge PE to zero (dead-center collision course) first. This
    // gives the widest possible encounter margin — the trajectory
    // passes through the middle of the SOI — so that subsequent INC
    // targeting can add substantial normal dV without losing the
    // encounter. Especially important for local transfers (Mun/Minmus)
    // where the SOI is narrow relative to the trajectory deflection.
    newtonTarget(nd, targetBody, "PE", 0).

    // --- 3. INC targeting ---
    // Resolve capture orbit direction from CFG. Adding normal dV at
    // departure tilts the approach trajectory so the ship enters the
    // target's SOI at the right angle for the desired capture orbit.
    // This is much cheaper than a mid-course or post-capture plane
    // change because the lever arm is longest at departure.
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

    // --- 4. Final targeting ---
    // If an arrival inclination is requested, solve PE and INC as a pair.
    // A one-axis Newton step is fragile here: at a near-collision Mun
    // encounter, tiny normal probes may not visibly change the patched
    // conic inclination even though larger normal/radial/prograde moves do.
    IF captureInc >= 0 {
        _targetPeIncCoupled(nd, targetBody, targetPe, captureInc, normalBias).
    } ELSE {
        newtonTarget(nd, targetBody, "PE", targetPe).
    }

    IF lanTarget >= 0 OR aopTarget >= 0 {
        LOCAL elemTargets IS LEXICON().
        elemTargets:ADD("PE", targetPe).
        IF captureInc >= 0 { elemTargets:ADD("INC", captureInc). }
        IF lanTarget >= 0 { elemTargets:ADD("LAN", lanTarget). }
        IF aopTarget >= 0 { elemTargets:ADD("AOP", aopTarget). }

        LOCAL elemOpts IS LEXICON().
        elemOpts:ADD("STEP_NORMAL", 5.0).
        elemOpts:ADD("STEP_PROGRADE", 2.0).
        elemOpts:ADD("STEP_RADIAL", 5.0).
        elemOpts:ADD("STEP_TIME", 60.0).
        elemOpts:ADD("MIN_STEP", 0.05).
        elemOpts:ADD("MAX_ITER", 100).
        _targetPatchElementsCoupled(nd, targetBody, elemTargets, elemOpts).
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
    PARAMETER lanTarget.
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
    LOCAL scanSteps IS nScanOrbits * 4.  // 4 samples per orbit
    LOCAL scanDt IS shipPeriod / 4.

    LOCAL bestTime IS departUt.
    LOCAL bestCA IS _findClosestApproach(targetBody, departUt + hohmannTof * 0.5, departUt + hohmannTof * 1.5, 40).

    mLog("Closest approach scan: " + scanSteps + " steps over ±" + nScanOrbits + " orbits").

    FROM { LOCAL si IS -scanSteps. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTime IS departUt + si * scanDt.
        IF tryTime > TIME:SECONDS + 30 {
            SET nd:TIME TO tryTime.
            WAIT 0.02.
            LOCAL tryCa IS _findClosestApproach(targetBody, tryTime + hohmannTof * 0.5, tryTime + hohmannTof * 1.5, 40).
            IF tryCa["distance"] < bestCA["distance"] {
                SET bestCA TO tryCa.
                SET bestTime TO tryTime.
            }
        }
    }
    SET nd:TIME TO bestTime.
    WAIT 0.1.
    mLog("Time scan: best CA=" + ROUND(bestCA["distance"]/1000, 1) + "km"
        + " at T+" + ROUND(bestCA["time"] - TIME:SECONDS, 0) + "s"
        + "  depart T+" + ROUND(bestTime - TIME:SECONDS, 0) + "s").

    // --- Golden section refine departure time ---
    LOCAL tA IS MAX(TIME:SECONDS + 30, bestTime - scanDt).
    LOCAL tB IS bestTime + scanDt.
    LOCAL gr IS (SQRT(5) + 1) / 2.

    FROM { LOCAL gi IS 0. } UNTIL gi >= 15 STEP { SET gi TO gi + 1. } DO {
        LOCAL tC IS tB - (tB - tA) / gr.
        LOCAL tD IS tA + (tB - tA) / gr.

        SET nd:TIME TO tC. WAIT 0.02.
        LOCAL caC IS _findClosestApproach(targetBody, tC + hohmannTof * 0.4, tC + hohmannTof * 1.6, 30).
        SET nd:TIME TO tD. WAIT 0.02.
        LOCAL caD IS _findClosestApproach(targetBody, tD + hohmannTof * 0.4, tD + hohmannTof * 1.6, 30).

        IF caC["distance"] < caD["distance"] {
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

    FROM { LOCAL di IS 0. } UNTIL di > dvSteps STEP { SET di TO di + 1. } DO {
        LOCAL tryDv IS hohmannDv - dvRange + di * dvStep.
        SET nd:PROGRADE TO tryDv.
        WAIT 0.02.
        LOCAL tryCa IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 40).
        IF tryCa["distance"] < bestCA["distance"] {
            SET bestCA TO tryCa.
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
        SET nd:PROGRADE TO dvD. WAIT 0.02.
        LOCAL caD IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.4, nd:TIME + hohmannTof * 1.6, 30).

        IF caC["distance"] < caD["distance"] {
            SET dvB TO dvD.
        } ELSE {
            SET dvA TO dvC.
        }
    }
    SET nd:PROGRADE TO (dvA + dvB) / 2.
    WAIT 0.1.

    LOCAL finalCA IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.3, nd:TIME + hohmannTof * 2.0, 60).
    mLog("Optimized: CA=" + ROUND(finalCA["distance"]/1000, 1) + "km"
        + "  dV=" + ROUND(nd:PROGRADE, 1) + " m/s"
        + "  depart T+" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    mLogWarn("STATS local-transfer target=" + targetBody:NAME
        + " caKm=" + ROUND(finalCA["distance"]/1000,1)
        + " prograde=" + ROUND(nd:PROGRADE,1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).

    // --- Optional LAN scan ---
    // If lanTarget is specified, scan across multiple orbits to find the departure
    // that produces the closest LAN at the target body (read from KSP's conics).
    IF lanTarget >= 0 {
        SET nd TO _scanForLan(nd, targetBody, lanTarget, shipPeriod).
    }

    RETURN nd.
}

// ============================================================
// LAN scan — shared by local and interplanetary paths
// Slides departure time across orbits, reads actual LAN from
// KSP's patched conics, picks the orbit with lowest LAN error.
// ============================================================
GLOBAL FUNCTION _scanForLan {
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
    mLogWarn("STATS lan-scan target=" + targetBody:NAME
        + " target=" + ROUND(lanTarget,1)
        + " err=" + ROUND(bestLanErr,1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).
    RETURN nd.
}

// ============================================================
// _findClosestApproach — find minimum separation between ship
// and a target vessel over a time window.
//
// Uses coarse scan + golden section refinement. POSITIONAT on
// both ship and target reflects any maneuver nodes on the flight
// plan, so this works for evaluating planned burns.
//
// Returns: LEXICON("time", ut, "distance", meters)
// ============================================================
GLOBAL FUNCTION _findClosestApproach {
    PARAMETER tgt, tStart, tEnd, steps.

    // Coarse scan
    LOCAL dt IS (tEnd - tStart) / steps.
    LOCAL bestT IS tStart.
    LOCAL bestD IS 9e15.

    LOCAL t IS tStart.
    UNTIL t > tEnd {
        LOCAL sep IS (POSITIONAT(SHIP, t) - POSITIONAT(tgt, t)):MAG.
        IF sep < bestD {
            SET bestD TO sep.
            SET bestT TO t.
        }
        SET t TO t + dt.
    }

    // Golden section refine around the best point
    LOCAL a IS MAX(tStart, bestT - dt * 2).
    LOCAL b IS MIN(tEnd, bestT + dt * 2).
    LOCAL gr IS (SQRT(5) + 1) / 2.

    FROM { LOCAL i IS 0. } UNTIL i >= 15 STEP { SET i TO i + 1. } DO {
        LOCAL c IS b - (b - a) / gr.
        LOCAL d IS a + (b - a) / gr.
        LOCAL fc IS (POSITIONAT(SHIP, c) - POSITIONAT(tgt, c)):MAG.
        LOCAL fd IS (POSITIONAT(SHIP, d) - POSITIONAT(tgt, d)):MAG.
        IF fc < fd {
            SET b TO d.
        } ELSE {
            SET a TO c.
        }
    }

    LOCAL midT IS (a + b) / 2.
    LOCAL midD IS (POSITIONAT(SHIP, midT) - POSITIONAT(tgt, midT)):MAG.
    RETURN LEXICON("time", midT, "distance", midD).
}

// ============================================================
// _targetPeIncCoupled — coordinate search for capture PE + INC.
//
// Why this exists:
//   A local Mun/Minmus transfer often starts as a dead-center encounter
//   so PE targeting has a wide margin. Once we ask for a polar capture,
//   PE and INC stop being independent:
//     - normal dV changes the B-plane miss direction and capture plane
//     - prograde dV changes arrival energy and periapsis
//     - radial dV changes timing/aim point and can recover an encounter
//
// A scalar Newton probe of +0.5 m/s normal can look like "low
// sensitivity" in KSP's patched conics. This search takes larger trial
// moves on all three node axes and accepts whichever lowers the combined
// PE/INC cost, then halves the step sizes when no axis improves.
// ============================================================
LOCAL FUNCTION _targetPeIncCoupled {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER targetInc.
    PARAMETER normalBias IS 0.
    PARAMETER opts IS LEXICON().

    IF normalBias <> 0 AND nd:NORMAL = 0 {
        SET nd:NORMAL TO normalBias * 5.
        WAIT 0.02.
    }

    LOCAL axes IS LIST("NORMAL", "PROGRADE", "RADIALOUT").
    LOCAL signs IS LIST(1, -1).
    LOCAL steps IS LEXICON().
    steps:ADD("NORMAL", 40.0).
    steps:ADD("PROGRADE", 20.0).
    steps:ADD("RADIALOUT", 20.0).
    LOCAL minStep IS 0.05.
    LOCAL maxIter IS 120.
    LOCAL dvCap IS -1.

    IF opts:HASKEY("STEP_NORMAL")  { SET steps["NORMAL"]    TO opts["STEP_NORMAL"]. }
    IF opts:HASKEY("STEP_PROGRADE"){ SET steps["PROGRADE"]  TO opts["STEP_PROGRADE"]. }
    IF opts:HASKEY("STEP_RADIAL")  { SET steps["RADIALOUT"] TO opts["STEP_RADIAL"]. }
    IF opts:HASKEY("MIN_STEP")     { SET minStep            TO opts["MIN_STEP"]. }
    IF opts:HASKEY("MAX_ITER")     { SET maxIter            TO opts["MAX_ITER"]. }
    IF opts:HASKEY("DV_CAP")       { SET dvCap              TO opts["DV_CAP"]. }

    LOCAL best IS _peIncCost(nd, targetBody, targetPe, targetInc).
    LOCAL solved IS FALSE.
    mLog("PE/INC: coupled target Pe=" + ROUND(targetPe/1000, 1)
        + "km inc=" + ROUND(targetInc, 1) + "°"
        + " start Pe=" + ROUND(best["PE"]/1000, 1)
        + "km inc=" + ROUND(best["INC"], 1) + "°").
    mLogWarn("STATS pe-inc setup target=" + targetBody:NAME
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " targetInc=" + ROUND(targetInc,1)
        + " startPeKm=" + ROUND(best["PE"]/1000,1)
        + " startInc=" + ROUND(best["INC"],1)
        + " maxIter=" + maxIter
        + " dvCap=" + ROUND(dvCap,1)).

    FROM { LOCAL i IS 0. } UNTIL i >= maxIter STEP { SET i TO i + 1. } DO {
        LOCAL converged IS FALSE.
        IF best["PATCH"] <> 0 {
            IF ABS(best["PE_ERR"]) < 500 AND ABS(best["INC_ERR"]) < 0.5 {
                SET converged TO TRUE.
            }
        }
        IF converged {
            SET solved TO TRUE.
            mLog("  PE/INC[" + i + "] converged: Pe="
                + ROUND(best["PE"]/1000, 1) + "km inc="
                + ROUND(best["INC"], 1) + "°").
            BREAK.
        }

        LOCAL bestAxis IS "".
        LOCAL bestValue IS 0.
        LOCAL bestTrial IS best.

        FOR axis IN axes {
            LOCAL oldVal IS _nodeAxisGet(nd, axis).
            FOR sgn IN signs {
                LOCAL trialVal IS oldVal + sgn * steps[axis].
                _nodeAxisSet(nd, axis, trialVal).
                WAIT 0.02.

                IF dvCap < 0 OR nd:DELTAV:MAG <= dvCap {
                    LOCAL trial IS _peIncCost(nd, targetBody, targetPe, targetInc).
                    IF trial["COST"] < bestTrial["COST"] {
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
            SET best TO _peIncCost(nd, targetBody, targetPe, targetInc).
            mLog("  PE/INC[" + i + "] " + bestAxis
                + "=" + ROUND(bestValue, 2)
                + " Pe=" + ROUND(best["PE"]/1000, 1)
                + "km inc=" + ROUND(best["INC"], 1)
                + "° cost=" + ROUND(best["COST"], 2)).
        } ELSE {
            FOR axis IN axes {
                SET steps[axis] TO steps[axis] / 2.
            }
            mLog("  PE/INC[" + i + "] refining steps: N="
                + ROUND(steps["NORMAL"], 2)
                + " P=" + ROUND(steps["PROGRADE"], 2)
                + " R=" + ROUND(steps["RADIALOUT"], 2)).

            LOCAL stepsSmall IS FALSE.
            IF steps["NORMAL"] < minStep AND steps["PROGRADE"] < minStep {
                IF steps["RADIALOUT"] < minStep { SET stepsSmall TO TRUE. }
            }
            IF stepsSmall {
                mLogWarn("  PE/INC: stopped at Pe="
                    + ROUND(best["PE"]/1000, 1) + "km inc="
                    + ROUND(best["INC"], 1) + "°").
                BREAK.
            }
        }
    }

    IF NOT solved {
        SET best TO _peIncCost(nd, targetBody, targetPe, targetInc).
        mLogWarn("PE/INC final error: PeErr="
            + ROUND(best["PE_ERR"]/1000, 1) + "km incErr="
            + ROUND(best["INC_ERR"], 2) + "°").
    }

    SET best TO _peIncCost(nd, targetBody, targetPe, targetInc).
    mLogWarn("STATS pe-inc result target=" + targetBody:NAME
        + " solved=" + solved
        + " PeKm=" + ROUND(best["PE"]/1000,1)
        + " inc=" + ROUND(best["INC"],1)
        + " PeErrKm=" + ROUND(best["PE_ERR"]/1000,2)
        + " incErr=" + ROUND(best["INC_ERR"],2)
        + " cost=" + ROUND(best["COST"],2)
        + " dv=" + ROUND(nd:DELTAV:MAG,1)).

    RETURN best.
}

LOCAL FUNCTION _peIncCost {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER targetInc.

    LOCAL p IS _getTargetPatch(nd, targetBody).
    IF p = 0 {
        LOCAL miss IS LEXICON().
        miss:ADD("PATCH", 0).
        miss:ADD("PE", 0).
        miss:ADD("INC", 0).
        miss:ADD("PE_ERR", 9999999).
        miss:ADD("INC_ERR", 999).
        miss:ADD("COST", 999999999).
        RETURN miss.
    }

    RETURN _peIncPatchCost(p, targetPe, targetInc).
}

LOCAL FUNCTION _peIncPatchCost {
    PARAMETER p.
    PARAMETER targetPe.
    PARAMETER targetInc.

    LOCAL peErr IS p:PERIAPSIS - targetPe.
    LOCAL incErr IS p:INCLINATION - targetInc.
    IF incErr >  180 { SET incErr TO incErr - 360. }
    IF incErr < -180 { SET incErr TO incErr + 360. }

    // Inclination still dominates from an equatorial start, but PE must
    // become expensive once the plane is close. The previous 10 km scale
    // let a polar-but-impacting Mun trajectory look "good enough".
    LOCAL peScore IS peErr / 2000.
    LOCAL incScore IS incErr / 0.5.
    LOCAL cost IS peScore^2 + incScore^2.

    LOCAL result IS LEXICON().
    result:ADD("PATCH", 1).
    result:ADD("PE", p:PERIAPSIS).
    result:ADD("INC", p:INCLINATION).
    result:ADD("PE_ERR", peErr).
    result:ADD("INC_ERR", incErr).
    result:ADD("COST", cost).
    RETURN result.
}

// ============================================================
// _targetPatchElementsCoupled — coordinate search for PE/INC/LAN/AOP.
//
// Used as a final cleanup for precise capture geometry. It optimizes
// all requested patch elements together so a LAN or AoP correction can't
// quietly destroy periapsis or inclination. The TIME axis is included
// because LAN/AoP are often better changed by moving the correction node
// slightly along the transfer than by spending more normal/radial dV.
// ============================================================
LOCAL FUNCTION _targetPatchElementsCoupled {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targets.
    PARAMETER opts IS LEXICON().

    LOCAL axes IS LIST("PROGRADE", "NORMAL", "RADIALOUT", "TIME").
    LOCAL signs IS LIST(1, -1).
    LOCAL steps IS LEXICON().
    steps:ADD("PROGRADE", 1.0).
    steps:ADD("NORMAL", 1.0).
    steps:ADD("RADIALOUT", 1.0).
    steps:ADD("TIME", 30.0).

    LOCAL minStep IS 0.02.
    LOCAL maxIter IS 80.
    LOCAL dvCap IS -1.
    LOCAL minTime IS TIME:SECONDS + 30.

    IF opts:HASKEY("STEP_PROGRADE"){ SET steps["PROGRADE"]  TO opts["STEP_PROGRADE"]. }
    IF opts:HASKEY("STEP_NORMAL")  { SET steps["NORMAL"]    TO opts["STEP_NORMAL"]. }
    IF opts:HASKEY("STEP_RADIAL")  { SET steps["RADIALOUT"] TO opts["STEP_RADIAL"]. }
    IF opts:HASKEY("STEP_TIME")    { SET steps["TIME"]      TO opts["STEP_TIME"]. }
    IF opts:HASKEY("MIN_STEP")     { SET minStep            TO opts["MIN_STEP"]. }
    IF opts:HASKEY("MAX_ITER")     { SET maxIter            TO opts["MAX_ITER"]. }
    IF opts:HASKEY("DV_CAP")       { SET dvCap              TO opts["DV_CAP"]. }
    IF opts:HASKEY("MIN_TIME")     { SET minTime            TO opts["MIN_TIME"]. }

    LOCAL best IS _patchElementsCost(nd, targetBody, targets).
    LOCAL solved IS FALSE.
    mLog("ELEMENTS: coupled target"
        + _elementTargetSummary(targets)
        + " start" + _elementStateSummary(best)).
    mLogWarn("STATS elements setup target=" + targetBody:NAME
        + _elementTargetSummary(targets)
        + " start" + _elementStateSummary(best)
        + " maxIter=" + maxIter
        + " dvCap=" + ROUND(dvCap,1)).

    FROM { LOCAL i IS 0. } UNTIL i >= maxIter STEP { SET i TO i + 1. } DO {
        IF _elementsConverged(best, targets) {
            SET solved TO TRUE.
            mLog("  ELEMENTS[" + i + "] converged" + _elementStateSummary(best)).
            BREAK.
        }

        LOCAL bestAxis IS "".
        LOCAL bestValue IS 0.
        LOCAL bestTrial IS best.

        FOR axis IN axes {
            LOCAL oldVal IS _nodeAxisGet(nd, axis).
            FOR sgn IN signs {
                LOCAL trialVal IS oldVal + sgn * steps[axis].
                LOCAL timeOk IS TRUE.
                IF axis = "TIME" AND trialVal <= minTime { SET timeOk TO FALSE. }
                IF timeOk {
                    _nodeAxisSet(nd, axis, trialVal).
                    WAIT 0.02.

                    IF dvCap < 0 OR nd:DELTAV:MAG <= dvCap {
                        LOCAL trial IS _patchElementsCost(nd, targetBody, targets).
                        IF trial["COST"] < bestTrial["COST"] {
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
            SET best TO _patchElementsCost(nd, targetBody, targets).
            mLog("  ELEMENTS[" + i + "] " + bestAxis
                + "=" + ROUND(bestValue, 2)
                + _elementStateSummary(best)
                + " cost=" + ROUND(best["COST"], 2)).
        } ELSE {
            FOR axis IN axes {
                SET steps[axis] TO steps[axis] / 2.
            }
            mLog("  ELEMENTS[" + i + "] refining steps: P="
                + ROUND(steps["PROGRADE"], 2)
                + " N=" + ROUND(steps["NORMAL"], 2)
                + " R=" + ROUND(steps["RADIALOUT"], 2)
                + " T=" + ROUND(steps["TIME"], 1)).

            LOCAL stepsSmall IS FALSE.
            IF steps["PROGRADE"] < minStep AND steps["NORMAL"] < minStep {
                IF steps["RADIALOUT"] < minStep AND steps["TIME"] < 1 {
                    SET stepsSmall TO TRUE.
                }
            }
            IF stepsSmall {
                mLogWarn("  ELEMENTS: stopped" + _elementStateSummary(best)).
                BREAK.
            }
        }
    }

    IF NOT solved {
        SET best TO _patchElementsCost(nd, targetBody, targets).
        mLogWarn("ELEMENTS final error" + _elementErrorSummary(best, targets)).
    }

    SET best TO _patchElementsCost(nd, targetBody, targets).
    mLogWarn("STATS elements result target=" + targetBody:NAME
        + " solved=" + solved
        + _elementStateSummary(best)
        + _elementErrorSummary(best, targets)
        + " cost=" + ROUND(best["COST"],2)
        + " dv=" + ROUND(nd:DELTAV:MAG,1)).

    RETURN best.
}

LOCAL FUNCTION _patchElementsCost {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targets.

    LOCAL p IS _getTargetPatch(nd, targetBody).
    IF p = 0 {
        LOCAL miss IS LEXICON().
        miss:ADD("PATCH", 0).
        miss:ADD("PE", 0).
        miss:ADD("INC", 0).
        miss:ADD("LAN", 0).
        miss:ADD("AOP", 0).
        miss:ADD("PE_ERR", 9999999).
        miss:ADD("INC_ERR", 999).
        miss:ADD("LAN_ERR", 999).
        miss:ADD("AOP_ERR", 999).
        miss:ADD("COST", 999999999).
        RETURN miss.
    }

    RETURN _patchElementsCostFromPatch(p, targets).
}

LOCAL FUNCTION _patchElementsCostFromPatch {
    PARAMETER p.
    PARAMETER targets.

    LOCAL peErr IS 0.
    LOCAL incErr IS 0.
    LOCAL lanErr IS 0.
    LOCAL aopErr IS 0.
    LOCAL cost IS 0.

    IF targets:HASKEY("PE") {
        SET peErr TO p:PERIAPSIS - targets["PE"].
        SET cost TO cost + (peErr / 2000)^2.
    }
    IF targets:HASKEY("INC") {
        SET incErr TO _angleError(p:INCLINATION, targets["INC"]).
        SET cost TO cost + (incErr / 0.5)^2.
    }
    IF targets:HASKEY("LAN") {
        SET lanErr TO _angleError(p:LAN, targets["LAN"]).
        SET cost TO cost + (lanErr / 1.0)^2.
    }
    IF targets:HASKEY("AOP") {
        SET aopErr TO _angleError(p:ARGUMENTOFPERIAPSIS, targets["AOP"]).
        SET cost TO cost + (aopErr / 1.0)^2.
    }

    LOCAL result IS LEXICON().
    result:ADD("PATCH", 1).
    result:ADD("PE", p:PERIAPSIS).
    result:ADD("INC", p:INCLINATION).
    result:ADD("LAN", p:LAN).
    result:ADD("AOP", p:ARGUMENTOFPERIAPSIS).
    result:ADD("PE_ERR", peErr).
    result:ADD("INC_ERR", incErr).
    result:ADD("LAN_ERR", lanErr).
    result:ADD("AOP_ERR", aopErr).
    result:ADD("COST", cost).
    RETURN result.
}

LOCAL FUNCTION _elementsConverged {
    PARAMETER eval.
    PARAMETER targets.
    IF eval["PATCH"] = 0 { RETURN FALSE. }
    IF targets:HASKEY("PE") {
        IF ABS(eval["PE_ERR"]) > 500 { RETURN FALSE. }
    }
    IF targets:HASKEY("INC") {
        IF ABS(eval["INC_ERR"]) > 0.5 { RETURN FALSE. }
    }
    IF targets:HASKEY("LAN") {
        IF ABS(eval["LAN_ERR"]) > 1.0 { RETURN FALSE. }
    }
    IF targets:HASKEY("AOP") {
        IF ABS(eval["AOP_ERR"]) > 1.0 { RETURN FALSE. }
    }
    RETURN TRUE.
}

LOCAL FUNCTION _angleError {
    PARAMETER current.
    PARAMETER target.
    LOCAL err IS current - target.
    IF err >  180 { SET err TO err - 360. }
    IF err < -180 { SET err TO err + 360. }
    RETURN err.
}

LOCAL FUNCTION _elementTargetSummary {
    PARAMETER targets.
    LOCAL msg IS "".
    IF targets:HASKEY("PE")  { SET msg TO msg + " Pe=" + ROUND(targets["PE"]/1000, 1) + "km". }
    IF targets:HASKEY("INC") { SET msg TO msg + " INC=" + ROUND(targets["INC"], 1) + "°". }
    IF targets:HASKEY("LAN") { SET msg TO msg + " LAN=" + ROUND(targets["LAN"], 1) + "°". }
    IF targets:HASKEY("AOP") { SET msg TO msg + " AoP=" + ROUND(targets["AOP"], 1) + "°". }
    RETURN msg.
}

LOCAL FUNCTION _elementStateSummary {
    PARAMETER eval.
    IF eval["PATCH"] = 0 { RETURN " no-patch". }
    RETURN " Pe=" + ROUND(eval["PE"]/1000, 1)
        + "km INC=" + ROUND(eval["INC"], 1)
        + "° LAN=" + ROUND(eval["LAN"], 1)
        + "° AoP=" + ROUND(eval["AOP"], 1) + "°".
}

LOCAL FUNCTION _elementErrorSummary {
    PARAMETER eval.
    PARAMETER targets.
    LOCAL msg IS "".
    IF targets:HASKEY("PE")  { SET msg TO msg + " PeErr=" + ROUND(eval["PE_ERR"]/1000, 1) + "km". }
    IF targets:HASKEY("INC") { SET msg TO msg + " IncErr=" + ROUND(eval["INC_ERR"], 2) + "°". }
    IF targets:HASKEY("LAN") { SET msg TO msg + " LanErr=" + ROUND(eval["LAN_ERR"], 2) + "°". }
    IF targets:HASKEY("AOP") { SET msg TO msg + " AopErr=" + ROUND(eval["AOP_ERR"], 2) + "°". }
    RETURN msg.
}

LOCAL FUNCTION _nodeAxisGet {
    PARAMETER nd.
    PARAMETER axis.
    IF axis = "PROGRADE"  { RETURN nd:PROGRADE. }
    IF axis = "NORMAL"    { RETURN nd:NORMAL. }
    IF axis = "RADIALOUT" { RETURN nd:RADIALOUT. }
    IF axis = "TIME"      { RETURN nd:TIME. }
    RETURN 0.
}

LOCAL FUNCTION _nodeAxisSet {
    PARAMETER nd.
    PARAMETER axis.
    PARAMETER value.
    IF axis = "PROGRADE"  { SET nd:PROGRADE  TO value. }
    IF axis = "NORMAL"    { SET nd:NORMAL    TO value. }
    IF axis = "RADIALOUT" { SET nd:RADIALOUT TO value. }
    IF axis = "TIME"      { SET nd:TIME      TO value. }
}

// ============================================================
// newtonTarget — unified Newton-Raphson for any orbital param.
//
// param: "PE" (prograde), "INC" (normal), "LAN" (normal), "AOP" (radial)
// opts (optional LEXICON):
//   BIAS    — seed value for the axis when it's zero (e.g. ±5 for polar)
//   DV_CAP  — max total node dV; aborts if exceeded (used by MCC)
//   TOL     — convergence tolerance (default: 500m for PE, 0.5° for angles)
//   DAMP    — damping factor (default: 0.5 for PE, 0.7 for angles)
//   HOLD    — LEXICON("PARAM", name, "VALUE", target) — after each
//             primary correction, apply a compensating single Newton
//             step on the held axis to maintain its target. Used to
//             keep INC locked while converging PE.
//
// Accepts negative PE encounters (trajectory below surface). The
// closest-approach optimizer may produce a dead-center trajectory
// with PE deep below the surface — the orbital elements are still
// well-defined and Newton can raise PE from there. Only a truly
// missing encounter (no patch) triggers backtracking.
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

    // HOLD constraint: after each primary correction, compensate drift
    // on a secondary axis with a single Newton step.
    LOCAL holdParam IS "".
    LOCAL holdValue IS 0.
    IF opts:HASKEY("HOLD") {
        SET holdParam TO opts["HOLD"]["PARAM"].
        SET holdValue TO opts["HOLD"]["VALUE"].
    }

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
        IF p = 0 {
            // No encounter patch at all — backtrack toward last good value
            LOCAL midVal IS (_ntGetAxis(nd, param) + lastGood) / 2.
            _ntSetAxis(nd, param, midVal).
            WAIT 0.02.
            LOCAL pMid IS _getTargetPatch(nd, targetBody).
            IF pMid <> 0 {
                SET lastGood TO midVal.
                SET stepScale TO stepScale * 0.5.
                mLog("  " + label + "[" + i + "]: backtracked.").
            } ELSE {
                _ntSetAxis(nd, param, lastGood).
                SET stepScale TO stepScale * 0.5.
                IF stepScale < 0.05 {
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

            // Finite difference for sensitivity — try +eps, fall back to -eps
            LOCAL oldVal IS _ntGetAxis(nd, param).
            _ntSetAxis(nd, param, oldVal + eps).
            WAIT 0.02.
            LOCAL p2 IS _getTargetPatch(nd, targetBody).
            LOCAL probeSign IS 1.
            IF p2 = 0 {
                // +eps lost encounter, try -eps
                _ntSetAxis(nd, param, oldVal - eps).
                WAIT 0.02.
                SET p2 TO _getTargetPatch(nd, targetBody).
                SET probeSign TO -1.
                IF p2 = 0 {
                    _ntSetAxis(nd, param, oldVal).
                    mLog("  " + label + "[" + i + "]: probe lost encounter both dirs.").
                    BREAK.
                }
            }
            _ntSetAxis(nd, param, oldVal).

            LOCAL current2 IS _ntReadParam(p2, param).
            LOCAL delta IS current2 - current.
            IF isAngle {
                IF delta >  180 { SET delta TO delta - 360. }
                IF delta < -180 { SET delta TO delta + 360. }
            }

            LOCAL sens IS delta / (eps * probeSign).
            IF ABS(sens) < 0.001 {
                mLog("  " + label + "[" + i + "]: low sensitivity, skipping.").
            } ELSE {
                LOCAL correction IS (err / sens) * damp.
                LOCAL maxStep IS CHOOSE MAX(5.0, ABS(err) / 3) IF isAngle ELSE MIN(20, MAX(3.0, ABS(err) / 10000)).
                SET maxStep TO maxStep * stepScale.
                IF correction >  maxStep { SET correction TO  maxStep. }
                IF correction < -maxStep { SET correction TO -maxStep. }

                _ntSetAxis(nd, param, oldVal + correction).
                WAIT 0.02.

                // dV cap check (MCC) — per-axis so INC (normal) and PE
                // (prograde) don't compete for the same budget.
                IF dvCap >= 0 AND ABS(_ntGetAxis(nd, param)) > dvCap {
                    _ntSetAxis(nd, param, lastGood).
                    mLog("  " + label + "[" + i + "]: dV cap (" + dvCap + " m/s) reached.").
                    BREAK.
                }

                // Verify encounter survives the correction
                LOCAL pCheck IS _getTargetPatch(nd, targetBody).
                IF pCheck = 0 {
                    _ntSetAxis(nd, param, oldVal + correction / 2).
                    WAIT 0.02.
                    LOCAL pHalf IS _getTargetPatch(nd, targetBody).
                    IF pHalf = 0 {
                        _ntSetAxis(nd, param, lastGood).
                        SET stepScale TO stepScale * 0.5.
                        mLog("  " + label + "[" + i + "]: correction lost encounter, reverted.").
                    }
                }

                mLog("  " + label + "[" + i + "] " + ROUND(current, 1) + " corr=" + ROUND(correction, 2) + " m/s").

                // --- HOLD compensation ---
                // After each primary correction, apply a single Newton step
                // on the held axis to compensate for coupling drift.
                IF holdParam <> "" {
                    LOCAL hp IS _getTargetPatch(nd, targetBody).
                    IF hp <> 0 {
                        LOCAL hIsAngle IS (holdParam <> "PE").
                        LOCAL hCurrent IS _ntReadParam(hp, holdParam).
                        LOCAL hErr IS holdValue - hCurrent.
                        IF hIsAngle {
                            IF hErr >  180 { SET hErr TO hErr - 360. }
                            IF hErr < -180 { SET hErr TO hErr + 360. }
                        }
                        LOCAL hTol IS CHOOSE 0.5 IF hIsAngle ELSE 500.
                        IF ABS(hErr) > hTol {
                            LOCAL hOld IS _ntGetAxis(nd, holdParam).
                            LOCAL hEps IS CHOOSE 0.5 IF hIsAngle ELSE 0.1.
                            _ntSetAxis(nd, holdParam, hOld + hEps).
                            WAIT 0.02.
                            LOCAL hp2 IS _getTargetPatch(nd, targetBody).
                            IF hp2 <> 0 {
                                LOCAL hCurrent2 IS _ntReadParam(hp2, holdParam).
                                LOCAL hDelta IS hCurrent2 - hCurrent.
                                IF hIsAngle {
                                    IF hDelta >  180 { SET hDelta TO hDelta - 360. }
                                    IF hDelta < -180 { SET hDelta TO hDelta + 360. }
                                }
                                LOCAL hSens IS hDelta / hEps.
                                IF ABS(hSens) > 0.001 {
                                    LOCAL hCorr IS (hErr / hSens) * 0.7.
                                    _ntSetAxis(nd, holdParam, hOld + hCorr).
                                    WAIT 0.02.
                                    // Verify encounter survived
                                    IF _getTargetPatch(nd, targetBody) = 0 {
                                        _ntSetAxis(nd, holdParam, hOld).
                                    }
                                } ELSE {
                                    _ntSetAxis(nd, holdParam, hOld).
                                }
                            } ELSE {
                                _ntSetAxis(nd, holdParam, hOld).
                            }
                        }
                    }
                }
            }
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
    mLog("Capture node: dV=" + ROUND(dv,1)
        + " m/s at Pe in " + ROUND(ETA:PERIAPSIS,0)
        + "s  targetAp=" + ROUND(targetAlt/1000,1) + "km").
    archivePlannedManeuverLog("capture").
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
    mLog("Raise Pe node: dV=" + ROUND(dv,1)
        + " m/s  targetPe=" + ROUND(targetPe/1000,1) + "km").
    archivePlannedManeuverLog("raise-pe").
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
    mLog("AoP node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s  targetAoP=" + ROUND(targetAoP,1)
        + " ETA=" + ROUND(burnETA,0) + "s").
    archivePlannedManeuverLog("aop").
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
    // requested we score all requested elements together.
    LOCAL preCost IS 0.
    IF useElementSolver {
        LOCAL preElemEval IS _patchElementsCostFromPatch(patch, elementTargets).
        SET preCost TO preElemEval["COST"].
        LOCAL elemOpts IS LEXICON().
        elemOpts:ADD("DV_CAP", MCC_DV_CAP).
        elemOpts:ADD("STEP_NORMAL", 2.0).
        elemOpts:ADD("STEP_PROGRADE", 1.0).
        elemOpts:ADD("STEP_RADIAL", 1.0).
        elemOpts:ADD("STEP_TIME", 120.0).
        elemOpts:ADD("MIN_STEP", 0.02).
        elemOpts:ADD("MAX_ITER", 100).
        elemOpts:ADD("MIN_TIME", TIME:SECONDS + 60).
        _targetPatchElementsCoupled(nd, target, elementTargets, elemOpts).
    } ELSE IF targetInc >= 0 {
        LOCAL prePeEval IS _peIncPatchCost(patch, targetPe, targetInc).
        SET preCost TO prePeEval["COST"].
        LOCAL coupledOpts IS LEXICON().
        coupledOpts:ADD("DV_CAP", MCC_DV_CAP).
        coupledOpts:ADD("STEP_NORMAL", 2.0).
        coupledOpts:ADD("STEP_PROGRADE", 1.0).
        coupledOpts:ADD("STEP_RADIAL", 1.0).
        coupledOpts:ADD("MIN_STEP", 0.02).
        coupledOpts:ADD("MAX_ITER", 80).
        _targetPeIncCoupled(nd, target, targetPe, targetInc, 0, coupledOpts).
    } ELSE {
        newtonTarget(nd, target, "PE", targetPe, mccOpts).
    }

    WAIT 0.1.

    LOCAL totalDv IS nd:DELTAV:MAG.
    LOCAL finalPatch IS _getTargetPatch(nd, target).

    LOCAL worsened IS FALSE.
    IF useElementSolver AND finalPatch <> 0 {
        LOCAL finalElemEval IS _patchElementsCostFromPatch(finalPatch, elementTargets).
        LOCAL finalElemCost IS finalElemEval["COST"].
        IF finalElemCost > preCost * 1.05 { SET worsened TO TRUE. }
        IF ABS(finalElemEval["PE_ERR"]) > 100000 { SET worsened TO TRUE. }
    } ELSE IF targetInc >= 0 AND finalPatch <> 0 {
        LOCAL finalPeEval IS _peIncPatchCost(finalPatch, targetPe, targetInc).
        LOCAL finalPeCost IS finalPeEval["COST"].
        IF finalPeCost > preCost * 1.05 { SET worsened TO TRUE. }
        IF ABS(finalPatch:PERIAPSIS - targetPe) > 100000 { SET worsened TO TRUE. }
    }

    IF totalDv < 0.1 OR finalPatch = 0 OR worsened {
        IF worsened {
            mLogWarn("MCC made approach worse; skipping correction node.").
        }
        mLog("Encounter on target. Skipping MCC burn.").
        mLogWarn("STATS mcc result target=" + target:NAME
            + " status=skipped dv=" + ROUND(totalDv,1)
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
