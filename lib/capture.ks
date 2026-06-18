// ============================================================
// capture.ks  —  Coast + capture phases  (0:/lib/capture.ks)
//
// phaseCoast   — coast to target SOI
// phaseCapture — capture into elliptical orbit at target
// phaseFlyby   — wait through target periapsis without capture
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL MIDCOURSE_REFINE_FRACTION IS 0.5.
GLOBAL MIDCOURSE_REFINE_MIN_LEAD IS 600.
GLOBAL MIDCOURSE_REFINE_MARGIN IS 60.
GLOBAL SOI_BUFFER_TIME IS 120.
GLOBAL BPLANE_LEAD IS 300.
GLOBAL FLYBY_POST_PE_HOLD IS 0.
GLOBAL FLYBY_EXIT_SOI IS 1.
GLOBAL TARGET_AP IS -1.

LOCAL MAX_RETRIES IS 5.
LOCAL SOI_BUFFER_TIME_DEFAULT IS 300.
LOCAL MIDCOURSE_REFINE_FRACTION_DEFAULT IS 0.5.
LOCAL MIDCOURSE_REFINE_MIN_LEAD_DEFAULT IS 300.
LOCAL MIDCOURSE_REFINE_MARGIN_DEFAULT IS 60.

LOCAL FUNCTION _enterSolarCoast {
    PARAMETER label IS "COAST".
    SET SAS TO TRUE.
    UNLOCK STEERING.
    IF (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING"
            OR SHIP:STATUS = "SUB_ORBITAL")
            AND DEFINED BOOT_LIB_RAN
            AND BOOT_LIB_RAN:CONTAINS("solar") {
        orientForSolar(TRUE, TRUE, TRUE).
    } ELSE {
        trySolarOrient().
    }
    tryCommandCoreHibernate(TRUE).
    LOCAL solarRef IS trySolarHoldTick(-1).
    mLog(label + ": solar coast attitude armed.").
    IF NOT coastHealthCheck(label + " entry") {
        mLogWarn(label + ": entry health check failed; remaining at 1x.").
    }
    RETURN solarRef.
}

LOCAL FUNCTION _solarCoastCanWarp {
    PARAMETER refFlow.
    PARAMETER label IS "COAST".
    IF DEFINED BOOT_LIB_RAN
            AND BOOT_LIB_RAN:CONTAINS("solar")
            AND shipHasSolarPanels()
            AND refFlow <= 0 {
        mLogWarn(label + ": auto-warp skipped; no solar flow after orient.").
        RETURN FALSE.
    }
    RETURN TRUE.
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
    PARAMETER alarmId IS "".
    PARAMETER solarRef IS -1.

    SET solarRef TO trySolarHoldTick(solarRef).
    LOCAL waitSeconds IS MAX(0, targetUt - TIME:SECONDS).
    IF COAST_AUTO_WARP > 0
            AND waitSeconds >= COAST_AUTO_WARP_MIN
            AND idealCoastWarpRate(waitSeconds) > 0
            AND _solarCoastCanWarp(solarRef, "SOI coast")
            AND coastHealthCheck("SOI coast pre-warp") {
        SET waitSeconds TO MAX(0, targetUt - TIME:SECONDS).
        IF COAST_HEALTH_CHECK > 0
                AND waitSeconds >= COAST_AUTO_WARP_MIN * 2 {
            LOCAL midUt IS TIME:SECONDS + waitSeconds / 2.
            mLog("SOI coast: midpoint health check in T+"
                + ROUND(midUt - TIME:SECONDS, 0) + "s.").
            IF coastAutoWarp(midUt, "SOI coast midpoint", alarmId) {
                UNTIL TIME:SECONDS >= midUt OR SHIP:BODY = targetBody {
                    SET solarRef TO trySolarHoldTick(solarRef).
                    WAIT MIN(pollInterval, MAX(1, midUt - TIME:SECONDS)).
                }
                IF WARP > 0 {
                    SET WARP TO 0.
                    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
                    WAIT 1.
                }
                SET solarRef TO trySolarHoldTick(solarRef).
                IF SHIP:BODY <> targetBody
                        AND _solarCoastCanWarp(solarRef, "SOI coast")
                        AND coastHealthCheck("SOI coast midpoint") {
                    coastAutoWarp(targetUt, "SOI coast", alarmId).
                }
            }
        } ELSE {
            coastAutoWarp(targetUt, "SOI coast", alarmId).
        }
    }
    UNTIL TIME:SECONDS >= targetUt OR SHIP:BODY = targetBody {
        SET solarRef TO trySolarHoldTick(solarRef).
        WAIT MIN(pollInterval, MAX(1, targetUt - TIME:SECONDS)).
    }
}

