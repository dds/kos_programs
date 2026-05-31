// ============================================================
// xfer.ks  —  Transfer & arrival phases  (0:/lib/xfer.ks)
// ============================================================

GLOBAL xferSeq IS LIST().

LOCAL MAX_RETRIES IS 5.

GLOBAL FUNCTION phaseTransfer {
    LOCAL target IS missionTargetBody().
    orbitSummary().
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        LOCAL xLan IS -1.
        LOCAL xAoP IS -1.
        IF CFG:HASKEY("CAPTURE_LAN") { SET xLan TO CFG["CAPTURE_LAN"]. }
        IF CFG:HASKEY("CAPTURE_AOP") { SET xAoP TO CFG["CAPTURE_AOP"]. }
        planTransfer(target, CFG["CAPTURE_PE"], xLan, xAoP).
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Transfer missed (attempt " + retries + ") — waiting 10s and replanning.").
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            IF retries >= MAX_RETRIES {
                mLogError("Transfer failed after " + retries + " attempts — halting.").
                RETURN.
            }
            WAIT 10.
        }
    }
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCoast {
    LOCAL target IS missionTargetBody().
    SET SAS TO TRUE.
    UNLOCK STEERING.
    mLog("Coasting to " + target:NAME + " SOI.").
    waitForSOI(target).
    orbitSummary().
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCapture {
    LOCAL target IS missionTargetBody().
    WAIT 2.
    mLog("Planning capture into elliptical orbit at " + target:NAME + ".").
    
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        
        // 1. Resolve target altitude from config
        LOCAL captureAlt IS CFG["RELAY_ALT"].
        IF CFG:HASKEY("TARGET_AP") { SET captureAlt TO CFG["TARGET_AP"]. }

        // 2. Delegate math to your existing library function
        planCapture(target, captureAlt).

        // 3. Execute with standard retry logic
        SET success TO executeManeuver().
        
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Capture missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError("Capture failed after " + retries + " attempts — halting.").
                RETURN.
            }
            WAIT 10.
        }
    }
    
    orbitSummary().
    mLog("Capture complete. Moving to finalization phase.").
    nextPhase(xferSeq).
}


