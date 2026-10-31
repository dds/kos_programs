// ============================================================
// capture.ks  —  Coast + capture phases  (0:/lib/capture.ks)
//
// phaseCoast   — coast to target SOI
// phaseCapture — capture into elliptical orbit at target
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL TARGET_AP IS -1.
GLOBAL CAPTURE_RESERVE_DV IS -1.
GLOBAL CAPTURE_MIN_PE IS -1.
GLOBAL CAPTURE_MAX_PE IS -1.
GLOBAL CAPTURE_ACCEPT_BOUND IS 0.
// Opt-in only: an unaffordable, unflown airless capture may continue into
// an immediately following FLYBY phase. No failed/interrupted burn waiver.
GLOBAL CAPTURE_OPTIONAL_FLYBY IS 0.

LOCAL MAX_RETRIES IS 5.

LOCAL FUNCTION _transferArrivalUt {
    PARAMETER targetBody.

    IF SHIP:BODY = targetBody { RETURN TIME:SECONDS. }
    LOCAL arrivalUt IS 0.
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
    // Prefer the live unburned patch above to an old departure estimate.
    SET arrivalUt TO stateGetNum("xing_arrival_ut", 0).
    IF arrivalUt > TIME:SECONDS AND stateGet("xing_arrival_target", "") = targetBody:NAME {
        RETURN arrivalUt.
    }
    RETURN 0.
}

