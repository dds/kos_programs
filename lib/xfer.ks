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
        planTransfer(target, CFG["CAPTURE_PE"]).
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
                ELSE IF NEXTNODE:DELTAV:MAG > 50 {
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
    LOCAL targetAp IS CFG["RELAY_ALT"].
    IF elliptical { SET targetAp TO CFG["TARGET_AP"]. }

    IF SHIP:APOAPSIS > targetAp * 0.99 {
        mLog("Already at target Ap.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL targetPe IS SHIP:PERIAPSIS.
    IF elliptical { SET targetPe TO CFG["TARGET_PE"]. }

    IF elliptical {
        mLog("Target ellipse: Pe=" + ROUND(targetPe/1000,0) + "km  Ap=" + ROUND(targetAp/1000,0) + "km.").
    } ELSE {
        mLog("Raising Ap to " + ROUND(targetAp/1000,0) + "km.").
    }

    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL rBurn IS bodyR + SHIP:PERIAPSIS.
        LOCAL rTarget IS bodyR + targetAp.
        LOCAL tSMA IS (rBurn + rTarget) / 2.
        LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG.
        LOCAL vNew IS SQRT(mu * (2/rBurn - 1/tSMA)).
        LOCAL dv IS vNew - vNow.
        LOCAL nd IS NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, dv).
        ADD nd.
        mLog("Raise Ap: dV=" + ROUND(dv,1) + " m/s at Pe").
        WAIT 2.
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Raise Ap missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError("Raise Ap failed after " + retries + " attempts — halting.").
                nextPhase(xferSeq).
                RETURN.
            }
            WAIT 10.
        }
    }

    IF elliptical {
        LOCAL deltaPe IS ABS(SHIP:PERIAPSIS - targetPe).
        IF deltaPe > targetPe * 0.05 {
            SET success TO FALSE.
            SET retries TO 0.
            UNTIL success {
                UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
                LOCAL rAp IS bodyR + SHIP:APOAPSIS.
                LOCAL rPe IS bodyR + targetPe.
                LOCAL tSMA IS (rAp + rPe) / 2.
                LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:APOAPSIS):ORBIT:MAG.
                LOCAL vNew IS SQRT(mu * (2/rAp - 1/tSMA)).
                LOCAL dv IS vNew - vNow.
                LOCAL nd IS NODE(TIME:SECONDS + ETA:APOAPSIS, 0, 0, dv).
                ADD nd.
                mLog("Set Pe: dV=" + ROUND(dv,1) + " m/s at Ap").
                WAIT 2.
                SET success TO executeManeuver().
                IF NOT success {
                    SET retries TO retries + 1.
                    mLog("Set Pe missed (attempt " + retries + ") — waiting 10s.").
                    IF retries >= MAX_RETRIES {
                        mLogError("Set Pe failed after " + retries + " attempts — halting.").
                        nextPhase(xferSeq).
                        RETURN.
                    }
                    WAIT 10.
                }
            }
        } ELSE {
            mLog("Pe already within tolerance.").
        }
    }

    orbitSummary().
    nextPhase(xferSeq).
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

LOCAL FUNCTION _impactThreat {
    LOCAL myBody IS SHIP:ORBIT:BODY.
    LOCAL pe   IS SHIP:PERIAPSIS.

    IF myBody:ATM:EXISTS {
        RETURN pe < myBody:ATM:HEIGHT + 1000.
    }

    RETURN pe < 5000.
}
