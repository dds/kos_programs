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
    LOCAL targetAoP IS -1.
    LOCAL targetLan IS -1.
    IF CFG:HASKEY("CAPTURE_AOP") { SET targetAoP TO CFG["CAPTURE_AOP"]. }
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

    _correctPe(nd, target, targetPe).

    IF targetAoP >= 0 {
        _correctAoP(nd, target, targetAoP).
        _correctPe(nd, target, targetPe).
    }

    IF targetLan >= 0 {
        _correctLan(nd, target, targetLan).
        _correctPe(nd, target, targetPe).
    }

    LOCAL totalDv IS nd:DELTAV:MAG.
    LOCAL finalPatch IS _getTargetPatch(nd, target).

    IF totalDv < 0.1 OR finalPatch = 0 {
        mLog("Encounter on target. Skipping MCC burn.").
        REMOVE nd.
    } ELSE {
        LOCAL logMsg IS "MCC planned: dV=" + ROUND(totalDv, 1)
            + " m/s  Pe=" + ROUND(finalPatch:PERIAPSIS/1000,1) + "km".
        IF targetAoP >= 0 {
            SET logMsg TO logMsg + "  AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1) + "°".
        }
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

LOCAL FUNCTION _correctPe {
    PARAMETER nd, target, targetPe.
    FROM { LOCAL i IS 0. } UNTIL i >= 10 STEP { SET i TO i + 1. } DO {
        LOCAL p IS _getTargetPatch(nd, target).
        IF p = 0 OR p:PERIAPSIS < 0 { RETURN. }
        LOCAL err IS targetPe - p:PERIAPSIS.
        IF ABS(err) < MCC_PE_TOL { RETURN. }
        LOCAL basePe IS p:PERIAPSIS.
        LOCAL oldPro IS nd:PROGRADE.
        SET nd:PROGRADE TO oldPro + MCC_EPS.
        WAIT 0.05.
        LOCAL p2 IS _getTargetPatch(nd, target).
        SET nd:PROGRADE TO oldPro.
        IF p2 = 0 { RETURN. }
        LOCAL sens IS (p2:PERIAPSIS - basePe) / MCC_EPS.
        IF ABS(sens) < 1 { RETURN. }
        LOCAL dv IS err / sens * MCC_DAMP.
        SET nd:PROGRADE TO oldPro + dv.
        WAIT 0.05.
        IF nd:DELTAV:MAG > MCC_DV_CAP {
            SET nd:PROGRADE TO oldPro.
            RETURN.
        }
    }
}

LOCAL FUNCTION _correctAoP {
    PARAMETER nd, target, targetAoP.
    FROM { LOCAL i IS 0. } UNTIL i >= 10 STEP { SET i TO i + 1. } DO {
        LOCAL p IS _getTargetPatch(nd, target).
        IF p = 0 { RETURN. }
        LOCAL err IS targetAoP - p:ARGUMENTOFPERIAPSIS.
        IF err > 180 { SET err TO err - 360. }
        IF err < -180 { SET err TO err + 360. }
        IF ABS(err) < MCC_ANG_TOL { RETURN. }
        LOCAL baseAoP IS p:ARGUMENTOFPERIAPSIS.
        LOCAL oldRad IS nd:RADIALOUT.
        SET nd:RADIALOUT TO oldRad + MCC_EPS.
        WAIT 0.05.
        LOCAL p2 IS _getTargetPatch(nd, target).
        SET nd:RADIALOUT TO oldRad.
        IF p2 = 0 { RETURN. }
        LOCAL dAoP IS p2:ARGUMENTOFPERIAPSIS - baseAoP.
        IF dAoP > 180 { SET dAoP TO dAoP - 360. }
        IF dAoP < -180 { SET dAoP TO dAoP + 360. }
        IF ABS(dAoP) < 0.01 { RETURN. }
        LOCAL dv IS err / (dAoP / MCC_EPS) * MCC_DAMP.
        SET nd:RADIALOUT TO oldRad + dv.
        WAIT 0.05.
        IF nd:DELTAV:MAG > MCC_DV_CAP {
            SET nd:RADIALOUT TO oldRad.
            RETURN.
        }
    }
}

LOCAL FUNCTION _correctLan {
    PARAMETER nd, target, targetLan.
    FROM { LOCAL i IS 0. } UNTIL i >= 10 STEP { SET i TO i + 1. } DO {
        LOCAL p IS _getTargetPatch(nd, target).
        IF p = 0 { RETURN. }
        LOCAL err IS targetLan - p:LAN.
        IF err > 180 { SET err TO err - 360. }
        IF err < -180 { SET err TO err + 360. }
        IF ABS(err) < MCC_ANG_TOL { RETURN. }
        LOCAL baseLan IS p:LAN.
        LOCAL oldNrm IS nd:NORMAL.
        SET nd:NORMAL TO oldNrm + MCC_EPS.
        WAIT 0.05.
        LOCAL p2 IS _getTargetPatch(nd, target).
        SET nd:NORMAL TO oldNrm.
        IF p2 = 0 { RETURN. }
        LOCAL dLan IS p2:LAN - baseLan.
        IF dLan > 180 { SET dLan TO dLan - 360. }
        IF dLan < -180 { SET dLan TO dLan + 360. }
        IF ABS(dLan) < 0.01 { RETURN. }
        LOCAL dv IS err / (dLan / MCC_EPS) * MCC_DAMP.
        SET nd:NORMAL TO oldNrm + dv.
        WAIT 0.05.
        IF nd:DELTAV:MAG > MCC_DV_CAP {
            SET nd:NORMAL TO oldNrm.
            RETURN.
        }
    }
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
