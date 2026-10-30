// ============================================================
// capture.ks  —  Coast + capture phases  (0:/lib/capture.ks)
//
// phaseCoast   — coast to target SOI
// phaseCapture — capture into elliptical orbit at target
// phaseFlyby   — wait through target periapsis without capture
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL FLYBY_POST_PE_HOLD IS 0.
GLOBAL FLYBY_EXIT_SOI IS 1.
// After a flyby, the return-side phases work relative to the body we're
// returning to. Retarget to FLYBY_NEXT_TARGET, or (unset) the flyby
// body's parent (e.g. Mun -> Kerbin).
GLOBAL FLYBY_NEXT_TARGET IS "".
GLOBAL TARGET_AP IS -1.
GLOBAL CAPTURE_RESERVE_DV IS -1.
GLOBAL CAPTURE_MIN_PE IS -1.
GLOBAL CAPTURE_MAX_PE IS -1.
GLOBAL CAPTURE_ACCEPT_BOUND IS 0.

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
                AND SHIP:DELTAV:VACUUM >= 0 AND SHIP:DELTAV:VACUUM < 1e30
                AND nd:DELTAV:MAG <= SHIP:DELTAV:VACUUM) {
            REMOVE nd.
            mLogError("CAPTURE: native node exceeds finite available fuel; no burn authorized.").
            yieldToPrompt(). RETURN.
        }

        IF CAPTURE_RESERVE_DV >= 0 {
            mLog("STATS capture budget dv=" + ROUND(nd:DELTAV:MAG, 2)
                + " remainingDv=" + ROUND(SHIP:DELTAV:VACUUM, 2)
                + " reserveDv=" + CAPTURE_RESERVE_DV).
            IF nd:DELTAV:MAG + CAPTURE_RESERVE_DV > SHIP:DELTAV:VACUUM {
                REMOVE nd.
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

GLOBAL FUNCTION phaseFlyby {
    LOCAL target IS missionTargetBody().
    WAIT 2.
    IF SHIP:BODY:NAME <> target:NAME {
        enterSolarCoast("FLYBY").
        mLog("Flyby waiting for " + target:NAME + " SOI.").
        waitForSOI(target).
    }

    enterSolarCoast("FLYBY").

    LOCAL postPeHold IS 3600.
    LOCAL exitSoi IS 0.
    SET postPeHold TO FLYBY_POST_PE_HOLD.
    SET exitSoi TO FLYBY_EXIT_SOI.

    LOCAL peEta IS MAX(0, ETA:PERIAPSIS).
    LOCAL peUt IS TIME:SECONDS + peEta.
    IF peEta > 60 {
        kacEnsureAlarm("Flyby Pe: " + target:NAME, peUt,
            "Auto-created by phaseFlyby").
    }

    mLog("STATS flyby setup target=" + target:NAME
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

    mLog("STATS flyby result target=" + target:NAME
        + " body=" + SHIP:BODY:NAME
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).

    // Retarget for the return: the moon is behind us, so ESCAPE/MCC/
    // AEROBRAKE should work toward the body we're returning to — else
    // they keep trying to re-acquire the moon. FLYBY_NEXT_TARGET if set,
    // else the flyby body's parent. getTarget() reads state "target"
    // first, so this sticks across the band-change reboot.
    LOCAL nextTgt IS FLYBY_NEXT_TARGET.
    IF nextTgt = "" AND target:HASBODY { SET nextTgt TO target:BODY:NAME. }
    IF nextTgt <> "" {
        stateSet("target", nextTgt).
        mLog("Flyby: retargeting to " + nextTgt + " for the return leg.").
    }
    nextPhase(xferSeq).
}
