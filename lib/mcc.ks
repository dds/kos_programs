// ============================================================
// mcc.ks  —  Mid-Course Correction phase  (0:/lib/mcc.ks)
// ============================================================

GLOBAL FUNCTION phaseMidCourse {
    LOCAL target IS missionTargetBody().

    IF NOT CFG:HASKEY("CAPTURE_INC") AND NOT CFG:HASKEY("CAPTURE_PE") {
        mLog("No capture parameters specified. Skipping mid-course correction.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL targetInc IS 0.
    LOCAL targetPe  IS 0.
    LOCAL targetAoP IS -1.
    IF CFG:HASKEY("CAPTURE_AOP") { SET targetAoP TO CFG["CAPTURE_AOP"]. }
    IF CFG:HASKEY("CAPTURE_INC") { SET targetInc TO CFG["CAPTURE_INC"]. }
    IF CFG:HASKEY("CAPTURE_PE")  { SET targetPe TO CFG["CAPTURE_PE"]. }

    LOCAL patch IS _getTargetPatch(SHIP, target).
    IF patch = 0 {
        mLogWarn("No encounter with " + target:NAME + " detected! Skipping MCC.").
        nextPhase(xferSeq).
        RETURN.
    }

    // Smart Timing:
    // If we are leaving our parent's SOI (e.g. going to Duna via Sun), warp until we enter deep space.
    // If we stay in the same SOI (e.g. going to Mun), wait until halfway.
    LOCAL waitTime IS 0.
    IF SHIP:ORBIT:NEXTPATCH:BODY:NAME <> target:NAME {
        LOCAL transitionTime IS ETA:TRANSITION.
        SET waitTime TO transitionTime + 3600. // 1 hour after leaving origin SOI
        mLog("MCC: Interplanetary transfer. Coasting to deep space (" + ROUND(waitTime,0) + "s).").
    } ELSE {
        SET waitTime TO ETA:TRANSITION / 2.
        mLog("MCC: Local transfer. Coasting to halfway point (" + ROUND(waitTime,0) + "s).").
    }

    LOCAL midTime IS TIME:SECONDS + waitTime.
    SET SAS TO TRUE.
    IF waitTime > 120 {
        KUNIVERSE:TIMEWARP:WARPTO(midTime - 60).
        WAIT UNTIL TIME:SECONDS >= (midTime - 60).
    }

    mLog("Planning mid-course correction.").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }

    // Drop blank node
    LOCAL nd IS NODE(TIME:SECONDS + 60, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    // Optimize Normal and Radial using gradient descent
    LOCAL bestInc  IS 999.
    LOCAL bestPe   IS -1.
    LOCAL bestNorm IS 0.
    LOCAL bestRad  IS 0.
    LOCAL bestAoP IS -1.
    LOCAL bestPro  IS 0.
    LOCAL steps    IS 10. 

    LOCAL testPatch IS _getTargetPatch(nd, target).
    IF testPatch <> 0 {
        SET bestInc TO testPatch:INCLINATION.
        SET bestPe  TO testPatch:PERIAPSIS.
        SET bestAoP TO testPatch:ARGUMENTOFPERIAPSIS.
    }

    FROM { LOCAL pass IS 1. } UNTIL pass > 6 STEP { SET pass TO pass + 1. } DO {
        LOCAL improved IS TRUE.
        UNTIL NOT improved {
            SET improved TO FALSE.
            LOCAL currentScore IS _evaluateMCC(bestInc, bestPe, bestAoP, targetInc, targetPe, targetAoP).
            
            // Now evaluating Normal, Radial, AND Prograde
            LOCAL moves IS LIST(
                LIST(steps, 0, 0),   // Normal Up
                LIST(-steps, 0, 0),  // Normal Down
                LIST(0, steps, 0),   // Radial Out
                LIST(0, -steps, 0),  // Radial In
                LIST(0, 0, steps),   // Prograde (Crucial for shifting AoP)
                LIST(0, 0, -steps)   // Retrograde
            ).
            
            LOCAL bestMoveScore IS currentScore.
            LOCAL bestMoveN IS 0.
            LOCAL bestMoveR IS 0.
            LOCAL bestMoveP IS 0.
            
            LOCAL foundInc  IS bestInc.
            LOCAL foundPe   IS bestPe.
            LOCAL foundAoP  IS bestAoP.

            FOR move IN moves {
                SET nd:NORMAL TO bestNorm + move[0].
                SET nd:RADIALOUT TO bestRad + move[1].
                SET nd:PROGRADE TO bestPro + move[2].
                WAIT 0.02.
                
                LOCAL movePatch IS _getTargetPatch(nd, target).
                LOCAL score IS 999999999.
                LOCAL tempInc IS -1.
                LOCAL tempPe  IS -1.
                LOCAL tempAoP IS -1.
                
                IF movePatch <> 0 {
                    SET tempInc TO movePatch:INCLINATION.
                    SET tempPe  TO movePatch:PERIAPSIS.
                    SET tempAoP TO movePatch:ARGUMENTOFPERIAPSIS.
                    SET score TO _evaluateMCC(tempInc, tempPe, tempAoP, targetInc, targetPe, targetAoP).
                }
                
                IF score < bestMoveScore {
                    SET bestMoveScore TO score.
                    SET bestMoveN TO move[0].
                    SET bestMoveR TO move[1].
                    SET bestMoveP TO move[2].
                    SET foundInc  TO tempInc.
                    SET foundPe   TO tempPe.
                    SET foundAoP  TO tempAoP.
                }
            }
            
            // Reset node
            SET nd:NORMAL TO bestNorm.
            SET nd:RADIALOUT TO bestRad.
            SET nd:PROGRADE TO bestPro.

            IF bestMoveScore < currentScore {
                SET bestNorm TO bestNorm + bestMoveN.
                SET bestRad  TO bestRad + bestMoveR.
                SET bestPro  TO bestPro + bestMoveP.
                SET bestInc  TO foundInc.
                SET bestPe   TO foundPe.
                SET bestAoP  TO foundAoP.
                
                SET nd:NORMAL TO bestNorm.
                SET nd:RADIALOUT TO bestRad.
                SET nd:PROGRADE TO bestPro.
                SET improved TO TRUE.
            }
        }
        SET steps TO steps / 5.
    }

    LOCAL totalDv IS SQRT(bestNorm^2 + bestRad^2).
    IF totalDv < 0.1 OR _getTargetPatch(nd, target) = 0 {
        mLog("Arrival parameters optimal or unfixable. Skipping MCC burn.").
        REMOVE nd.
    } ELSE {
        mLog("MCC planned: dV=" + ROUND(totalDv, 1) + " m/s. Est Inc=" + ROUND(bestInc, 1) + "° Pe=" + ROUND(bestPe/1000,0) + "km.").
        LOCAL success IS FALSE.
        LOCAL retries IS 0.
        UNTIL success {
            SET success TO executeManeuver().
            IF NOT success {
                SET retries TO retries + 1.
                IF retries >= MAX_RETRIES {
                    mLogError("MCC failed. Abandoning MCC phase.").
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

LOCAL FUNCTION _evaluateMCC {
    PARAMETER currentInc, currentPe, currentAoP.
    PARAMETER targetInc, targetPe, targetAoP.

    LOCAL score IS 0.
    
    IF targetInc >= 0 { 
        SET score TO score + (ABS(currentInc - targetInc) * 10000). 
    }
    IF targetPe >= 0 { 
        SET score TO score + ABS(currentPe - targetPe). 
    }
    IF targetAoP >= 0 {
        LOCAL errAoP IS ABS(currentAoP - targetAoP).
        IF errAoP > 180 { SET errAoP TO 360 - errAoP. }
        // Scale AoP weight so it competes fairly with Inclination
        SET score TO score + (errAoP * 2000). 
    }
    
    RETURN score.
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