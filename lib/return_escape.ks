// ============================================================
// return_escape.ks - lightweight Mun/Minmus -> Kerbin escape
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL ESCAPE_PE IS -1.
GLOBAL ESCAPE_KSC_TARGET IS 0.
GLOBAL REENTRY_PE IS 30000.

LOCAL MAX_RETRIES IS 5.

LOCAL FUNCTION _returnTargetPe {
    LOCAL pe IS ESCAPE_PE.
    IF pe < 0 { SET pe TO REENTRY_PE. }
    IF pe < 0 { SET pe TO 30000. }
    RETURN pe.
}

LOCAL FUNCTION _targetPatch {
    PARAMETER nd.
    PARAMETER targetBody.

    LOCAL p IS nd:ORBIT.
    IF p:BODY:NAME = targetBody:NAME { RETURN p. }
    UNTIL NOT p:HASNEXTPATCH {
        SET p TO p:NEXTPATCH.
        IF p:BODY:NAME = targetBody:NAME { RETURN p. }
    }
    RETURN 0.
}

LOCAL FUNCTION _escapeScore {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targetPe.

    LOCAL patch IS _targetPatch(nd, targetBody).
    LOCAL score IS nd:DELTAV:MAG * 0.01.
    LOCAL hasPatch IS patch <> 0.
    IF NOT hasPatch {
        SET score TO score + 1000000.
    } ELSE {
        SET score TO score + (ABS(patch:PERIAPSIS - targetPe) / 100000)^2.
    }
    RETURN LEXICON("SCORE", score, "PATCH", hasPatch).
}