LOCAL FUNCTION _timeMidcourseUt {
    PARAMETER tStart.
    PARAMETER tArrival.

    LOCAL frac IS MIDCOURSE_REFINE_FRACTION.
    SET frac TO MAX(0.05, MIN(0.95, frac)).

    LOCAL rawUt IS tStart + frac * (tArrival - tStart).
    LOCAL minLead IS MIDCOURSE_REFINE_MIN_LEAD.
    LOCAL margin IS MIDCOURSE_REFINE_MARGIN.
    LOCAL soiBuffer IS SOI_BUFFER_TIME.
    LOCAL bplaneLead IS BPLANE_LEAD.
    LOCAL latestUt IS tArrival - soiBuffer - bplaneLead - margin.
    LOCAL refineUt IS rawUt.

    IF latestUt <= tStart {
        mLogWarn("COAST_1HALF: transfer too short for guarded midpoint; "
            + "refining now.").
        RETURN tStart.
    }

    IF refineUt < tStart + minLead AND tStart + minLead < latestUt {
        SET refineUt TO tStart + minLead.
    }
    IF refineUt > latestUt {
        SET refineUt TO latestUt.
    }

    stateSet("midcourse_refine_method", "TIME").
    stateSet("midcourse_refine_fraction", frac).
    stateSet("midcourse_refine_arrival_ut", tArrival).
    FOR key IN LIST("midcourse_refine_distance",
            "midcourse_refine_start_distance") {
        stateRemove(key).
    }

    mLog("COAST_1HALF: time midpoint fraction=" + ROUND(frac, 2)
        + " rawT+" + ROUND(rawUt - TIME:SECONDS, 0)
        + "s scheduledT+" + ROUND(refineUt - TIME:SECONDS, 0) + "s.").
    RETURN refineUt.
}

GLOBAL FUNCTION phaseCoast {
    LOCAL target IS missionTargetBody().
    _enterSolarCoast("COAST").
    mLog("Coasting to " + target:NAME + " SOI.").
    waitForSOI(target).
    orbitSummary().
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCoast1Half {
    LOCAL target IS missionTargetBody().
    LOCAL solarRef IS _enterSolarCoast("COAST_1HALF").

    LOCAL tArrival IS _transferArrivalUt(target).
    IF tArrival <= TIME:SECONDS {
        mLogWarn("COAST_1HALF: no future arrival timestamp; continuing to refinement.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL tStart IS TIME:SECONDS.
    LOCAL tMidpoint IS _timeMidcourseUt(tStart, tArrival).
    stateSet("midcourse_refine_ut", tMidpoint).

    mLog("Coasting to mid-course refinement at T+"
        + ROUND(tMidpoint - TIME:SECONDS, 0) + "s.").
    LOCAL alarmId IS kacEnsureAlarm("Midcourse refine: " + target:NAME,
        tMidpoint,
        "Auto-created by COAST_1HALF").
    _waitUntilOrSOI(target, tMidpoint, 10, alarmId, solarRef).
    IF alarmId <> "" { DELETEALARM(alarmId). }

    IF SHIP:BODY = target {
        mLog("COAST_1HALF: entered " + target:NAME
            + " SOI before midpoint; handing forward.").
    }
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCoast2Half {
    LOCAL target IS missionTargetBody().
    LOCAL solarRef IS _enterSolarCoast("COAST_2HALF").

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
    _waitUntilOrSOI(target, coastUntil, 10, soiAlarmId, solarRef).

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
        LOCAL captureAlt IS 35000.        SET captureAlt TO TARGET_AP.

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
        _enterSolarCoast("FLYBY").
        mLog("Flyby waiting for " + target:NAME + " SOI.").
        waitForSOI(target).
    }

    _enterSolarCoast("FLYBY").

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