// GLOBAL FUNCTION phaseCapture {
//     LOCAL target IS missionTargetBody().
//     WAIT 2.
//     mLog("Planning capture at " + target:NAME + ".").
//     LOCAL success IS FALSE.
//     LOCAL retries IS 0.
//     UNTIL success {
//         UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
//         LOCAL captureAlt IS CFG["RELAY_ALT"].
//         IF CFG:HASKEY("TARGET_AP") { SET captureAlt TO CFG["TARGET_AP"]. }
//         planCapture(target, captureAlt).
//         SET success TO executeManeuver().
//         IF NOT success {
//             SET retries TO retries + 1.
//             mLog("Capture missed (attempt " + retries + ") — waiting 10s.").
//             IF retries >= MAX_RETRIES {
//                 mLogError("Capture failed after " + retries + " attempts — halting.").
//                 RETURN.
//             }
//             WAIT 10.
//         }
//     }
//     orbitSummary().
// 
//     IF CFG:HASKEY("CAPTURE_AOP") {
//         LOCAL targetAoP IS CFG["CAPTURE_AOP"].
//         LOCAL deltaAoP IS ABS(SHIP:ORBIT:ARGUMENTOFPERIAPSIS - targetAoP).
//         IF deltaAoP > 180 { SET deltaAoP TO 360 - deltaAoP. }
//         IF deltaAoP > 2 {
//             mLog("Post-capture AoP correction: current=" + ROUND(SHIP:ORBIT:ARGUMENTOFPERIAPSIS,1)
//                 + " target=" + ROUND(targetAoP,1)).
//             LOCAL aopOk IS FALSE.
//             LOCAL aopRetries IS 0.
//             UNTIL aopOk {
//                 UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
//                 LOCAL nd IS planAoPChange(targetAoP).
//                 IF nd = 0 { SET aopOk TO TRUE. }
//                 ELSE IF NEXTNODE:DELTAV:MAG > 200 {
//                     mLogWarn("AoP correction would cost " + ROUND(NEXTNODE:DELTAV:MAG, 0) + "m/s. Exceeds safe limit — skipping.").
//                     REMOVE NEXTNODE.
//                     SET aopOk TO TRUE. 
//                 } ELSE {
//                     SET aopOk TO executeManeuver().
//                     IF NOT aopOk {
//                         SET aopRetries TO aopRetries + 1.
//                         mLog("AoP correction missed (attempt " + aopRetries + ").").
//                         IF aopRetries >= MAX_RETRIES { SET aopOk TO TRUE. }
//                         WAIT 10.
//                     }
//                 }
//             }
//             orbitSummary().
//         } ELSE {
//             mLog("AoP already within 2deg — skipping.").
//         }
//     }
// 
//     IF CFG:HASKEY("CAPTURE_INC") {
//         LOCAL targetInc IS CFG["CAPTURE_INC"].
//         LOCAL deltaInc IS ABS(SHIP:ORBIT:INCLINATION - targetInc).
//         LOCAL incTol IS 0.5.
//         IF CFG:HASKEY("INCL_TOLERANCE") { SET incTol TO CFG["INCL_TOLERANCE"]. }
//         IF deltaInc > incTol {
//             mLog("Post-capture INC correction: current=" + ROUND(SHIP:ORBIT:INCLINATION,2)
//                 + " target=" + ROUND(targetInc,2)).
//             LOCAL incOk IS FALSE.
//             LOCAL incRetries IS 0.
//             UNTIL incOk {
//                 UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
//                 planInclinationChange(targetInc).
//                 SET incOk TO executeManeuver().
//                 IF NOT incOk {
//                     SET incRetries TO incRetries + 1.
//                     mLog("INC correction missed (attempt " + incRetries + ").").
//                     IF incRetries >= MAX_RETRIES { SET incOk TO TRUE. }
//                     WAIT 10.
//                 }
//             }
//             orbitSummary().
//         } ELSE {
//             mLog("Inclination within tolerance — skipping.").
//         }
//     }
// 
//     nextPhase(xferSeq).
// }

