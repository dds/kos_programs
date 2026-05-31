// ============================================================
// mcc.ks  —  Mid-Course Correction phase  (0:/lib/mcc.ks)
// ============================================================

LOCAL MCC_DV_CAP IS 50.

GLOBAL FUNCTION phaseMidCourse {
    LOCAL target IS missionTargetBody().

    IF NOT CFG:HASKEY("CAPTURE_PE") {
        mLog("No CAPTURE_PE specified. Skipping mid-course correction.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL targetPe  IS CFG["CAPTURE_PE"].
    LOCAL targetAoP IS -1.
    LOCAL targetLan IS -1.
    IF CFG:HASKEY("CAPTURE_AOP") { SET targetAoP TO CFG["CAPTURE_AOP"]. }
    IF CFG:HASKEY("CAPTURE_LAN") { SET targetLan TO CFG["CAPTURE_LAN"]. }

    LOCAL patch IS _getTargetPatch(SHIP, target).
    IF patch = 0 {
        mLogWarn("No encounter with " + target:NAME + " detected! Skipping MCC.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL waitTime IS 0.
    IF SHIP:ORBIT:NEXTPATCH:BODY:NAME <> target:NAME {
        LOCAL transitionTime IS ETA:TRANSITION.
        SET waitTime TO transitionTime + 3600.
        mLog("MCC: Interplanetary transfer. Coasting to deep space (" + ROUND(waitTime,0) + "s).").
    } ELSE {
        SET waitTime TO ETA:TRANSITION / 2.
        mLog("MCC: Local transfer. Coasting to halfway point (" + ROUND(waitTime,0) + "s).").
    }

    LOCAL startPatch IS _getTargetPatch(SHIP, target).
    LOCAL startPe IS startPatch:PERIAPSIS.
    LOCAL startAoP IS startPatch:ARGUMENTOFPERIAPSIS.
    LOCAL startLan IS startPatch:LAN.
    mLog("MCC: Pre-correction encounter  Pe=" + ROUND(startPe/1000,1) + "km"
        + " AoP=" + ROUND(startAoP,1) + "° LAN=" + ROUND(startLan,1) + "°.").

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + waitTime, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    LOCAL bestPe   IS -1.
    LOCAL bestAoP  IS -1.
    LOCAL bestLan  IS -1.
    LOCAL bestNorm IS 0.
    LOCAL bestRad  IS 0.
    LOCAL bestPro  IS 0.
    LOCAL steps    IS 5.

    LOCAL testPatch IS _getTargetPatch(nd, target).
    IF testPatch <> 0 {
        SET bestPe  TO testPatch:PERIAPSIS.
        SET bestAoP TO testPatch:ARGUMENTOFPERIAPSIS.
        SET bestLan TO testPatch:LAN.
    }

    FROM { LOCAL pass IS 1. } UNTIL pass > 6 STEP { SET pass TO pass + 1. } DO {
        LOCAL improved IS TRUE.
        UNTIL NOT improved {
            SET improved TO FALSE.
            LOCAL currentScore IS _scoreMCC(bestPe, bestAoP, bestLan, targetPe, targetAoP, targetLan).

            LOCAL moves IS LIST(
                LIST(0, 0, steps),
                LIST(0, 0, -steps),
                LIST(0, steps, 0),
                LIST(0, -steps, 0),
                LIST(steps, 0, 0),
                LIST(-steps, 0, 0)
            ).

            LOCAL bestMoveScore IS currentScore.
            LOCAL bestMoveN IS 0.
            LOCAL bestMoveR IS 0.
            LOCAL bestMoveP IS 0.
            LOCAL foundPe  IS bestPe.
            LOCAL foundAoP IS bestAoP.
            LOCAL foundLan IS bestLan.

            FOR move IN moves {
                LOCAL testN IS bestNorm + move[0].
                LOCAL testR IS bestRad  + move[1].
                LOCAL testP IS bestPro  + move[2].
                LOCAL testDv IS SQRT(testN^2 + testR^2 + testP^2).
                IF testDv > MCC_DV_CAP {
                    // skip — would exceed dV budget
                } ELSE {
                    SET nd:NORMAL    TO testN.
                    SET nd:RADIALOUT TO testR.
                    SET nd:PROGRADE  TO testP.
                    WAIT 0.02.

                    LOCAL movePatch IS _getTargetPatch(nd, target).
                    IF movePatch <> 0 AND movePatch:PERIAPSIS > 0 {
                        LOCAL score IS _scoreMCC(movePatch:PERIAPSIS, movePatch:ARGUMENTOFPERIAPSIS,
                            movePatch:LAN, targetPe, targetAoP, targetLan).
                        IF score < bestMoveScore {
                            SET bestMoveScore TO score.
                            SET bestMoveN TO move[0].
                            SET bestMoveR TO move[1].
                            SET bestMoveP TO move[2].
                            SET foundPe  TO movePatch:PERIAPSIS.
                            SET foundAoP TO movePatch:ARGUMENTOFPERIAPSIS.
                            SET foundLan TO movePatch:LAN.
                        }
                    }
                }
            }

            SET nd:NORMAL    TO bestNorm.
            SET nd:RADIALOUT TO bestRad.
            SET nd:PROGRADE  TO bestPro.

            IF bestMoveScore < currentScore {
                SET bestNorm TO bestNorm + bestMoveN.
                SET bestRad  TO bestRad  + bestMoveR.
                SET bestPro  TO bestPro  + bestMoveP.
                SET bestPe   TO foundPe.
                SET bestAoP  TO foundAoP.
                SET bestLan  TO foundLan.
                SET nd:NORMAL    TO bestNorm.
                SET nd:RADIALOUT TO bestRad.
                SET nd:PROGRADE  TO bestPro.
                SET improved TO TRUE.
            }
        }
        SET steps TO steps / 5.
    }

    LOCAL totalDv IS SQRT(bestNorm^2 + bestRad^2 + bestPro^2).
    LOCAL logMsg IS "MCC result: dV=" + ROUND(totalDv, 1) + " m/s"
        + "  Pe=" + ROUND(bestPe/1000,1) + "km".
    IF targetAoP >= 0 {
        LOCAL aopErr IS ABS(bestAoP - targetAoP).
        IF aopErr > 180 { SET aopErr TO 360 - aopErr. }
        SET logMsg TO logMsg + "  AoP=" + ROUND(bestAoP,1) + "°(err " + ROUND(aopErr,1) + "°)".
    }
    IF targetLan >= 0 {
        LOCAL lanErr IS ABS(bestLan - targetLan).
        IF lanErr > 180 { SET lanErr TO 360 - lanErr. }
        SET logMsg TO logMsg + "  LAN=" + ROUND(bestLan,1) + "°(err " + ROUND(lanErr,1) + "°)".
    }

    IF totalDv < 0.1 OR _getTargetPatch(nd, target) = 0 {
        mLog("Encounter already on target. Skipping MCC burn.").
        REMOVE nd.
    } ELSE {
        mLog(logMsg).
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

LOCAL FUNCTION _scoreMCC {
    PARAMETER pe, aop, lan, tPe, tAoP, tLan.

    LOCAL score IS 0.

    IF pe < 0 {
        RETURN ABS(pe) * 100000000.
    }

    SET score TO ABS(pe - tPe) * 1000.

    IF tAoP >= 0 {
        LOCAL errAoP IS ABS(aop - tAoP).
        IF errAoP > 180 { SET errAoP TO 360 - errAoP. }
        SET score TO score + errAoP * 500000.
    }

    IF tLan >= 0 {
        LOCAL errLan IS ABS(lan - tLan).
        IF errLan > 180 { SET errLan TO 360 - errLan. }
        SET score TO score + errLan * 500000.
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