// Estimate KSC longitude penalty for a candidate escape node.
// Kept local so the return path does not import maneuver_targeting.
LOCAL FUNCTION _escapeKscPenalty {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER departTime.
    PARAMETER transitA.
    PARAMETER muParent.
    PARAMETER kscLng.

    LOCAL patch IS _targetPatch(nd, targetBody).
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

LOCAL FUNCTION _planReturnEscape {
    PARAMETER targetBody.
    PARAMETER targetPe.

    LOCAL shipPeriod IS SHIP:ORBIT:PERIOD.
    LOCAL muParent IS targetBody:MU.
    LOCAL muMoon IS BODY:MU.

    LOCAL rMoon IS BODY:ORBIT:SEMIMAJORAXIS.
    LOCAL vMoon IS SQRT(muParent / rMoon).
    LOCAL rTarget IS targetBody:RADIUS + targetPe.
    LOCAL aTransfer IS (rMoon + rTarget) / 2.
    LOCAL vNeeded IS SQRT(muParent * (2 / rMoon - 1 / aTransfer)).
    LOCAL vInf IS ABS(vMoon - vNeeded).

    LOCAL rShipPe IS BODY:RADIUS + SHIP:PERIAPSIS.
    LOCAL aShip IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL vEscape IS SQRT(2 * muMoon / rShipPe).
    LOCAL vBurn IS SQRT(vInf^2 + vEscape^2).
    LOCAL vAtPe IS SQRT(muMoon * (2 / rShipPe - 1 / aShip)).
    LOCAL escapeDv IS vBurn - vAtPe.

    LOCAL departUt IS TIME:SECONDS + ETA:PERIAPSIS.
    IF departUt < TIME:SECONDS + 30 { SET departUt TO departUt + shipPeriod. }
    LOCAL nd IS NODE(departUt, 0, 0, escapeDv).
    ADD nd.
    WAIT 0.1.

    LOCAL kscTarget IS ESCAPE_KSC_TARGET <> 0.
    LOCAL kscLng IS -74.6.
    LOCAL kscTransitA IS (rMoon + targetBody:RADIUS + targetPe) / 2.

    LOCAL samplesPerOrbit IS 12.
    LOCAL scanSteps IS samplesPerOrbit.
    LOCAL scanDt IS shipPeriod / samplesPerOrbit.
    LOCAL scanStart IS departUt.
    LOCAL scanEnd IS departUt + shipPeriod.
    LOCAL bestTime IS departUt.
    LOCAL bestScore IS 999999999.

    mLog("Return escape scan: " + (scanSteps + 1)
        + " steps over next orbit; KSC=" + kscTarget + ".").
    FROM { LOCAL si IS 0. } UNTIL si > scanSteps STEP { SET si TO si + 1. } DO {
        LOCAL tryTime IS departUt + si * scanDt.
        IF tryTime > TIME:SECONDS + 30 {
            SET nd:TIME TO tryTime.
            WAIT 0.02.
            LOCAL seed IS _escapeScore(nd, targetBody, targetPe).
            LOCAL score IS seed["SCORE"].
            IF kscTarget AND seed["PATCH"] {
                SET score TO score + _escapeKscPenalty(
                    nd, targetBody, tryTime, kscTransitA, muParent, kscLng).
            }
            IF score < bestScore {
                SET bestScore TO score.
                SET bestTime TO tryTime.
            }
        }
    }

    LOCAL gr IS (SQRT(5) + 1) / 2.
    LOCAL tA IS MAX(scanStart, bestTime - scanDt).
    LOCAL tB IS MIN(scanEnd, bestTime + scanDt).
    FROM { LOCAL gi IS 0. } UNTIL gi >= 12 STEP { SET gi TO gi + 1. } DO {
        LOCAL tC IS tB - (tB - tA) / gr.
        LOCAL tD IS tA + (tB - tA) / gr.

        SET nd:TIME TO tC. WAIT 0.02.
        LOCAL seedC IS _escapeScore(nd, targetBody, targetPe).
        LOCAL scoreC IS seedC["SCORE"].
        IF kscTarget AND seedC["PATCH"] {
            SET scoreC TO scoreC + _escapeKscPenalty(
                nd, targetBody, tC, kscTransitA, muParent, kscLng).
        }

        SET nd:TIME TO tD. WAIT 0.02.
        LOCAL seedD IS _escapeScore(nd, targetBody, targetPe).
        LOCAL scoreD IS seedD["SCORE"].
        IF kscTarget AND seedD["PATCH"] {
            SET scoreD TO scoreD + _escapeKscPenalty(
                nd, targetBody, tD, kscTransitA, muParent, kscLng).
        }

        IF scoreC < scoreD {
            SET tB TO tD.
        } ELSE {
            SET tA TO tC.
        }
    }
    SET nd:TIME TO (tA + tB) / 2.
    WAIT 0.1.

    LOCAL dvRange IS MAX(10, ABS(escapeDv) * 0.2).
    LOCAL dvSteps IS 16.
    LOCAL dvStep IS dvRange * 2 / dvSteps.
    LOCAL bestDv IS escapeDv.
    LOCAL bestDvSeed IS _escapeScore(nd, targetBody, targetPe).
    LOCAL bestDvScore IS bestDvSeed["SCORE"].
    IF kscTarget AND bestDvSeed["PATCH"] {
        SET bestDvScore TO bestDvScore + _escapeKscPenalty(
            nd, targetBody, nd:TIME, kscTransitA, muParent, kscLng).
    }
    FROM { LOCAL di IS 0. } UNTIL di > dvSteps STEP { SET di TO di + 1. } DO {
        LOCAL tryDv IS escapeDv - dvRange + di * dvStep.
        SET nd:PROGRADE TO tryDv.
        WAIT 0.02.
        LOCAL trySeed IS _escapeScore(nd, targetBody, targetPe).
        LOCAL tryScore IS trySeed["SCORE"].
        IF kscTarget AND trySeed["PATCH"] {
            SET tryScore TO tryScore + _escapeKscPenalty(
                nd, targetBody, nd:TIME, kscTransitA, muParent, kscLng).
        }
        IF tryScore < bestDvScore {
            SET bestDvScore TO tryScore.
            SET bestDv TO tryDv.
        }
    }

    LOCAL dvA IS MAX(bestDv - dvStep, escapeDv - dvRange).
    LOCAL dvB IS MIN(bestDv + dvStep, escapeDv + dvRange).
    SET nd:PROGRADE TO bestDv.
    WAIT 0.1.
    FROM { LOCAL gi IS 0. } UNTIL gi >= 12 STEP { SET gi TO gi + 1. } DO {
        LOCAL dvC IS dvB - (dvB - dvA) / gr.
        LOCAL dvD IS dvA + (dvB - dvA) / gr.

        SET nd:PROGRADE TO dvC. WAIT 0.02.
        LOCAL seedC IS _escapeScore(nd, targetBody, targetPe).
        LOCAL scoreC IS seedC["SCORE"].
        IF kscTarget AND seedC["PATCH"] {
            SET scoreC TO scoreC + _escapeKscPenalty(
                nd, targetBody, nd:TIME, kscTransitA, muParent, kscLng).
        }

        SET nd:PROGRADE TO dvD. WAIT 0.02.
        LOCAL seedD IS _escapeScore(nd, targetBody, targetPe).
        LOCAL scoreD IS seedD["SCORE"].
        IF kscTarget AND seedD["PATCH"] {
            SET scoreD TO scoreD + _escapeKscPenalty(
                nd, targetBody, nd:TIME, kscTransitA, muParent, kscLng).
        }

        IF scoreC < scoreD {
            SET dvB TO dvD.
        } ELSE {
            SET dvA TO dvC.
        }
    }
    SET nd:PROGRADE TO (dvA + dvB) / 2.
    WAIT 0.1.

    LOCAL finalSeed IS _escapeScore(nd, targetBody, targetPe).
    LOCAL patch IS _targetPatch(nd, targetBody).
    IF NOT finalSeed["PATCH"] {
        mLogError("Return escape planner found no " + targetBody:NAME
            + " patch.").
        mLog("STATS return-escape plan target=" + targetBody:NAME
            + " status=no-patch"
            + " dv=" + ROUND(nd:DELTAV:MAG, 1)
            + " score=" + ROUND(finalSeed["SCORE"], 2)
            + " free=" + ROUND(CORE:VOLUME:FREESPACE, 0)).
        IF HASNODE { REMOVE nd. WAIT 0.1. }
        RETURN 0.
    }
    LOCAL peKm IS -9999.
    IF patch <> 0 { SET peKm TO patch:PERIAPSIS / 1000. }
    mLog("Return escape optimized: dV=" + ROUND(nd:DELTAV:MAG, 1)
        + " m/s Pe=" + ROUND(peKm, 1)
        + "km patch=" + finalSeed["PATCH"]
        + " depart T+" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s.").
    mLog("STATS return-escape plan target=" + targetBody:NAME
        + " dv=" + ROUND(nd:DELTAV:MAG, 1)
        + " PeKm=" + ROUND(peKm, 1)
        + " patch=" + finalSeed["PATCH"]
        + " score=" + ROUND(finalSeed["SCORE"], 2)
        + " free=" + ROUND(CORE:VOLUME:FREESPACE, 0)).

    RETURN nd.
}

GLOBAL FUNCTION phaseEscape {
    IF BODY:BODY = 0 {
        mLogError("Return escape requires a parent body.").
        PRINT " ".
        PRINT "  ESCAPE FAILED".
        PRINT "  Current body has no parent.".
        yieldToPrompt().
        RETURN.
    }

    LOCAL target IS BODY:BODY.
    LOCAL targetPe IS _returnTargetPe().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS _planReturnEscape(target, targetPe).
        IF nd = 0 OR NOT nd:ISTYPE("Node") {
            SET retries TO retries + 1.
            mLogError("Return escape planning failed.").
            PRINT " ".
            PRINT "  ESCAPE PLANNING FAILED".
            PRINT "  No maneuver was executed. Manual control is available.".
            yieldToPrompt().
            RETURN.
        }

        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Return escape burn missed (attempt " + retries
                + ") - waiting 10s and replanning.").
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            IF retries >= MAX_RETRIES {
                mLogError("Return escape failed after " + retries
                    + " attempts - halting.").
                RETURN.
            }
            WAIT 10.
        }
    }

    nextPhase(xferSeq).
}