GLOBAL FUNCTION phaseCirc {
    IF _impactThreat() {
        LOCAL safePe IS CFG["PARKING_ALT"].
        IF CFG:HASKEY("CAPTURE_PE") AND CFG["CAPTURE_PE"] > safePe {
            SET safePe TO CFG["CAPTURE_PE"].
        }
        mLog("Impact threat — raising Pe to safe " + ROUND(safePe/1000,0) + "km.").
        LOCAL success IS FALSE.
        LOCAL retries IS 0.
        UNTIL success {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            planRaisePeNow(safePe).
            WAIT 2.
            SET success TO executeManeuver().
            IF NOT success {
                SET retries TO retries + 1.
                mLog("Raise Pe missed (attempt " + retries + ") — waiting 10s.").
                IF retries >= MAX_RETRIES {
                    mLogError("Raise Pe failed after " + retries + " attempts — halting.").
                    RETURN.
                }
                WAIT 10.
            }
        }
    } ELSE IF SHIP:ORBIT:ECCENTRICITY < CFG["CIRC_ECC_TOL"] {
        mLog("Already circular (ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4) + ").").
    } ELSE {
        LOCAL success IS FALSE.
        LOCAL retries IS 0.
        UNTIL success {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            planCircularize().
            SET success TO executeManeuver().
            IF NOT success {
                SET retries TO retries + 1.
                mLog("Circ burn missed (attempt " + retries + ") — waiting 10s.").
                IF retries >= MAX_RETRIES {
                    mLogError("Circ failed after " + retries + " attempts — halting.").
                    RETURN.
                }
                WAIT 10.
            }
        }
    }
    orbitSummary().
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseRaiseAlt {
    LOCAL elliptical IS CFG:HASKEY("TARGET_PE") AND CFG:HASKEY("TARGET_AP").
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.

    IF elliptical {
        LOCAL targetPe IS CFG["TARGET_PE"].
        LOCAL targetAp IS CFG["TARGET_AP"].
        mLog("Target ellipse: Pe=" + ROUND(targetPe/1000,0) + "km  Ap=" + ROUND(targetAp/1000,0) + "km.").

        IF ABS(SHIP:PERIAPSIS - targetPe) > targetPe * 0.05 {
            mLog("Raising Pe to " + ROUND(targetPe/1000,0) + "km at Ap.").
            _burnWithRetry(
                { LOCAL rAp IS bodyR + SHIP:APOAPSIS. LOCAL rPe IS bodyR + targetPe. LOCAL tSMA IS (rAp + rPe) / 2. LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:APOAPSIS):ORBIT:MAG. LOCAL vNew IS SQRT(mu * (2/rAp - 1/tSMA)). RETURN NODE(TIME:SECONDS + ETA:APOAPSIS, 0, 0, vNew - vNow). },
                "Raise Pe").
        } ELSE {
            mLog("Pe already within tolerance.").
        }

        IF ABS(SHIP:APOAPSIS - targetAp) > targetAp * 0.02 {
            LOCAL burnTA IS 0.
            IF CFG:HASKEY("CAPTURE_AOP") {
                LOCAL targetAoP IS CFG["CAPTURE_AOP"].
                SET burnTA TO targetAoP - SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
                UNTIL burnTA >= 0 { SET burnTA TO burnTA + 360. }
                UNTIL burnTA < 360 { SET burnTA TO burnTA - 360. }
                mLog("Raise Ap at TA=" + ROUND(burnTA,1) + "deg for AoP=" + ROUND(targetAoP,1) + "deg.").
            } ELSE {
                mLog("Raising Ap to " + ROUND(targetAp/1000,0) + "km at Pe.").
            }
            _burnWithRetry(
                { LOCAL eta_ IS etaToTrueAnomaly(burnTA). LOCAL burnTime IS TIME:SECONDS + eta_. LOCAL rBurn IS bodyR + _altAtTA(burnTA). LOCAL rTarget IS bodyR + targetAp. LOCAL tSMA IS (rBurn + rTarget) / 2. LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG. LOCAL vNew IS SQRT(mu * (2/rBurn - 1/tSMA)). RETURN NODE(burnTime, 0, 0, vNew - vNow). },
                "Raise Ap").
        } ELSE {
            mLog("Ap already within tolerance.").
        }
    } ELSE {
        LOCAL targetAp IS CFG["RELAY_ALT"].
        IF SHIP:APOAPSIS > targetAp * 0.99 {
            mLog("Already at target Ap.").
            nextPhase(xferSeq).
            RETURN.
        }
        mLog("Raising Ap to " + ROUND(targetAp/1000,0) + "km.").
        _burnWithRetry(
            { LOCAL rBurn IS bodyR + SHIP:PERIAPSIS. LOCAL rTarget IS bodyR + targetAp. LOCAL tSMA IS (rBurn + rTarget) / 2. LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG. LOCAL vNew IS SQRT(mu * (2/rBurn - 1/tSMA)). RETURN NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, vNew - vNow). },
            "Raise Ap").
    }

    orbitSummary().
    nextPhase(xferSeq).
}

LOCAL FUNCTION _burnWithRetry {
    PARAMETER planFn.
    PARAMETER label.
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS planFn:CALL().
        ADD nd.
        mLog(label + ": dV=" + ROUND(nd:DELTAV:MAG,1) + " m/s").
        WAIT 2.
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog(label + " missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError(label + " failed after " + retries + " attempts.").
                RETURN.
            }
            WAIT 10.
        }
    }
}

