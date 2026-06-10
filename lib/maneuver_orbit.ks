// ============================================================
// maneuver_orbit.ks  —  Post-capture orbit adjustment phases
// (0:/lib/maneuver_orbit.ks)
//
// phaseCirc                  — circularize or handle impact threat
// phaseRaiseAlt              — raise Pe/Ap to target ellipse or relay alt
// phaseInclCorrect           — correct orbital inclination
// phaseElliptical            — unified PE/INC/LAN/AoP hill-climb solver
//
// Payload/ScanSat impact-release lives in payload_release.ks
// (own band, loaded only when DROP_FOR_IMPACT_AND_RAISE_PE runs).
// ============================================================

LOCAL MAX_RETRIES IS 5.
LOCAL DEFAULT_CIRC_ECC_TOL IS 0.005.
LOCAL DEFAULT_INCL_TOLERANCE IS 0.01.
LOCAL DEFAULT_MAX_INCL_CHANGE_DV IS 300.

LOCAL FUNCTION _orbitCfgNum {
    PARAMETER key.
    PARAMETER defaultValue.
    IF CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _bodyImpactFloor {
    LOCAL body_ IS SHIP:ORBIT:BODY.
    IF body_:ATM:EXISTS { RETURN body_:ATM:HEIGHT + 1000. }
    RETURN 5000.
}

GLOBAL FUNCTION phaseCirc {
    IF CFG:HASKEY("SCANSAT_RELEASE_AFTER_CAPTURE")
            AND CFG["SCANSAT_RELEASE_AFTER_CAPTURE"] > 0 {
        // Hand off via the phase machine: the handler lives in the
        // payload_release band, so a direct call would crash here.
        // runPhases sees the missing handler and requests the reload.
        mLog("CIRC redirected to drop-for-impact recovery profile.").
        stateSet("phase", "DROP_FOR_IMPACT_AND_RAISE_PE").
        RETURN.
    }

    LOCAL circStatus IS "complete".
    mLogWarn("STATS circ phase setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    IF _impactThreat() {
        LOCAL safePe IS _orbitCfgNum("PARKING_ALT", 80000).
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
    } ELSE IF SHIP:ORBIT:ECCENTRICITY < _orbitCfgNum("CIRC_ECC_TOL", DEFAULT_CIRC_ECC_TOL) {
        mLog("Already circular (ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4) + ").").
        SET circStatus TO "skipped".
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
    mLogWarn("STATS circ phase result status=" + circStatus
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    nextPhase(xferSeq).
}



GLOBAL FUNCTION phaseRaiseAlt {
    LOCAL elliptical IS CFG:HASKEY("TARGET_PE") AND CFG:HASKEY("TARGET_AP").
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    mLogWarn("STATS raise phase setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " elliptical=" + elliptical).

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
            mLogWarn("STATS raise phase result status=skipped PeKm="
                + ROUND(SHIP:PERIAPSIS/1000,1)
                + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
            nextPhase(xferSeq).
            RETURN.
        }
        mLog("Raising Ap to " + ROUND(targetAp/1000,0) + "km.").
        _burnWithRetry(
            { LOCAL rBurn IS bodyR + SHIP:PERIAPSIS. LOCAL rTarget IS bodyR + targetAp. LOCAL tSMA IS (rBurn + rTarget) / 2. LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG. LOCAL vNew IS SQRT(mu * (2/rBurn - 1/tSMA)). RETURN NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, vNew - vNow). },
            "Raise Ap").
    }

    orbitSummary().
    mLogWarn("STATS raise phase result status=complete PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseRaise {
    phaseRaiseAlt().
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
        archivePlannedManeuverLog(label).
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
    LOCAL inclTol IS _orbitCfgNum("INCL_TOLERANCE", DEFAULT_INCL_TOLERANCE).
    LOCAL maxInclDv IS _orbitCfgNum("MAX_INCL_CHANGE_DV", DEFAULT_MAX_INCL_CHANGE_DV).
    mLogWarn("STATS incline phase setup current=" + ROUND(currentInc,2)
        + " target=" + ROUND(targetInc,2)
        + " tol=" + inclTol).

    IF currentInc > 90 AND targetInc < 90 {
        mLogWarn("Retrograde orbit detected (inc=" + ROUND(currentInc,1)
            + "deg) but target is prograde (" + ROUND(targetInc,1)
            + "deg) — plane change would cost ~600m/s. Skipping.").
        mLogWarn("STATS incline phase result status=skipped reason=retrograde-safety current="
            + ROUND(currentInc,2)
            + " target=" + ROUND(targetInc,2)).
        HUDTEXT("WARNING: Retrograde orbit — skipping incl correction",
            8, 2, 15, YELLOW, FALSE).
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL deltaInc IS ABS(currentInc - targetInc).
    IF deltaInc <= inclTol {
        mLog("Inclination within tolerance — skipping.").
        mLogWarn("STATS incline phase result status=skipped current="
            + ROUND(currentInc,2)
            + " target=" + ROUND(targetInc,2)).
        nextPhase(xferSeq).
        RETURN.
    }

    mLog("Correcting inclination: " + ROUND(currentInc,2)
        + "deg -> " + ROUND(targetInc,2)
        + "deg  delta=" + ROUND(deltaInc,2) + "deg").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    planInclinationChange(targetInc).

    IF NEXTNODE:DELTAV:MAG > maxInclDv {
        mLogWarn("Inclination correction would cost " + ROUND(NEXTNODE:DELTAV:MAG,0)
            + "m/s — exceeds MAX_INCL_CHANGE_DV. Skipping.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        nextPhase(xferSeq).
        RETURN.
    }

    executeManeuver().
    orbitSummary().
    mLogWarn("STATS incline phase result status=complete current="
        + ROUND(SHIP:ORBIT:INCLINATION,2)
        + " target=" + ROUND(targetInc,2)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseIncline {
    phaseInclCorrect().
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
    WAIT 2.
    mLog("Planning bounded elliptical orbit finalization.").

    LOCAL targetPe  IS -1.
    LOCAL targetAp  IS -1.
    LOCAL targetInc IS -1.
    LOCAL targetAoP IS -1.

    IF CFG:HASKEY("TARGET_PE")   { SET targetPe TO CFG["TARGET_PE"]. }
    IF CFG:HASKEY("TARGET_AP")   { SET targetAp TO CFG["TARGET_AP"]. }
    IF CFG:HASKEY("CAPTURE_INC") { SET targetInc TO CFG["CAPTURE_INC"]. }
    IF CFG:HASKEY("CAPTURE_AOP") { SET targetAoP TO CFG["CAPTURE_AOP"]. }

    IF targetPe < 0 AND targetAp < 0 AND targetAoP < 0 {
        mLog("No elliptical finalization targets specified. Skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }

    IF targetPe >= 0 AND NOT _ellipticalRecoveryWindowSafe(targetPe) {
        mLogError("Elliptical recovery halted: apoapsis burn occurs after impact.").
        mLogWarn("STATS elliptical precheck status=blocked reason=recovery-window"
            + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + " targetPeKm=" + ROUND(targetPe/1000,1)
            + " floorPeKm=" + ROUND(_bodyImpactFloor()/1000,1)
            + " etaAp=" + ROUND(ETA:APOAPSIS,1)
            + " etaPe=" + ROUND(ETA:PERIAPSIS,1)).
        PRINT " ".
        PRINT "  ELLIPTICAL RECOVERY HOLD".
        PRINT "  Apoapsis burn is after impact. Manual control is available.".
        yieldToPrompt().
        RETURN.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL maxDv IS 300.
    IF CFG:HASKEY("ELLIPTICAL_MAX_NODE_DV") { SET maxDv TO CFG["ELLIPTICAL_MAX_NODE_DV"]. }

    IF targetPe >= 0 AND ABS(SHIP:PERIAPSIS - targetPe) > MAX(5000, targetPe * 0.01) {
        LOCAL burnTime IS TIME:SECONDS + ETA:APOAPSIS.
        LOCAL rAp IS bodyR + SHIP:APOAPSIS.
        LOCAL rPe IS bodyR + targetPe.
        LOCAL tSMA IS (rAp + rPe) / 2.
        LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG.
        LOCAL vNew IS SQRT(mu * (2/rAp - 1/tSMA)).
        LOCAL nd IS NODE(burnTime, 0, 0, vNew - vNow).
        ADD nd.
        WAIT 0.2.
        IF _ellipticalNodeBad(nd, targetPe, targetAp, targetInc, maxDv, "raise-pe") {
            REMOVE nd.
            yieldToPrompt().
            RETURN.
        }
        mLog("Elliptical raise Pe: dV=" + ROUND(nd:DELTAV:MAG,1)
            + " m/s  Pe=" + ROUND(nd:ORBIT:PERIAPSIS/1000,1)
            + "km Ap=" + ROUND(nd:ORBIT:APOAPSIS/1000,1) + "km").
        archivePlannedManeuverLog("elliptical-raise-pe").
        IF NOT _executeEllipticalStep("Elliptical raise Pe") { RETURN. }
    } ELSE {
        mLog("Elliptical Pe already within tolerance.").
    }

    IF targetAoP >= 0 {
        LOCAL aopErr IS _angleDiff(SHIP:ORBIT:ARGUMENTOFPERIAPSIS, targetAoP).
        IF ABS(aopErr) > 3 {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            LOCAL aopNode IS planAoPChange(targetAoP).
            IF aopNode <> 0 AND aopNode:ISTYPE("Node") {
                WAIT 0.2.
                IF _ellipticalNodeBad(aopNode, targetPe, targetAp, targetInc, maxDv, "aop") {
                    REMOVE aopNode.
                    yieldToPrompt().
                    RETURN.
                }
                IF NOT _executeEllipticalStep("Elliptical AoP trim") { RETURN. }
            }
        } ELSE {
            mLog("Elliptical AoP already within tolerance.").
        }
    }

    orbitSummary().
    mLog("Orbit finalization complete!").
    nextPhase(xferSeq).
}

LOCAL FUNCTION _ellipticalRecoveryWindowSafe {
    PARAMETER targetPe.
    IF SHIP:PERIAPSIS >= _bodyImpactFloor() { RETURN TRUE. }
    LOCAL margin IS 60.
    IF CFG:HASKEY("ELLIPTICAL_RECOVERY_MARGIN") { SET margin TO CFG["ELLIPTICAL_RECOVERY_MARGIN"]. }
    RETURN ETA:APOAPSIS + margin < ETA:PERIAPSIS.
}

LOCAL FUNCTION _angleDiff {
    PARAMETER current.
    PARAMETER target.
    LOCAL err IS current - target.
    IF err > 180 { SET err TO err - 360. }
    IF err < -180 { SET err TO err + 360. }
    RETURN err.
}

LOCAL FUNCTION _ellipticalNodeBad {
    PARAMETER nd.
    PARAMETER targetPe.
    PARAMETER targetAp.
    PARAMETER targetInc.
    PARAMETER maxDv.
    PARAMETER label.

    LOCAL p IS nd:ORBIT.
    LOCAL bad IS FALSE.
    LOCAL reason IS "".
    IF nd:DELTAV:MAG > maxDv {
        SET bad TO TRUE.
        SET reason TO "dv-cap".
    } ELSE IF p:HASNEXTPATCH {
        SET bad TO TRUE.
        SET reason TO "escape".
    } ELSE IF targetPe >= 0 AND ABS(p:PERIAPSIS - targetPe) > MAX(25000, targetPe * 0.15) {
        SET bad TO TRUE.
        SET reason TO "pe-error".
    } ELSE IF targetAp >= 0 AND ABS(p:APOAPSIS - targetAp) > MAX(50000, targetAp * 0.15) {
        SET bad TO TRUE.
        SET reason TO "ap-error".
    } ELSE IF targetInc >= 0 AND ABS(_angleDiff(p:INCLINATION, targetInc)) > 5 {
        SET bad TO TRUE.
        SET reason TO "inc-error".
    }

    IF bad {
        mLogError("Elliptical " + label + " node rejected: " + reason + ".").
        mLogWarn("STATS elliptical rejected label=" + label
            + " reason=" + reason
            + " dv=" + ROUND(nd:DELTAV:MAG,1)
            + " PeKm=" + ROUND(p:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(p:APOAPSIS/1000,1)
            + " inc=" + ROUND(p:INCLINATION,1)
            + " AoP=" + ROUND(p:ARGUMENTOFPERIAPSIS,1)).
        PRINT " ".
        PRINT "  ELLIPTICAL NODE REJECTED".
        PRINT "  " + reason + ". Manual control is available.".
    }
    RETURN bad.
}

LOCAL FUNCTION _executeEllipticalStep {
    PARAMETER label.
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog(label + " missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError(label + " failed after " + retries + " attempts.").
                yieldToPrompt().
                RETURN FALSE.
            }
            WAIT 10.
        }
    }
    RETURN TRUE.
}
