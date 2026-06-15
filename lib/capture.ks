// ============================================================
// capture.ks  —  Coast + capture phases  (0:/lib/capture.ks)
//
// phaseCoast   — coast to target SOI
// phaseCapture — capture into elliptical orbit at target
// phaseFlyby   — wait through target periapsis without capture
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
        LOCAL captureAlt IS 35000.
        // IF CFG:HASKEY("TARGET_PE") { SET .
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

GLOBAL FUNCTION phaseFlyby {
    LOCAL target IS missionTargetBody().
    WAIT 2.
    IF SHIP:BODY:NAME <> target:NAME {
        mLog("Flyby waiting for " + target:NAME + " SOI.").
        waitForSOI(target).
    }

    SET SAS TO TRUE.
    UNLOCK STEERING.
    trySolarOrient().

    LOCAL postPeHold IS 3600.
    LOCAL exitSoi IS 0.
    IF CFG:HASKEY("FLYBY_POST_PE_HOLD") { SET postPeHold TO CFG["FLYBY_POST_PE_HOLD"]. }
    IF CFG:HASKEY("FLYBY_EXIT_SOI") { SET exitSoi TO CFG["FLYBY_EXIT_SOI"]. }

    LOCAL peEta IS MAX(0, ETA:PERIAPSIS).
    LOCAL peUt IS TIME:SECONDS + peEta.
    IF peEta > 60 {
        kacEnsureAlarm("Flyby Pe: " + target:NAME, peUt,
            "Auto-created by phaseFlyby").
    }

    mLogWarn("STATS flyby setup target=" + target:NAME
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
        + " etaPe=" + ROUND(peEta,0)
        + " holdS=" + ROUND(postPeHold,0)
        + " exitSoi=" + exitSoi).

    LOCAL solarRef IS -1.
    UNTIL TIME:SECONDS >= peUt + postPeHold {
        SET solarRef TO trySolarHoldTick(solarRef).
        WAIT MIN(60, MAX(1, peUt + postPeHold - TIME:SECONDS)).
    }

    orbitSummary().

    IF exitSoi > 0 AND SHIP:BODY:NAME = target:NAME {
        mLog("Flyby complete; waiting to exit " + target:NAME + " SOI.").
        IF SHIP:ORBIT:HASNEXTPATCH AND SHIP:ORBIT:NEXTPATCHETA > 60 {
            kacEnsureAlarm("Exit SOI: " + target:NAME,
                TIME:SECONDS + SHIP:ORBIT:NEXTPATCHETA,
                "Auto-created by phaseFlyby").
        }
        UNTIL SHIP:BODY:NAME <> target:NAME {
            SET solarRef TO trySolarHoldTick(solarRef).
            WAIT 60.
        }
        mLog("Exited " + target:NAME + " SOI; current body=" + SHIP:BODY:NAME + ".").
    }

    mLogWarn("STATS flyby result target=" + target:NAME
        + " body=" + SHIP:BODY:NAME
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).
    nextPhase(xferSeq).
}
