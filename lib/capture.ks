// ============================================================
// capture.ks  —  Coast + capture phases  (0:/lib/capture.ks)
//
// phaseCoast   — coast to target SOI
// phaseCapture — capture into elliptical orbit at target
// phaseFlyby   — wait through target periapsis without capture
// ============================================================

LOCAL MAX_RETRIES IS 5.
LOCAL SOI_BUFFER_TIME_DEFAULT IS 300.

LOCAL FUNCTION _cfgNum {
    PARAMETER key, defaultValue.
    IF DEFINED CFG AND CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _transferArrivalUt {
    PARAMETER targetBody.

    LOCAL arrivalUt IS stateGetNum("xing_arrival_ut", 0).
    LOCAL arrivalTarget IS stateGet("xing_arrival_target", "").
    IF arrivalUt > TIME:SECONDS AND arrivalTarget = targetBody:NAME {
        RETURN arrivalUt.
    }

    IF SHIP:BODY = targetBody { RETURN TIME:SECONDS. }
    LOCAL p IS SHIP:ORBIT.
    UNTIL NOT p:HASNEXTPATCH {
        LOCAL transitionEta IS p:NEXTPATCHETA.
        SET p TO p:NEXTPATCH.
        IF p:BODY = targetBody {
            SET arrivalUt TO TIME:SECONDS + transitionEta.
            stateSet("xing_arrival_ut", arrivalUt).
            stateSet("xing_arrival_target", targetBody:NAME).
            RETURN arrivalUt.
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _waitUntilOrSOI {
    PARAMETER targetBody.
    PARAMETER targetUt.
    PARAMETER pollInterval IS 10.

    LOCAL solarRef IS -1.
    UNTIL TIME:SECONDS >= targetUt OR SHIP:BODY = targetBody {
        SET solarRef TO trySolarHoldTick(solarRef).
        WAIT MIN(pollInterval, MAX(1, targetUt - TIME:SECONDS)).
    }
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

GLOBAL FUNCTION phaseCoast1Half {
    LOCAL target IS missionTargetBody().
    SET SAS TO TRUE.
    UNLOCK STEERING.
    trySolarOrient().

    LOCAL tArrival IS _transferArrivalUt(target).
    IF tArrival <= TIME:SECONDS {
        mLogWarn("COAST_1HALF: no future arrival timestamp; continuing to refinement.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL tStart IS TIME:SECONDS.
    LOCAL tMidpoint IS tStart + 0.5 * (tArrival - tStart).
    stateSet("midcourse_refine_ut", tMidpoint).

    mLog("Coasting to mid-course refinement at T+"
        + ROUND(tMidpoint - TIME:SECONDS, 0) + "s.").
    _waitUntilOrSOI(target, tMidpoint, 10).

    IF SHIP:BODY = target {
        mLog("COAST_1HALF: entered " + target:NAME
            + " SOI before midpoint; handing forward.").
    }
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCoast2Half {
    LOCAL target IS missionTargetBody().
    SET SAS TO TRUE.
    UNLOCK STEERING.
    trySolarOrient().

    IF SHIP:BODY = target {
        mLog("COAST_2HALF: already inside " + target:NAME + " SOI.").
        orbitSummary().
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL tArrival IS _transferArrivalUt(target).
    IF tArrival <= TIME:SECONDS {
        mLog("COAST_2HALF: arrival time is due; waiting for "
            + target:NAME + " SOI.").
        waitForSOI(target).
        orbitSummary().
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL soiBuffer IS _cfgNum("SOI_BUFFER_TIME", SOI_BUFFER_TIME_DEFAULT).
    LOCAL coastUntil IS MAX(TIME:SECONDS, tArrival - soiBuffer).
    mLog("Coasting toward " + target:NAME + " SOI boundary; buffer="
        + ROUND(soiBuffer, 0) + "s.").
    _waitUntilOrSOI(target, coastUntil, 10).

    IF SHIP:BODY <> target {
        mLog("COAST_2HALF: reached SOI buffer; waiting for "
            + target:NAME + " SOI.").
        waitForSOI(target).
    }

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
