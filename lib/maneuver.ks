// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
// ============================================================

LOCAL COMPLETE_FRAC        IS 0.001.
LOCAL ABS_CUTOFF           IS 0.0001.
LOCAL ALIGN_TOLERANCE      IS 2.0.
LOCAL HIBERNATE_THRESHOLD  IS 300.
LOCAL HIBERNATE_WAKE_LEAD  IS 180.

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

GLOBAL FUNCTION planTransfer {
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER lanTarget IS -1.
    PARAMETER aopTarget IS -1.

    LOCAL centralBody IS BODY.
    LOCAL mu          IS centralBody:MU.

    // Detect whether the target is a local moon (orbits same body as ship)
    // or an interplanetary body (orbits a different parent).
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

    // --- Newton-Raphson PE targeting (shared by both paths) ---
    _newtonPeTarget(nd, targetBody, targetPe).

    // --- Inclination targeting ---
    // Uses normal dV to steer capture orbit to desired inclination.
    // normalBias seeds the solver direction: +1 prograde-side polar,
    // -1 retrograde-side polar (produces different LAN).
    IF captureInc >= 0 {
        _newtonIncTarget(nd, targetBody, captureInc, normalBias).
        // Re-run PE targeting to correct drift from normal dV changes
        _newtonPeTarget(nd, targetBody, targetPe).
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
LOCAL FUNCTION _newtonPeTarget {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targetPe.

    mLog("PE: Targeting " + ROUND(targetPe/1000, 1) + "km.").
    LOCAL peIter IS 35.
    LOCAL peEps  IS 0.1.
    LOCAL peDamp IS 0.5.
    LOCAL lastGoodPrograde IS nd:PROGRADE.

    FROM { LOCAL i IS 0. } UNTIL i >= peIter STEP { SET i TO i + 1. } DO {
        LOCAL p IS _getTargetPatch(nd, targetBody).
        IF p = 0 OR p:PERIAPSIS < 0 {
            mLog("PE[" + i + "]: lost encounter, reverting.").
            SET nd:PROGRADE TO lastGoodPrograde.
            BREAK.
        }
        SET lastGoodPrograde TO nd:PROGRADE.
        LOCAL peErr IS targetPe - p:PERIAPSIS.
        IF ABS(peErr) < 500 {
            mLog("PE[" + i + "] converged: " + ROUND(p:PERIAPSIS/1000,1) + "km (err " + ROUND(peErr,0) + "m)").
            BREAK.
        }
        LOCAL oldDv IS nd:PROGRADE.
        SET nd:PROGRADE TO oldDv + peEps.
        WAIT 0.02.
        LOCAL p2 IS _getTargetPatch(nd, targetBody).
        SET nd:PROGRADE TO oldDv.
        IF p2 = 0 { BREAK. }
        LOCAL sens IS (p2:PERIAPSIS - p:PERIAPSIS) / peEps.
        IF ABS(sens) < 0.001 { BREAK. }
        LOCAL correction IS (peErr / sens) * peDamp.
        // Proportional clamp: allow larger steps for larger errors
        LOCAL maxStep IS MAX(3.0, ABS(peErr) / 5000).
        IF correction >  maxStep { SET correction TO  maxStep. }
        IF correction < -maxStep { SET correction TO -maxStep. }
        SET nd:PROGRADE TO oldDv + correction.
        WAIT 0.05.
        mLog("PE[" + i + "] Pe=" + ROUND(p:PERIAPSIS/1000,1) + "km  corr=" + ROUND(correction,2) + " m/s").
    }
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

LOCAL FUNCTION _getTargetPatch {
    PARAMETER originTarget.
    PARAMETER targetBody.
    LOCAL p IS originTarget:ORBIT.
    UNTIL NOT p:HASNEXTPATCH {
        SET p TO p:NEXTPATCH.
        IF p:BODY:NAME = targetBody:NAME { RETURN p. }
    }
    RETURN 0.
}
