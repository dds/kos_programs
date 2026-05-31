// ============================================================
// mcc.ks  —  Mid-Course Correction phase  (0:/lib/mcc.ks)
// ============================================================

LOCAL MCC_DV_CAP IS 50.
LOCAL MCC_EPS    IS 0.5.
LOCAL MCC_DAMP   IS 0.7.
LOCAL MCC_PE_TOL IS 500.
LOCAL MCC_ANG_TOL IS 2.

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
    
    IF CFG:HASKEY("CAPTURE_INC") { SET targetInc TO CFG["CAPTURE_INC"]. }
    IF CFG:HASKEY("CAPTURE_LAN") { SET targetLan TO CFG["CAPTURE_LAN"]. }

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

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + waitTime, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    _optimizeMCC(nd, target, targetPe, targetInc, targetLan).
    
    WAIT 0.1. 

    LOCAL totalDv IS nd:DELTAV:MAG.
    LOCAL finalPatch IS _getTargetPatch(nd, target).

    IF totalDv < 0.1 OR finalPatch = 0 {
        mLog("Encounter on target. Skipping MCC burn.").
        REMOVE nd.
    } ELSE {
        LOCAL logMsg IS "MCC planned: dV=" + ROUND(totalDv, 1)
            + " m/s  Pe=" + ROUND(finalPatch:PERIAPSIS/1000,1) + "km".
        IF targetLan >= 0 {
            SET logMsg TO logMsg + "  LAN=" + ROUND(finalPatch:LAN,1) + "°".
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

LOCAL FUNCTION _optimizeMCC {
    PARAMETER mccNode.
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER targetInc IS 90.
    PARAMETER targetLan IS 25.

    mLog("Starting 3-Axis MCC Optimization...").

    // --- FITNESS / COST FUNCTION ---
    LOCAL FUNCTION getScore {
        LOCAL p IS _getTargetPatch(mccNode, targetBody).
        
        // Massive penalties for lost encounters or impacts
        IF p = 0 { RETURN 9999999. }
        IF p:PERIAPSIS < 0 { RETURN 9999999. }

        // Normalize errors so they operate on similar scales
        LOCAL peErr IS ABS(p:PERIAPSIS - targetPe) / 1000. // Convert to km for scaling
        LOCAL incErr IS ABS(p:INCLINATION - targetInc).
        
        LOCAL lanErr IS ABS(p:LAN - targetLan).
        IF lanErr > 180 { SET lanErr TO 360 - lanErr. }

        // Weighting: PE is critical, INC is highly important, LAN is secondary
        RETURN (peErr * 10) + (incErr * 50) + (lanErr * 15).
    }

    // --- HILL CLIMB ALGORITHM ---
    LOCAL currentScore IS getScore().
    LOCAL stepSize IS 10.0. // Start with large 10 m/s steps to break out of local minima
    LOCAL minStep IS 0.01.
    LOCAL iter IS 0.

    UNTIL stepSize < minStep OR iter > 200 {
        SET iter TO iter + 1.
        LOCAL improved IS FALSE.

        // Store baseline
        LOCAL basePro IS mccNode:PROGRADE.
        LOCAL baseRad IS mccNode:RADIALOUT.
        LOCAL baseNor IS mccNode:NORMAL.

        // Define the 6 directions to probe
        LOCAL probes IS LIST(
            LIST(stepSize, 0, 0), LIST(-stepSize, 0, 0), // Prograde / Retrograde
            LIST(0, stepSize, 0), LIST(0, -stepSize, 0), // Radial In / Out
            LIST(0, 0, stepSize), LIST(0, 0, -stepSize)  // Normal / Antinormal
        ).

        LOCAL bestProbeScore IS currentScore.
        LOCAL bestPro IS basePro.
        LOCAL bestRad IS baseRad.
        LOCAL bestNor IS baseNor.

        // Test the gradient in all 6 directions
        FOR p IN probes {
            SET mccNode:PROGRADE TO basePro + p[0].
            SET mccNode:RADIALOUT TO baseRad + p[1].
            SET mccNode:NORMAL TO baseNor + p[2].
            WAIT 0.01. // Allow KSP conics to update

            LOCAL probeScore IS getScore().
            IF probeScore < bestProbeScore {
                SET bestProbeScore TO probeScore.
                SET bestPro TO mccNode:PROGRADE.
                SET bestRad TO mccNode:RADIALOUT.
                SET bestNor TO mccNode:NORMAL.
                SET improved TO TRUE.
            }
            
            // Reset for next probe
            SET mccNode:PROGRADE TO basePro.
            SET mccNode:RADIALOUT TO baseRad.
            SET mccNode:NORMAL TO baseNor.
        }

        // Apply the best gradient step found
        IF improved {
            SET mccNode:PROGRADE TO bestPro.
            SET mccNode:RADIALOUT TO bestRad.
            SET mccNode:NORMAL TO bestNor.
            SET currentScore TO bestProbeScore.
        } ELSE {
            // If no direction improved the score, shrink the step size to refine
            SET stepSize TO stepSize * 0.5.
        }
    }

    // --- FINAL REPORT ---
    LOCAL finalPatch IS _getTargetPatch(mccNode, targetBody).
    LOCAL totalDv IS SQRT(mccNode:PROGRADE^2 + mccNode:RADIALOUT^2 + mccNode:NORMAL^2).
    
    mLog("MCC Converged in " + iter + " iterations.").
    mLog("dV: " + ROUND(totalDv, 2) + " m/s (P:" + ROUND(mccNode:PROGRADE,2) + " R:" + ROUND(mccNode:RADIALOUT,2) + " N:" + ROUND(mccNode:NORMAL,2) + ")").
    
    IF finalPatch <> 0 {
        mLog("Result - PE: " + ROUND(finalPatch:PERIAPSIS/1000, 1) + "km  INC: " + ROUND(finalPatch:INCLINATION, 1) + "  LAN: " + ROUND(finalPatch:LAN, 1)).
    }

    RETURN mccNode.
}

GLOBAL FUNCTION phaseApoapsisCrank {
    LOCAL targetBody IS missionTargetBody().

    // Mission targets
    LOCAL targetInc IS CFG["CAPTURE_INC"]. // 90
    LOCAL targetAoP IS CFG["CAPTURE_AOP"]. // 93.2
    LOCAL targetPe  IS CFG["CAPTURE_PE"].  // 12500

    mLog("Starting Apoapsis Crank to Polar/AoP alignment...").

    // Plant the node exactly at Apoapsis
    LOCAL crankTime IS TIME:SECONDS + ETA:APOAPSIS.
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(crankTime, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    // --- FITNESS FUNCTION ---
    LOCAL FUNCTION getCrankScore {
        LOCAL p IS nd:ORBIT. // We use the node's resulting orbit directly
        
        // Massive penalties for impacting the Mun
        IF p:PERIAPSIS < 0 { RETURN 9999999. }

        // Normalize errors
        LOCAL peErr IS ABS(p:PERIAPSIS - targetPe) / 1000. 
        LOCAL incErr IS ABS(p:INCLINATION - targetInc).
        
        LOCAL aopErr IS ABS(p:ARGUMENTOFPERIAPSIS - targetAoP).
        IF aopErr > 180 { SET aopErr TO 360 - aopErr. }

        // Weighting: INC is massive here, AOP is secondary, PE keeps us locked
        RETURN (incErr * 50) + (aopErr * 20) + (peErr * 10).
    }

    // --- 3-AXIS HILL CLIMB ---
    LOCAL currentScore IS getCrankScore().
    LOCAL stepSize IS 5.0. // Smaller initial step, as velocity is low
    LOCAL minStep IS 0.01.
    LOCAL iter IS 0.

    UNTIL stepSize < minStep OR iter > 200 {
        SET iter TO iter + 1.
        LOCAL improved IS FALSE.

        LOCAL basePro IS nd:PROGRADE.
        LOCAL baseRad IS nd:RADIALOUT.
        LOCAL baseNor IS nd:NORMAL.

        // 6 directions to probe
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

            LOCAL probeScore IS getCrankScore().
            IF probeScore < bestProbeScore {
                SET bestProbeScore TO probeScore.
                SET bestPro TO nd:PROGRADE.
                SET bestRad TO nd:RADIALOUT.
                SET bestNor TO nd:NORMAL.
                SET improved TO TRUE.
            }
            
            // Reset
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
            SET stepSize TO stepSize * 0.5.
        }
    }

    LOCAL totalDv IS nd:DELTAV:MAG.
    mLog("Crank Converged: dV=" + ROUND(totalDv, 1) + " m/s").
    mLog("Result - INC: " + ROUND(nd:ORBIT:INCLINATION, 1) + "  AoP: " + ROUND(nd:ORBIT:ARGUMENTOFPERIAPSIS, 1) + "  Pe: " + ROUND(nd:ORBIT:PERIAPSIS/1000, 1) + "km").

    // Hand off to maneuver execution
    executeManeuver().
    nextPhase(xferSeq).
}