GLOBAL FUNCTION phaseCoast {
    LOCAL target IS missionTargetBody().
    enterSolarCoast("COAST").
    mLog("Coasting to " + target:NAME + " SOI.").
    waitForSOI(target).
    orbitSummary().
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCoast1Half {
    LOCAL target IS missionTargetBody().
    midcourseClearReviewAlarm().
    LOCAL tArrival IS _transferArrivalUt(target).
    IF tArrival <= TIME:SECONDS {
        mLogWarn("COAST_1HALF: no future arrival timestamp; continuing to refinement.").
        nextPhase(xferSeq).
        RETURN.
    }

    ensureSoiAlarm(target,tArrival,"Auto-created before midcourse coast.").
    LOCAL tStart IS TIME:SECONDS.
    LOCAL tMidpoint IS midcourseRefineUt(tStart, tArrival).
    IF tMidpoint <= TIME:SECONDS {
        mLog("COAST_1HALF: refinement checkpoint due; handing forward now.").
        nextPhase(xferSeq).
        RETURN.
    }

    mLog("Coasting to mid-course refinement at T+"
        + ROUND(tMidpoint - TIME:SECONDS, 0) + "s.").
    LOCAL alarmId IS kacEnsureAlarm("Midcourse refine: " + target:NAME,
        tMidpoint,
        "Auto-created by COAST_1HALF").
    mLog("STATS midcourse wake refineUt=" + tMidpoint + " arrivalUt=" + tArrival
        + " alarm=" + alarmId + " automaticResume=True").
    LOCAL solarRef IS enterSolarCoast("COAST_1HALF", TRUE, TRUE, tMidpoint).
    waitUntilOrSOI(target, tMidpoint, 10, alarmId, solarRef).
    IF alarmId <> "" { DELETEALARM(alarmId). }
    IF ABORT { RETURN. }

    IF SHIP:BODY = target {
        mLog("COAST_1HALF: entered " + target:NAME
            + " SOI before midpoint; handing forward.").
    }
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCoast2Half {
    midcourseClearReviewAlarm().
    LOCAL target IS missionTargetBody().

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

    LOCAL soiBuffer IS SOI_BUFFER_TIME.
    LOCAL soiAlarmId IS ensureSoiAlarm(target, tArrival,
        "Auto-created by COAST_2HALF").
    LOCAL coastUntil IS MAX(TIME:SECONDS, tArrival - soiBuffer).
    mLog("Coasting toward " + target:NAME + " SOI boundary; buffer="
        + ROUND(soiBuffer, 0) + "s.").
    LOCAL solarRef IS enterSolarCoast("COAST_2HALF", FALSE, FALSE).
    waitUntilOrSOI(target, coastUntil, 10, soiAlarmId, solarRef, FALSE).
    IF ABORT { RETURN. }

    IF SHIP:BODY = target AND soiAlarmId <> "" {
        DELETEALARM(soiAlarmId).
        FOR key IN LIST("soi_alarm_id", "soi_alarm_target", "soi_alarm_ut") {
            stateRemove(key).
        }
    }
    IF SHIP:BODY <> target {
        mLog("COAST_2HALF: reached SOI buffer; waiting for "
            + target:NAME + " SOI.").
        waitForSOI(target).
    }

    orbitSummary().
    nextPhase(xferSeq).
}

LOCAL FUNCTION _captureContinueFlyby {
    PARAMETER target.
    IF CAPTURE_OPTIONAL_FLYBY <= 0 OR ABORT OR WARP <> 0 OR HASNODE
            OR maneuverBurnInterrupted() OR SHIP <> KUNIVERSE:ACTIVEVESSEL
            OR SHIP:BODY <> target OR target:ATM:EXISTS
            OR NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
                AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0)
            OR NOT (SHIP:ORBIT:ECCENTRICITY >= 1 AND SHIP:ORBIT:ECCENTRICITY < 1e30
                AND SHIP:PERIAPSIS >= MAX(1,CAPTURE_MIN_PE)
                AND CAPTURE_MAX_PE >= SHIP:PERIAPSIS
                AND ETA:PERIAPSIS > 0 AND ETA:PERIAPSIS < 1e30) { RETURN FALSE. }
    IF SHIP:ORBIT:HASNEXTPATCH {
        IF NOT (ETA:PERIAPSIS < SHIP:ORBIT:NEXTPATCHETA) { RETURN FALSE. }
    }
    LOCAL i IS 0.
    UNTIL i+1 >= xferSeq:LENGTH {
        IF xferSeq[i] = stateGet("phase","") AND xferSeq[i+1] = "FLYBY" {
            mLogWarn("STATS capture decision=flyby reason=capture-budget noBurn=True").
            PRINT "Capture exceeds the fuel budget; continuing the planned science flyby.".
            nextPhase(xferSeq).
            RETURN TRUE.
        }
        SET i TO i+1.
    }
    RETURN FALSE.
}

GLOBAL FUNCTION phaseCapture {
    midcourseClearReviewAlarm().
    LOCAL target IS missionTargetBody().
    IF SHIP:BODY <> target {
        mLogError("CAPTURE: vessel is not inside " + target:NAME + " SOI.").
        RETURN.
    }
    IF HASNODE OR maneuverBurnInterrupted() {
        mLogError("CAPTURE: existing/interrupted maneuver retained; inspect or explicitly resume it before replanning.").
        yieldToPrompt(). RETURN.
    }
    WAIT 2.
    mLog("Planning capture into elliptical orbit at " + target:NAME + ".").
    mLog("STATS capture phase setup target=" + target:NAME
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).

    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    UNTIL success {
        // Recheck after the entry/retry waits: a new node, Abort or SOI
        // transition must not authorize another planner/executor call.
        IF ABORT OR SHIP:BODY <> target OR HASNODE OR maneuverBurnInterrupted()
                OR NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
                    AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
            mLogError("CAPTURE: context changed; existing maneuver retained, no replacement burn.").
            yieldToPrompt(). RETURN.
        }
        IF CAPTURE_ACCEPT_BOUND <> 0 AND SHIP:ORBIT:ECCENTRICITY < 1
                AND SHIP:PERIAPSIS > MAX(0, CAPTURE_MIN_PE)
                AND SHIP:APOAPSIS < target:SOIRADIUS {
            mLog("STATS capture result=already-bound; preserving recovered orbit").
            SET success TO TRUE. BREAK.
        }
        IF (CAPTURE_MIN_PE >= 0 AND SHIP:PERIAPSIS < CAPTURE_MIN_PE)
                OR (CAPTURE_MAX_PE >= 0 AND SHIP:PERIAPSIS > CAPTURE_MAX_PE) {
            mLogWarn("STATS capture decision=hold reason=periapsis-outside-recovery-corridor").
            yieldToPrompt(). RETURN.
        }

        // 1. Resolve target altitude from config
        LOCAL captureAlt IS MAX(35000, SHIP:PERIAPSIS).
        IF TARGET_AP >= 0 { SET captureAlt TO TARGET_AP. }

        // 2. Delegate math to your existing library function
        LOCAL nd IS planCapture(target, captureAlt).
        IF nd = 0 {
            mLogError("CAPTURE: no safe capture node; holding phase.").
            RETURN.
        }

        IF NOT (nd:DELTAV:MAG >= 0 AND nd:DELTAV:MAG < 1e30
                AND SHIP:DELTAV:VACUUM >= 0 AND SHIP:DELTAV:VACUUM < 1e30) {
            REMOVE nd.
            mLogError("CAPTURE: native node exceeds finite available fuel; no burn authorized.").
            yieldToPrompt(). RETURN.
        }
        IF nd:DELTAV:MAG > SHIP:DELTAV:VACUUM {
            REMOVE nd.
            IF _captureContinueFlyby(target) { RETURN. }
            mLogError("CAPTURE: native node exceeds available fuel; no burn authorized.").
            yieldToPrompt(). RETURN.
        }

        IF CAPTURE_RESERVE_DV >= 0 {
            mLog("STATS capture budget dv=" + ROUND(nd:DELTAV:MAG, 2)
                + " remainingDv=" + ROUND(SHIP:DELTAV:VACUUM, 2)
                + " reserveDv=" + CAPTURE_RESERVE_DV).
            IF nd:DELTAV:MAG + CAPTURE_RESERVE_DV > SHIP:DELTAV:VACUUM {
                REMOVE nd.
                IF _captureContinueFlyby(target) { RETURN. }
                mLogWarn("STATS capture decision=hold reason=capture-budget").
                yieldToPrompt(). RETURN.
            }
        }

        // 3. Execute with standard retry logic
        SET success TO executeManeuver().
        IF success AND (SHIP:ORBIT:ECCENTRICITY >= 1 OR SHIP:PERIAPSIS <= 0) {
            mLogError("CAPTURE: burn ended without a bound orbit above the surface; holding phase.").
            RETURN.
        }

        IF NOT success {
            IF maneuverBurnInterrupted() OR HASNODE {
                mLogError("CAPTURE: failed maneuver retained; explicit recovery required, no replacement burn.").
                yieldToPrompt(). RETURN.
            }
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
    mLog("STATS capture phase result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    mLog("Capture complete. Moving to finalization phase.").
    nextPhase(xferSeq).
}
