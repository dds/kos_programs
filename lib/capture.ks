// ============================================================
// capture.ks  —  Coast + capture phases  (0:/lib/capture.ks)
//
// phaseCoast   — coast to target SOI
// phaseCapture — capture into elliptical orbit at target
// ============================================================

LOCAL MAX_RETRIES IS 5.

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
    mLog("Planning capture into elliptical orbit at " + target:NAME + ".").
    mLogWarn("STATS capture phase setup target=" + target:NAME
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).

    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }

        // 1. Resolve target altitude from config
        LOCAL captureAlt IS CFG["TARGET_PE"].
        IF CFG:HASKEY("TARGET_AP") { SET captureAlt TO CFG["TARGET_AP"]. }

        // 2. Delegate math to your existing library function
        planCapture(target, captureAlt).

        // 3. Execute with standard retry logic
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
    mLogWarn("STATS capture phase result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    mLog("Capture complete. Moving to finalization phase.").
    nextPhase(xferSeq).
}
