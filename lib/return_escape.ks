// ============================================================
// return_escape.ks - lightweight Mun/Minmus -> Kerbin escape
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL ESCAPE_PE IS -1.
GLOBAL ESCAPE_KSC_TARGET IS 0.
GLOBAL REENTRY_PE IS 30000.
GLOBAL RETURN_ESCAPE_PE_TOLERANCE IS 1000.

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

// Fuel-weighted search can prefer a cheaper node just outside the entry
// corridor. Finish by targeting native parent-body Pe directly, without
// widening the burn acceptance gate or importing the full MCC solver.
LOCAL FUNCTION _polishReturnEscapePe {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targetPe.
    LOCAL initialDv IS nd:PROGRADE.
    LOCAL tolerance IS MAX(1,MIN(250,RETURN_ESCAPE_PE_TOLERANCE)).
    LOCAL iteration IS 0.
    LOCAL status IS "iteration-limit".
    UNTIL iteration >= 6 OR ABORT {
        LOCAL patch IS _targetPatch(nd,targetBody).
        IF patch = 0 { SET status TO "lost-parent-patch". BREAK. }
        LOCAL error IS targetPe - patch:PERIAPSIS.
        IF ABS(error) <= tolerance OR (iteration=0 AND ABS(error) <= RETURN_ESCAPE_PE_TOLERANCE) {
            SET status TO "converged". BREAK.
        }
        LOCAL baseDv IS nd:PROGRADE.
        SET nd:PROGRADE TO baseDv + 0.1.
        WAIT 0.05.
        LOCAL probe IS _targetPatch(nd,targetBody).
        LOCAL sensitivity IS 0.
        IF probe <> 0 { SET sensitivity TO (probe:PERIAPSIS - (targetPe-error)) / 0.1. }
        SET nd:PROGRADE TO baseDv.
        WAIT 0.05.
        IF NOT (ABS(sensitivity) > 0.001 AND ABS(sensitivity) < 1e30) {
            SET status TO "no-response". BREAK.
        }
        LOCAL correction IS MAX(-5,MIN(5,error/sensitivity)).
        LOCAL accepted IS FALSE.
        LOCAL fraction IS 1.
        LOCAL trial IS 0.
        UNTIL accepted OR trial >= 5 OR ABORT {
            SET nd:PROGRADE TO MAX(initialDv-10,MIN(initialDv+10,baseDv+fraction*correction)).
            WAIT 0.05.
            LOCAL candidate IS _targetPatch(nd,targetBody).
            IF candidate <> 0 {
                SET accepted TO ABS(candidate:PERIAPSIS-targetPe) < ABS(error).
            }
            SET fraction TO fraction/2.
            SET trial TO trial+1.
        }
        IF NOT accepted {
            SET nd:PROGRADE TO baseDv.
            WAIT 0.05.
            SET status TO "no-improvement". BREAK.
        }
        SET iteration TO iteration+1.
    }
    IF ABORT { SET status TO "abort". }
    LOCAL finalPatch IS _targetPatch(nd,targetBody).
    LOCAL finalPe IS -999999.
    IF finalPatch <> 0 { SET finalPe TO finalPatch:PERIAPSIS. }
    mLog("STATS return-escape refine status=" + status + " iterations=" + iteration
        + " deltaDv=" + (nd:PROGRADE-initialDv) + " predictedPe=" + finalPe
        + " targetPe=" + targetPe + " tolerance=" + tolerance).
    RETURN finalPatch <> 0 AND NOT ABORT
        AND ABS(finalPe-targetPe) <= RETURN_ESCAPE_PE_TOLERANCE.
}

// Coupled fallback for a poor timing/prograde seed. A one-axis derivative
// can be flat at the lowest reachable Pe in that departure plane; normal
// thrust and burn epoch must then move as well. Only native patches decide.
LOCAL FUNCTION _returnEscapeTrial {
    PARAMETER ctx.
    PARAMETER epoch.
    PARAMETER progradeDv.
    PARAMETER normalDv.
    IF ABORT OR ctx["TRIALS"] >= 256 OR TIME:SECONDS >= ctx["DEADLINE"] { RETURN. }
    LOCAL nd IS ctx["NODE"].
    SET nd:TIME TO MAX(ctx["START"],MIN(ctx["END"],epoch)).
    SET nd:PROGRADE TO MAX(0,MIN(ctx["BUDGET"],progradeDv)).
    LOCAL normalCap IS SQRT(MAX(0,ctx["BUDGET"]^2-nd:PROGRADE^2)).
    SET nd:NORMAL TO MAX(-normalCap,MIN(normalCap,normalDv)).
    WAIT 0.02.
    SET ctx["TRIALS"] TO ctx["TRIALS"]+1.
    LOCAL patch IS _targetPatch(nd,ctx["BODY"]).
    IF patch = 0 { RETURN. }
    LOCAL error IS ABS(patch:PERIAPSIS-ctx["PE"]).
    IF NOT (error >= 0 AND error < 1e30) { RETURN. }
    LOCAL feasible IS error <= RETURN_ESCAPE_PE_TOLERANCE.
    LOCAL bestFeasible IS ctx["ERROR"] <= RETURN_ESCAPE_PE_TOLERANCE.
    LOCAL cost IS nd:DELTAV:MAG*0.01.
    IF ctx["KSC"] {
        SET cost TO cost+_escapeKscPenalty(nd,ctx["BODY"],nd:TIME,
            ctx["TRANSIT_A"],ctx["PARENT_MU"],-74.6).
    }
    IF (feasible AND NOT bestFeasible)
            OR (feasible AND bestFeasible AND cost < ctx["COST"])
            OR (NOT bestFeasible AND error < ctx["ERROR"]) {
        SET ctx["ERROR"] TO error.
        SET ctx["DV"] TO nd:DELTAV:MAG.
        SET ctx["COST"] TO cost.
        SET ctx["TIME"] TO nd:TIME.
        SET ctx["PROGRADE"] TO nd:PROGRADE.
        SET ctx["NORMAL"] TO nd:NORMAL.
    }
}

