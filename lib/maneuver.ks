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
LOCAL MCC_MIN_DV           IS 2.0.
LOCAL MCC_LATE_MIN_DV      IS 3.0.
LOCAL MCC_LATE_ETA         IS 7200.

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
    _wakeCmd().
    _markPendingBurn(nd, burnDV, startTime).

    IF burnDV < 10 { _setThrustLimit(0.25). }
    IF burnDV < 2  { _setThrustLimit(0.10). }
    IF burnDV < 0.5 { _setThrustLimit(0.05). }

    IF startTime < TIME:SECONDS {
        mLogWarn("Burn window already passed by " + ROUND(TIME:SECONDS - startTime, 0) + "s — removing node.").
        HUDTEXT("Burn window missed — replanning", 5, 2, 15, YELLOW, FALSE).
        REMOVE nd.
        _clearPendingBurn("missed-window").
        RETURN FALSE.
    }

    mLog("Maneuver: dV=" + ROUND(burnDV,1) + " m/s  ETA=" + ROUND(startTime - TIME:SECONDS,1) + "s").
    mLogWarn("STATS burn setup dv=" + ROUND(burnDV,1)
        + " eta=" + ROUND(startTime - TIME:SECONDS,1)
        + " nodeEta=" + ROUND(nd:ETA,1)
        + " body=" + SHIP:BODY:NAME
        + " maxAcc=" + ROUND(_safeMaxAcc(),2)).
    IF _safeMaxAcc() <= 0 {
        mLogWarn("STATS burn thrust status=no-thrust maxThrust="
            + ROUND(SHIP:MAXTHRUST,1)
            + " availThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).
    }

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
        mLog("Long coast wait (" + ROUND(wakeTime - TIME:SECONDS, 0) + "s).").
        HUDTEXT("Coasting. Burn in " + ROUND(startTime - TIME:SECONDS, 0) + "s", 5, 2, 13, CYAN, FALSE).
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

    LOCAL alignDeadline IS startTime - 5.
    UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ALIGN_TOLERANCE
            OR TIME:SECONDS >= alignDeadline {
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT 0.1.
    }

    LOCAL alignErr IS VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR).
    mLogWarn("STATS burn align angle=" + ROUND(alignErr,1)
        + " tol=" + ALIGN_TOLERANCE
        + " timeToBurn=" + ROUND(startTime - TIME:SECONDS,1)).
    IF alignErr >= ALIGN_TOLERANCE {
        mLogWarn("Burn starting with " + ROUND(alignErr,1) + "° misalignment.").
    } ELSE {
        mLog("Aligned. Waiting for burn window...").
    }

    WAIT UNTIL TIME:SECONDS >= alignDeadline.
    HUDTEXT("Burn in T-4", 3, 2, 15, WHITE, FALSE).
    countdown(4).

    WAIT UNTIL TIME:SECONDS >= startTime.
    mLog("Burn start. dV=" + ROUND(burnDV,1) + " m/s").
    LOCAL burnStartClock IS TIME:SECONDS.

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
    _clearPendingBurn("complete").

    // Clean up the KAC alarm now that the burn is done.
    IF kacAlarmId <> "" {
        DELETEALARM(kacAlarmId).
    }

    mLog("Burn complete. Residual dV ~" + ROUND(residual, 2) + " m/s.").
    mLogWarn("STATS burn result dv=" + ROUND(burnDV,1)
        + " residual=" + ROUND(residual,2)
        + " duration=" + ROUND(TIME:SECONDS - burnStartClock,1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)).
    HUDTEXT("Burn complete", 3, 2, 15, GREEN, FALSE).
    RETURN TRUE.
}