GLOBAL FUNCTION phaseInclCorrect {
    LOCAL targetInc IS resolveTargetInclination().
    LOCAL currentInc IS SHIP:ORBIT:INCLINATION.

    IF currentInc > 90 AND targetInc < 90 {
        mLogWarn("Retrograde orbit detected (inc=" + ROUND(currentInc,1)
            + "deg) but target is prograde (" + ROUND(targetInc,1)
            + "deg) — plane change would cost ~600m/s. Skipping.").
        HUDTEXT("WARNING: Retrograde orbit — skipping incl correction",
            8, 2, 15, YELLOW, FALSE).
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL deltaInc IS ABS(currentInc - targetInc).
    IF deltaInc <= CFG["INCL_TOLERANCE"] {
        mLog("Inclination within tolerance — skipping.").
        nextPhase(xferSeq).
        RETURN.
    }

    mLog("Correcting inclination: " + ROUND(currentInc,2)
        + "deg -> " + ROUND(targetInc,2)
        + "deg  delta=" + ROUND(deltaInc,2) + "deg").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    planInclinationChange(targetInc).

    IF NEXTNODE:DELTAV:MAG > CFG["MAX_INCL_CHANGE_DV"] {
        mLogWarn("Inclination correction would cost " + ROUND(NEXTNODE:DELTAV:MAG,0)
            + "m/s — exceeds MAX_INCL_CHANGE_DV. Skipping.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        nextPhase(xferSeq).
        RETURN.
    }

    executeManeuver().
    orbitSummary().
    nextPhase(xferSeq).
}

LOCAL FUNCTION _altAtTA {
    PARAMETER ta.
    LOCAL sma IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL ecc IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL r_ IS sma * (1 - ecc^2) / (1 + ecc * COS(ta)).
    RETURN r_ - SHIP:ORBIT:BODY:RADIUS.
}

LOCAL FUNCTION _impactThreat {
    LOCAL myBody IS SHIP:ORBIT:BODY.
    LOCAL pe   IS SHIP:PERIAPSIS.

    IF myBody:ATM:EXISTS {
        RETURN pe < myBody:ATM:HEIGHT + 1000.
    }

    RETURN pe < 5000.
}

GLOBAL FUNCTION phaseElliptical {
    LOCAL targetBody IS missionTargetBody().
    WAIT 2.
    mLog("Planning unified PE, INC, LAN, and AoP alignment at Apoapsis...").

    // 1. Safely extract all 4 target parameters
    LOCAL targetPe  IS -1.
    LOCAL targetInc IS -1.
    LOCAL targetAoP IS -1.
    LOCAL targetLan IS -1.

    IF CFG:HASKEY("TARGET_PE")   { SET targetPe TO CFG["TARGET_PE"]. }
    IF CFG:HASKEY("CAPTURE_INC") { SET targetInc TO CFG["CAPTURE_INC"]. }
    IF CFG:HASKEY("CAPTURE_AOP") { SET targetAoP TO CFG["CAPTURE_AOP"]. }
    IF CFG:HASKEY("CAPTURE_LAN") { SET targetLan TO CFG["CAPTURE_LAN"]. }

    IF targetPe < 0 AND targetInc < 0 AND targetAoP < 0 AND targetLan < 0 {
        mLog("No finalization targets specified. Skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    
    // Plant the base node exactly at Apoapsis
    LOCAL burnTime IS TIME:SECONDS + ETA:APOAPSIS.
    LOCAL nd IS NODE(burnTime, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    // --- FITNESS FUNCTION ---
    LOCAL FUNCTION getFinalScore {
        LOCAL p IS nd:ORBIT. 
        
        IF p:PERIAPSIS < 0 { RETURN 9999999. } // Impact safety catch

        LOCAL peErr  IS 0.
        LOCAL incErr IS 0.
        LOCAL aopErr IS 0.
        LOCAL lanErr IS 0.

        IF targetPe >= 0 { SET peErr TO ABS(p:PERIAPSIS - targetPe) / 1000. }
        IF targetInc >= 0 { SET incErr TO ABS(p:INCLINATION - targetInc). }
        
        IF targetAoP >= 0 {
            LOCAL rawAoP IS ABS(p:ARGUMENTOFPERIAPSIS - targetAoP).
            IF rawAoP > 180 { SET rawAoP TO 360 - rawAoP. }
            SET aopErr TO rawAoP.
        }
        
        IF targetLan >= 0 {
            LOCAL rawLan IS ABS(p:LAN - targetLan).
            IF rawLan > 180 { SET rawLan TO 360 - rawLan. }
            SET lanErr TO rawLan.
        }

        // Weighting: 
        // PE keeps us alive (highest priority). 
        // INC is likely already close, but heavily weighted to prevent the solver from breaking it.
        // LAN and AOP are dialed in using the remaining Normal/Radial flexibility.
        RETURN (peErr * 10) + (incErr * 50) + (lanErr * 25) + (aopErr * 20).
    }
    

    // --- 3-AXIS HILL CLIMB (Prograde, Radial, Normal) ---
    LOCAL currentScore IS getFinalScore().
    LOCAL stepSize IS 10.0. 
    LOCAL minStep IS 0.01.
    LOCAL iter IS 0.

    UNTIL stepSize < minStep OR iter > 250 {
        SET iter TO iter + 1.
        LOCAL improved IS FALSE.

        LOCAL basePro IS nd:PROGRADE.
        LOCAL baseRad IS nd:RADIALOUT.
        LOCAL baseNor IS nd:NORMAL.

        LOCAL probes IS LIST(
            LIST(stepSize, 0, 0), LIST(-stepSize, 0, 0),
            LIST(0, stepSize, 0), LIST(0, -stepSize, 0),
            LIST(0, 0, stepSize), LIST(0, 0, -stepSize)
        ).

        LOCAL bestProbeScore IS currentScore.
        LOCAL bestPro IS basePro.
        LOCAL bestRad IS baseRad.
        LOCAL bestNor IS baseNor.

        FOR p IN probes {
            SET nd:PROGRADE TO basePro + p[0].
            SET nd:RADIALOUT TO baseRad + p[1].
            SET nd:NORMAL TO baseNor + p[2].
            WAIT 0.01. 

            LOCAL probeScore IS getFinalScore().
            IF probeScore < bestProbeScore {
                SET bestProbeScore TO probeScore.
                SET bestPro TO nd:PROGRADE.
                SET bestRad TO nd:RADIALOUT.
                SET bestNor TO nd:NORMAL.
                SET improved TO TRUE.
            }
            
            // Reset for next probe
            SET nd:PROGRADE TO basePro.
            SET nd:RADIALOUT TO baseRad.
            SET nd:NORMAL TO baseNor.
        }

        IF improved {
            SET nd:PROGRADE TO bestPro.
            SET nd:RADIALOUT TO bestRad.
            SET nd:NORMAL TO bestNor.
            SET currentScore TO bestProbeScore.
        } ELSE {
            SET stepSize TO stepSize * 0.5. // Shrink step and refine
        }
    }

    // 3. Evaluate and execute the resulting maneuver
    LOCAL totalDv IS nd:DELTAV:MAG.
    mLog("Finalization Converged: dV=" + ROUND(totalDv, 1) + " m/s").
    
    LOCAL resultMsg IS "Result ->".
    IF targetPe >= 0  { SET resultMsg TO resultMsg + " Pe: " + ROUND(nd:ORBIT:PERIAPSIS/1000, 1) + "km". }
    IF targetInc >= 0 { SET resultMsg TO resultMsg + " Inc: " + ROUND(nd:ORBIT:INCLINATION, 1) + "°". }
    IF targetAoP >= 0 { SET resultMsg TO resultMsg + " AoP: " + ROUND(nd:ORBIT:ARGUMENTOFPERIAPSIS, 1) + "°". }
    mLog(resultMsg).

    // Execution loop integrating your retry architecture
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Finalization burn missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError("Finalization failed after " + retries + " attempts. Halting.").
                RETURN.
            }
            WAIT 10.
        }
    }

    orbitSummary().
    mLog("Orbit finalization complete!").
    nextPhase(xferSeq).
}