LOCAL FUNCTION _jointReturnEscape {
    PARAMETER nd.
    PARAMETER parentBody.
    PARAMETER targetPe.
    PARAMETER seedDv.
    LOCAL budget IS SHIP:DELTAV:VACUUM.
    IF NOT (budget > 0 AND budget < 1e30) { RETURN FALSE. }
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL ctx IS LEXICON("NODE",nd,"BODY",parentBody,"PE",targetPe,
        "START",TIME:SECONDS+60,"END",TIME:SECONDS+60+period,
        "BUDGET",budget,"DEADLINE",TIME:SECONDS+20,"TRIALS",0,
        "ERROR",1e30,"DV",1e30,"COST",1e30,"KSC",ESCAPE_KSC_TARGET <> 0,
        "TIME",nd:TIME,"PROGRADE",nd:PROGRADE,"NORMAL",nd:NORMAL).
    IF ctx["KSC"] {
        SET ctx["TRANSIT_A"] TO (SHIP:BODY:ORBIT:SEMIMAJORAXIS+parentBody:RADIUS+targetPe)/2.
        SET ctx["PARENT_MU"] TO parentBody:MU.
    }
    _returnEscapeTrial(ctx,nd:TIME,nd:PROGRADE,nd:NORMAL).
    // Scan thrust AND time, rather than freezing a time chosen at one thrust.
    LOCAL sample IS 0.
    UNTIL sample >= 12 OR ABORT OR TIME:SECONDS >= ctx["DEADLINE"] {
        LOCAL epoch IS ctx["START"]+sample*period/12.
        FOR fraction IN LIST(0.85,1,1.25) {
            _returnEscapeTrial(ctx,epoch,seedDv*fraction,0).
        }
        SET sample TO sample+1.
    }
    LOCAL timeStep IS period/24.
    LOCAL dvStep IS MAX(5,seedDv*0.15).
    LOCAL normalStep IS dvStep.
    LOCAL iteration IS 0.
    UNTIL ctx["ERROR"] <= RETURN_ESCAPE_PE_TOLERANCE OR iteration >= 32
            OR ctx["TRIALS"] >= 256 OR ABORT OR TIME:SECONDS >= ctx["DEADLINE"] {
        LOCAL baseTime IS ctx["TIME"].
        LOCAL baseDv IS ctx["PROGRADE"].
        LOCAL baseNormal IS ctx["NORMAL"].
        LOCAL baseError IS ctx["ERROR"].
        FOR sign IN LIST(-1,1) {
            _returnEscapeTrial(ctx,baseTime+sign*timeStep,baseDv,baseNormal).
            _returnEscapeTrial(ctx,baseTime,baseDv+sign*dvStep,baseNormal).
            _returnEscapeTrial(ctx,baseTime,baseDv,baseNormal+sign*normalStep).
        }
        IF ctx["ERROR"] >= baseError {
            SET timeStep TO timeStep/2.
            SET dvStep TO dvStep/2.
            SET normalStep TO normalStep/2.
        }
        SET iteration TO iteration+1.
    }
    SET nd:TIME TO ctx["TIME"].
    SET nd:PROGRADE TO ctx["PROGRADE"].
    SET nd:NORMAL TO ctx["NORMAL"].
    WAIT 0.05.
    mLog("STATS return-escape joint trials=" + ctx["TRIALS"]
        + " iterations=" + iteration + " peError=" + ctx["ERROR"]
        + " dv=" + ctx["DV"] + " prograde=" + nd:PROGRADE + " normal=" + nd:NORMAL
        + " eta=" + (nd:TIME-TIME:SECONDS) + " abort=" + ABORT
        + " deadline=" + (TIME:SECONDS >= ctx["DEADLINE"])).
    RETURN NOT ABORT AND ctx["ERROR"] <= RETURN_ESCAPE_PE_TOLERANCE.
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
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.

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

    IF NOT _polishReturnEscapePe(nd,targetBody,targetPe) AND NOT ABORT {
        _jointReturnEscape(nd,targetBody,targetPe,escapeDv).
    }
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

GLOBAL FUNCTION previewReturnEscape {
    PARAMETER targetPe IS 53000.
    IF (BODY:NAME <> "Mun" AND BODY:NAME <> "Minmus")
            OR SHIP:STATUS <> "ORBITING" {
        PRINT "Return preview requires a bound Mun/Minmus orbit.".
        RETURN FALSE.
    }
    IF HASNODE {
        PRINT "Existing maneuver retained. Remove it before requesting a new preview.".
        RETURN FALSE.
    }
    SET ESCAPE_KSC_TARGET TO 0.
    LOCAL nd IS _planReturnEscape(BODY:BODY, targetPe).
    IF nd = 0 { RETURN FALSE. }
    LOCAL patch IS _targetPatch(nd, BODY:BODY).
    PRINT "RETURN PREVIEW ONLY - no burn or phase change".
    PRINT "  Burn: " + ROUND(nd:DELTAV:MAG,2) + " m/s".
    PRINT "  Remaining after burn (estimate): "
        + ROUND(SHIP:DELTAV:VACUUM - nd:DELTAV:MAG,2) + " m/s".
    PRINT "  Predicted Kerbin Pe: " + ROUND(patch:PERIAPSIS/1000,2) + " km".
    PRINT "  Target: " + targetPe/1000 + " km; KSC targeting disabled for this preview.".
    PRINT "  Entry corridor valid: " + _returnEscapeEntryValid(patch:PERIAPSIS, targetPe).
    PRINT "  Burn affordable: " + (nd:DELTAV:MAG <= SHIP:DELTAV:VACUUM).
    IF NOT _returnEscapeEntryValid(patch:PERIAPSIS, targetPe) {
        PRINT "  REJECTED: escape found, requested Kerbin reentry NOT found.".
    }
    IF nd:DELTAV:MAG > SHIP:DELTAV:VACUUM {
        PRINT "  REJECTED: maneuver exceeds remaining fuel.".
    }
    PRINT "  Leave automation stopped and review these numbers before burning.".
    mLog("STATS return-preview dv=" + nd:DELTAV:MAG
        + " available=" + SHIP:DELTAV:VACUUM + " pe=" + patch:PERIAPSIS).
    RETURN TRUE.
}

LOCAL FUNCTION _returnEscapeEntryValid {
    PARAMETER predictedPe.
    PARAMETER targetPe.
    RETURN ABS(predictedPe - targetPe) <= RETURN_ESCAPE_PE_TOLERANCE.
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

    // ESCAPE plans a burn to leave a CAPTURED (bound) orbit. On a
    // hyperbolic flyby the craft is already leaving — SHIP:ORBIT:PERIOD
    // is Infinity and the planner pushes Infinity onto the stack.
    // Detect "already escaping" and hand forward, no redundant burn.
    IF SHIP:ORBIT:ECCENTRICITY >= 1 OR SHIP:ORBIT:HASNEXTPATCH {
        mLog("ESCAPE: already leaving " + BODY:NAME + " (ecc="
            + ROUND(SHIP:ORBIT:ECCENTRICITY, 2)
            + ") — no escape burn needed; handing forward.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL target IS BODY:BODY.
    LOCAL targetPe IS _returnTargetPe().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    IF HASNODE {
        PRINT "Existing maneuver retained; remove/review it before automatic return planning.".
        yieldToPrompt(). RETURN.
    }

    UNTIL success {
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

        LOCAL returnPatch IS _targetPatch(nd, target).
        IF returnPatch = 0 {
            mLogError("STATS return-escape hold reason=lost-parent-patch").
            REMOVE nd.
            yieldToPrompt().
            RETURN.
        }
        IF ABORT OR NOT _returnEscapeEntryValid(returnPatch:PERIAPSIS, targetPe)
                OR nd:DELTAV:MAG > SHIP:DELTAV:VACUUM {
            mLogError("STATS return-escape hold reason=entry-or-fuel dv="
                + nd:DELTAV:MAG + " available=" + SHIP:DELTAV:VACUUM
                + " predictedPe=" + returnPatch:PERIAPSIS + " targetPe=" + targetPe
                + " peError=" + (returnPatch:PERIAPSIS-targetPe)
                + " tolerance=" + RETURN_ESCAPE_PE_TOLERANCE
                + " entryOk=" + _returnEscapeEntryValid(returnPatch:PERIAPSIS,targetPe)
                + " fuelOk=" + (nd:DELTAV:MAG <= SHIP:DELTAV:VACUUM)).
            PRINT "RETURN ESCAPE REJECTED - NO BURN".
            PRINT "  dV required/available: " + ROUND(nd:DELTAV:MAG,1)
                + "/" + ROUND(SHIP:DELTAV:VACUUM,1) + " m/s".
            PRINT "  Predicted/target Kerbin Pe: " + ROUND(returnPatch:PERIAPSIS/1000,1)
                + "/" + ROUND(targetPe/1000,1) + " km".
            REMOVE nd.
            PRINT "  Rejected planner node removed; mission held, no burn.".
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