GLOBAL FUNCTION archivePlannedManeuverLog {
    PARAMETER label IS "maneuver".
    IF HOMECONNECTION:ISCONNECTED {
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
    mLogWarn("STATS circularize plan dv=" + ROUND(dv,1)
        + " eta=" + ROUND(etaApo,0)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    archivePlannedManeuverLog("circularize").
    RETURN nd.
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
//   2. Element-aware seed scoring — prefer departure windows that
//      already produce the requested PE/INC/LAN/AoP geometry.
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

    // Resolve capture orbit direction before seeding the raw transfer
    // so the coarse departure scans can prefer windows that already
    // arrive with the right apsidal geometry.
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

    // --- 1. Build raw node ---
    LOCAL nd IS 0.
    IF isLocal {
        SET nd TO _planLocalTransfer(targetBody, targetPe, captureInc, lanTarget, aopTarget, centralBody, mu).
    } ELSE {
        SET nd TO planInterplanetaryTransfer(targetBody, targetPe, captureInc, lanTarget, aopTarget, centralBody, mu).
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
    // --- 4. Final targeting ---
    // Solve PE (and optionally INC, LAN, AoP) as a coupled coordinate
    // search. A one-axis Newton step is fragile at near-collision Mun
    // encounters: tiny normal probes may not visibly change the patched
    // conic inclination even though larger normal/radial/prograde moves do.
    // The unified element solver handles all combinations — when only PE
    // and INC are requested the TIME axis is inert and it reduces to the
    // same 3-axis search the old _targetPeIncCoupled performed.
    LOCAL elemTargets IS LEXICON().
    elemTargets:ADD("PE", targetPe).
    IF captureInc >= 0 { elemTargets:ADD("INC", captureInc). }
    IF lanTarget >= 0 { elemTargets:ADD("LAN", lanTarget). }
    IF aopTarget >= 0 { elemTargets:ADD("AOP", aopTarget). }

    IF elemTargets:LENGTH > 1 OR lanTarget >= 0 OR aopTarget >= 0 {
        elemTargets:ADD("PE_FLOOR", -25000).

        // Seed normal bias for polar/retropolar before the solver starts
        IF normalBias <> 0 AND nd:NORMAL = 0 {
            SET nd:NORMAL TO normalBias * 5.
            WAIT 0.02.
        }

        IF captureInc >= 0 AND (lanTarget >= 0 OR aopTarget >= 0) {
            // First recover the arrival plane and periapsis using the
            // wide PE/INC search that worked well before AoP/LAN were
            // folded into this routine. Without this staging, the full
            // solver can accept a wildly sub-surface Pe because the
            // inclination/AoP cost appears to improve.
            LOCAL planeTargets IS LEXICON().
            planeTargets:ADD("PE", targetPe).
            planeTargets:ADD("PE_FLOOR", -25000).
            planeTargets:ADD("INC", captureInc).

            LOCAL planeOpts IS LEXICON().
            planeOpts:ADD("STEP_NORMAL", 40.0).
            planeOpts:ADD("STEP_PROGRADE", 20.0).
            planeOpts:ADD("STEP_RADIAL", 20.0).
            planeOpts:ADD("STEP_TIME", 60.0).
            planeOpts:ADD("MIN_STEP", 0.05).
            planeOpts:ADD("MAX_ITER", 120).
            mLogWarn("STATS elements stage=plane-pe-inc before full targeting.").
            LOCAL planeResult IS _targetPatchElementsCoupled(nd, targetBody, planeTargets, planeOpts).
            IF planeResult:HASKEY("SOLVED") AND NOT planeResult["SOLVED"] {
                mLogError("planTransfer: PE/INC targeting failed; refusing bad transfer node.").
                mLogWarn("STATS transfer result target=" + targetBody:NAME
                    + " status=plane-elements-failed"
                    + _elementErrorSummary(planeResult, planeTargets)).
                IF HASNODE { REMOVE nd. }
                RETURN.
            }
        }

        LOCAL elemOpts IS LEXICON().
        elemOpts:ADD("STEP_NORMAL", CHOOSE 10.0 IF captureInc >= 0 ELSE 5.0).
        elemOpts:ADD("STEP_PROGRADE", CHOOSE 5.0 IF captureInc >= 0 ELSE 2.0).
        elemOpts:ADD("STEP_RADIAL", CHOOSE 10.0 IF captureInc >= 0 ELSE 5.0).
        elemOpts:ADD("STEP_TIME", 60.0).
        elemOpts:ADD("MIN_STEP", 0.05).
        elemOpts:ADD("MAX_ITER", CHOOSE 100 IF captureInc >= 0 ELSE 100).
        LOCAL elemResult IS _targetPatchElementsCoupled(nd, targetBody, elemTargets, elemOpts).
        IF elemResult:HASKEY("SOLVED") AND NOT elemResult["SOLVED"] {
            mLogError("planTransfer: element targeting failed; refusing bad transfer node.").
            mLogWarn("STATS transfer result target=" + targetBody:NAME
                + " status=elements-failed"
                + _elementErrorSummary(elemResult, elemTargets)).
            IF HASNODE { REMOVE nd. }
            RETURN.
        }
    } ELSE {
        newtonTarget(nd, targetBody, "PE", targetPe).
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
    LOCAL scanSteps IS nScanOrbits * 4.  // 4 samples per orbit
    LOCAL scanDt IS shipPeriod / 4.

    LOCAL bestTime IS departUt.
    LOCAL bestCA IS _findClosestApproach(targetBody, departUt + hohmannTof * 0.5, departUt + hohmannTof * 1.5, 40).
    LOCAL bestSeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, bestCA["distance"], nd:DELTAV:MAG).

    mLog("Element-aware transfer scan: " + scanSteps + " steps over ±" + nScanOrbits + " orbits").

    FROM { LOCAL si IS -scanSteps. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTime IS departUt + si * scanDt.
        IF tryTime > TIME:SECONDS + 30 {
            SET nd:TIME TO tryTime.
            WAIT 0.02.
            LOCAL tryCa IS _findClosestApproach(targetBody, tryTime + hohmannTof * 0.5, tryTime + hohmannTof * 1.5, 40).
            LOCAL trySeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, tryCa["distance"], nd:DELTAV:MAG).
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

    // --- Golden section refine departure time ---
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

    LOCAL finalCA IS _findClosestApproach(targetBody, nd:TIME + hohmannTof * 0.3, nd:TIME + hohmannTof * 2.0, 60).
    LOCAL finalSeed IS _transferSeedScore(nd, targetBody, targetPe, captureInc, lanTarget, aopTarget, finalCA["distance"], nd:DELTAV:MAG).
    mLog("Optimized: CA=" + ROUND(finalCA["distance"]/1000, 1) + "km"
        + " score=" + ROUND(finalSeed["SCORE"], 2)
        + " AoPerr=" + ROUND(finalSeed["AOP_ERR"], 1)
        + "  dV=" + ROUND(nd:PROGRADE, 1) + " m/s"
        + "  depart T+" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    mLogWarn("STATS local-transfer target=" + targetBody:NAME
        + " caKm=" + ROUND(finalCA["distance"]/1000,1)
        + " score=" + ROUND(finalSeed["SCORE"],2)
        + " patch=" + finalSeed["PATCH"]
        + " incErr=" + ROUND(finalSeed["INC_ERR"],1)
        + " lanErr=" + ROUND(finalSeed["LAN_ERR"],1)
        + " aopErr=" + ROUND(finalSeed["AOP_ERR"],1)
        + " prograde=" + ROUND(nd:PROGRADE,1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).

    // --- Optional LAN scan ---
    // If lanTarget is specified, scan across multiple orbits to find the departure
    // that produces the closest LAN at the target body (read from KSP's conics).
    IF lanTarget >= 0 AND aopTarget < 0 {
        SET nd TO _scanForLan(nd, targetBody, lanTarget, shipPeriod).
    }

    RETURN nd.
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
    mLogWarn("STATS capture plan target=" + targetBody:NAME
        + " dv=" + ROUND(dv,1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " targetApKm=" + ROUND(targetAlt/1000,1)
        + " etaPe=" + ROUND(ETA:PERIAPSIS,0)).
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
    mLogWarn("STATS raise-pe plan dv=" + ROUND(dv,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    archivePlannedManeuverLog("raise-pe").
    RETURN nd.
}

GLOBAL FUNCTION planLowerPe {
    PARAMETER targetPe.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL burnTime IS TIME:SECONDS + ETA:APOAPSIS.
    LOCAL rBurn IS bodyR + SHIP:APOAPSIS.
    LOCAL rTarget IS bodyR + targetPe.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(burnTime, 0, 0, vNew - vNow).
    ADD nd.
    mLog("Lower Pe node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPe=" + ROUND(targetPe/1000,1) + "km").
    mLogWarn("STATS lower-pe plan dv=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " etaAp=" + ROUND(ETA:APOAPSIS,0)).
    archivePlannedManeuverLog("lower-pe").
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

LOCAL FUNCTION _markPendingBurn {
    PARAMETER nd.
    PARAMETER burnDV.
    PARAMETER startTime.
    stateSet("burn_pending", "true").
    stateSet("burn_phase", stateGet("phase", "")).
    stateSetNum("burn_node_time", nd:TIME).
    stateSetNum("burn_start_time", startTime).
    stateSetNum("burn_dv", burnDV).
}

LOCAL FUNCTION _clearPendingBurn {
    PARAMETER reason.
    IF stateGet("burn_pending", "") = "true" {
        mLog("Clearing pending burn state: " + reason + ".").
    }
    FOR key IN LIST(
        "burn_pending", "burn_phase", "burn_node_time",
        "burn_start_time", "burn_dv"
    ) {
        stateRemove(key).
    }
}

LOCAL FUNCTION _wakeCmd {
    LOCAL cm IS _findCmdModule().
    IF cm = 0 { RETURN. }
    IF cm:HASFIELD("hibernation") { cm:SETFIELD("hibernation", FALSE). }
}
