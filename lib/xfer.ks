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
        planCapture(target, CFG["RELAY_ALT"]).
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
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCirc {
    IF _impactThreat() {
        mLog("Impact threat — raising Pe immediately.").
        LOCAL success IS FALSE.
        LOCAL retries IS 0.
        UNTIL success {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            planRaisePeNow(CFG["RELAY_ALT"]).
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
    LOCAL targetAlt IS CFG["RELAY_ALT"].
    IF SHIP:APOAPSIS > targetAlt * 0.99 {
        mLog("Already at target altitude.").
        nextPhase(xferSeq).
        RETURN.
    }
    mLog("Raising to " + ROUND(targetAlt/1000,0) + "km.").
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL mu    IS SHIP:ORBIT:BODY:MU.
        LOCAL rNow  IS SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS.
        LOCAL rTarget IS SHIP:ORBIT:BODY:RADIUS + targetAlt.
        LOCAL tSMA  IS (rNow + rTarget) / 2.
        LOCAL vNow  IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:APOAPSIS):ORBIT:MAG.
        LOCAL vNew  IS SQRT(mu * (2/rNow - 1/tSMA)).
        LOCAL dv    IS vNew - vNow.
        LOCAL nd    IS NODE(TIME:SECONDS + ETA:APOAPSIS, 0, 0, dv).
        ADD nd.
        mLog("Raise Ap: dV=" + ROUND(dv,1) + " m/s").
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
    SET success TO FALSE.
    SET retries TO 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planCircularize().
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Circ at target alt missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError("Circ at target alt failed after " + retries + " attempts — halting.").
                nextPhase(xferSeq).
                RETURN.
            }
            WAIT 10.
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
