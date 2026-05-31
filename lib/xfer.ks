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
    mLog("Planning capture at " + target:NAME + ".").
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL captureAlt IS CFG["RELAY_ALT"].
        IF CFG:HASKEY("TARGET_AP") { SET captureAlt TO CFG["TARGET_AP"]. }
        planCapture(target, captureAlt).
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

    IF CFG:HASKEY("CAPTURE_AOP") {
        LOCAL targetAoP IS CFG["CAPTURE_AOP"].
        LOCAL deltaAoP IS ABS(SHIP:ORBIT:ARGUMENTOFPERIAPSIS - targetAoP).
        IF deltaAoP > 180 { SET deltaAoP TO 360 - deltaAoP. }
        IF deltaAoP > 2 {
            mLog("Post-capture AoP correction: current=" + ROUND(SHIP:ORBIT:ARGUMENTOFPERIAPSIS,1)
                + " target=" + ROUND(targetAoP,1)).
            LOCAL aopOk IS FALSE.
            LOCAL aopRetries IS 0.
            UNTIL aopOk {
                UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
                LOCAL nd IS planAoPChange(targetAoP).
                IF nd = 0 { SET aopOk TO TRUE. }
                ELSE IF NEXTNODE:DELTAV:MAG > 200 {
                    mLogWarn("AoP correction would cost " + ROUND(NEXTNODE:DELTAV:MAG, 0) + "m/s. Exceeds safe limit — skipping.").
                    REMOVE NEXTNODE.
                    SET aopOk TO TRUE. 
                } ELSE {
                    SET aopOk TO executeManeuver().
                    IF NOT aopOk {
                        SET aopRetries TO aopRetries + 1.
                        mLog("AoP correction missed (attempt " + aopRetries + ").").
                        IF aopRetries >= MAX_RETRIES { SET aopOk TO TRUE. }
                        WAIT 10.
                    }
                }
            }
            orbitSummary().
        } ELSE {
            mLog("AoP already within 2deg — skipping.").
        }
    }

    IF CFG:HASKEY("CAPTURE_INC") {
        LOCAL targetInc IS CFG["CAPTURE_INC"].
        LOCAL deltaInc IS ABS(SHIP:ORBIT:INCLINATION - targetInc).
        LOCAL incTol IS 0.5.
        IF CFG:HASKEY("INCL_TOLERANCE") { SET incTol TO CFG["INCL_TOLERANCE"]. }
        IF deltaInc > incTol {
            mLog("Post-capture INC correction: current=" + ROUND(SHIP:ORBIT:INCLINATION,2)
                + " target=" + ROUND(targetInc,2)).
            LOCAL incOk IS FALSE.
            LOCAL incRetries IS 0.
            UNTIL incOk {
                UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
                planInclinationChange(targetInc).
                SET incOk TO executeManeuver().
                IF NOT incOk {
                    SET incRetries TO incRetries + 1.
                    mLog("INC correction missed (attempt " + incRetries + ").").
                    IF incRetries >= MAX_RETRIES { SET incOk TO TRUE. }
                    WAIT 10.
                }
            }
            orbitSummary().
        } ELSE {
            mLog("Inclination within tolerance — skipping.").
        }
    }

    nextPhase(xferSeq).
}

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
