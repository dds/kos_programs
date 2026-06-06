// ============================================================
// mcc.ks  —  Mid-Course Correction phase  (0:/lib/mcc.ks)
// ============================================================

LOCAL MCC_DV_CAP IS 50.

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

    // Resolve CAPTURE_DIR to inclination (same mapping as planTransfer)
    IF CFG:HASKEY("CAPTURE_DIR") {
        LOCAL dir IS CFG["CAPTURE_DIR"]:TOUPPER.
        IF dir = "PROGRADE"   { SET targetInc TO 0. }
        IF dir = "POLAR"      { SET targetInc TO 90. }
        IF dir = "RETROPOLAR" { SET targetInc TO 90. }
        IF dir = "RETROGRADE" { SET targetInc TO 180. }
    }
    // Explicit CAPTURE_INC overrides CAPTURE_DIR
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

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + waitTime, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    _optimizeMCC(nd, target, targetPe, targetInc, targetLan, targetAoP).

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
        IF targetAoP >= 0 {
            SET logMsg TO logMsg + "  AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1) + "°".
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

// ============================================================
// Phased MCC optimizer — solves each orbital parameter via
// independent Newton-Raphson on the appropriate maneuver axis.
// Order: INC (normal) → AoP (radial) → PE (prograde) →
//        LAN (normal) → PE cleanup.
// Solving normal first ensures the orbital plane is right
// before dialling in energy, matching how you'd do it manually.
// ============================================================
LOCAL FUNCTION _optimizeMCC {
    PARAMETER mccNode.
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER targetInc.
    PARAMETER targetLan.
    PARAMETER targetAoP.

    mLog("Starting phased MCC optimization...").

    // Phase 1: Inclination via NORMAL (get orbital plane right first)
    IF targetInc >= 0 {
        _mccNewton(mccNode, targetBody, "INC", targetInc).
    }

    // Phase 2: AoP via RADIALOUT
    IF targetAoP >= 0 {
        _mccNewton(mccNode, targetBody, "AOP", targetAoP).
    }

    // Phase 3: PE via PROGRADE
    _mccNewton(mccNode, targetBody, "PE", targetPe).

    // Phase 4: LAN via NORMAL (small tweaks on top of inc correction)
    IF targetLan >= 0 {
        _mccNewton(mccNode, targetBody, "LAN", targetLan).
        // Re-correct PE since normal changes drift it
        _mccNewton(mccNode, targetBody, "PE", targetPe).
    }

    // --- FINAL REPORT ---
    LOCAL finalPatch IS _getTargetPatch(mccNode, targetBody).
    LOCAL totalDv IS mccNode:DELTAV:MAG.

    mLog("MCC complete: dV=" + ROUND(totalDv, 2)
        + " m/s (P:" + ROUND(mccNode:PROGRADE,2)
        + " R:" + ROUND(mccNode:RADIALOUT,2)
        + " N:" + ROUND(mccNode:NORMAL,2) + ")").

    IF finalPatch <> 0 {
        mLog("Result - PE: " + ROUND(finalPatch:PERIAPSIS/1000, 1)
            + "km  INC: " + ROUND(finalPatch:INCLINATION, 1)
            + "°  LAN: " + ROUND(finalPatch:LAN, 1) + "°").
    }

    RETURN mccNode.
}

// ============================================================
// Generic Newton-Raphson for a single orbital parameter.
// param: "PE", "INC", "LAN", or "AOP"
// Each maps to a specific maneuver axis:
//   PE  → PROGRADE,  INC → NORMAL,
//   LAN → NORMAL,    AOP → RADIALOUT
// ============================================================
LOCAL FUNCTION _mccNewton {
    PARAMETER mccNode.
    PARAMETER targetBody.
    PARAMETER param.
    PARAMETER targetVal.

    LOCAL isAngle IS (param <> "PE").
    LOCAL eps  IS CHOOSE 0.5 IF isAngle ELSE 0.1.
    LOCAL damp IS 0.7.
    LOCAL tol  IS CHOOSE 1.0 IF isAngle ELSE 500.
    LOCAL maxIter IS 25.

    mLog("MCC " + param + ": targeting " + ROUND(targetVal, CHOOSE 1 IF isAngle ELSE 0)).

    FROM { LOCAL i IS 0. } UNTIL i >= maxIter STEP { SET i TO i + 1. } DO {
        LOCAL p IS _getTargetPatch(mccNode, targetBody).
        IF p = 0 OR p:PERIAPSIS < 0 {
            mLog("  " + param + "[" + i + "]: lost encounter.").
            BREAK.
        }

        LOCAL current IS _mccReadParam(p, param).
        LOCAL err IS targetVal - current.

        // Wrap angular errors to ±180
        IF isAngle {
            IF err > 180 { SET err TO err - 360. }
            IF err < -180 { SET err TO err + 360. }
        }

        IF ABS(err) < tol {
            mLog("  " + param + "[" + i + "] converged: " + ROUND(current, 1)).
            BREAK.
        }

        // Finite difference for sensitivity
        LOCAL oldVal IS _mccGetAxis(mccNode, param).
        _mccSetAxis(mccNode, param, oldVal + eps).
        WAIT 0.02.
        LOCAL p2 IS _getTargetPatch(mccNode, targetBody).
        _mccSetAxis(mccNode, param, oldVal).
        IF p2 = 0 OR p2:PERIAPSIS < 0 { BREAK. }

        LOCAL current2 IS _mccReadParam(p2, param).
        LOCAL delta IS current2 - current.
        IF isAngle {
            IF delta > 180 { SET delta TO delta - 360. }
            IF delta < -180 { SET delta TO delta + 360. }
        }

        LOCAL sens IS delta / eps.
        IF ABS(sens) < 0.001 { BREAK. }

        LOCAL correction IS (err / sens) * damp.
        LOCAL maxStep IS CHOOSE MAX(5.0, ABS(err) / 3) IF isAngle ELSE MAX(3.0, ABS(err) / 5000).
        IF correction >  maxStep { SET correction TO  maxStep. }
        IF correction < -maxStep { SET correction TO -maxStep. }

        // Apply correction, then check dV cap and encounter
        LOCAL lastGood IS oldVal.
        _mccSetAxis(mccNode, param, oldVal + correction).
        WAIT 0.02.

        IF mccNode:DELTAV:MAG > MCC_DV_CAP {
            _mccSetAxis(mccNode, param, lastGood).
            mLog("  " + param + "[" + i + "]: dV cap (" + MCC_DV_CAP + " m/s) reached.").
            BREAK.
        }

        LOCAL pCheck IS _getTargetPatch(mccNode, targetBody).
        IF pCheck = 0 OR pCheck:PERIAPSIS < 0 {
            // Backtrack to half correction
            _mccSetAxis(mccNode, param, oldVal + correction / 2).
            WAIT 0.02.
            LOCAL pHalf IS _getTargetPatch(mccNode, targetBody).
            IF pHalf = 0 OR pHalf:PERIAPSIS < 0 {
                _mccSetAxis(mccNode, param, lastGood).
                mLog("  " + param + "[" + i + "]: backtrack failed, reverting.").
                BREAK.
            }
        }

        mLog("  " + param + "[" + i + "] val=" + ROUND(current, 1) + "  corr=" + ROUND(correction, 2) + " m/s").
    }
}

// Helpers: read orbital parameter from patch
LOCAL FUNCTION _mccReadParam {
    PARAMETER p, param.
    IF param = "PE"  { RETURN p:PERIAPSIS. }
    IF param = "INC" { RETURN p:INCLINATION. }
    IF param = "LAN" { RETURN p:LAN. }
    IF param = "AOP" { RETURN p:ARGUMENTOFPERIAPSIS. }
    RETURN 0.
}

// Helpers: get/set the node axis that controls a given parameter
LOCAL FUNCTION _mccGetAxis {
    PARAMETER nd, param.
    IF param = "PE"  { RETURN nd:PROGRADE. }
    IF param = "INC" { RETURN nd:NORMAL. }
    IF param = "LAN" { RETURN nd:NORMAL. }
    IF param = "AOP" { RETURN nd:RADIALOUT. }
    RETURN 0.
}

LOCAL FUNCTION _mccSetAxis {
    PARAMETER nd, param, val.
    IF param = "PE"  { SET nd:PROGRADE   TO val. }
    IF param = "INC" { SET nd:NORMAL     TO val. }
    IF param = "LAN" { SET nd:NORMAL     TO val. }
    IF param = "AOP" { SET nd:RADIALOUT  TO val. }
}
