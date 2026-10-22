// ============================================================
// coast_wait.ks - live solar/clock waits for arrival and orbital retries
// KAC guards warp; these loops resume execution.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION enterSolarCoast {
    PARAMETER label IS "COAST".
    PARAMETER orientOnEntry IS FALSE.
    PARAMETER checkEntryHealth IS TRUE.
    PARAMETER deadlineUt IS 0.
    SET SAS TO TRUE.
    UNLOCK STEERING.
    LOCAL aimed IS FALSE.
    IF orientOnEntry
            AND (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING"
                OR SHIP:STATUS = "SUB_ORBITAL")
            AND PHASES_HAS_SOLAR {
        SET aimed TO orientForSolar(FALSE, TRUE, TRUE, deadlineUt).
    }
    LOCAL solarRef IS -1.
    IF checkEntryHealth {
        SET solarRef TO trySolarHoldTick(-1, deadlineUt).
    } ELSE IF PHASES_HAS_SOLAR AND shipHasSolarPanels() {
        SET solarRef TO MAX(shipSolarFlow(), 0).
    }
    mLog(label + ": solar coast initialAim=" + aimed + " flow=" + ROUND(solarRef,3)).
    IF checkEntryHealth {
        IF NOT coastHealthCheck(label + " entry", deadlineUt) {
            mLogWarn(label + ": entry health check failed; remaining at 1x.").
        } ELSE {
            SET solarRef TO trySolarHoldTick(-1, deadlineUt).
        }
    }
    RETURN solarRef.
}

GLOBAL FUNCTION solarCoastCanWarp {
    PARAMETER refFlow.
    PARAMETER label IS "COAST".
    // No solar flow alone shouldn't pin us at 1x — a short eclipse with a
    // healthy battery is fine to warp through (it recharges on the sunny
    // side). Only hold when there's no flow AND the battery is low.
    IF PHASES_HAS_SOLAR
            AND shipHasSolarPanels()
            AND refFlow <= 0
            AND shipPowerFraction() < SOLAR_HOLD_EC {
        mLogWarn(label + ": auto-warp skipped; no solar flow and battery low ("
            + ROUND(shipPowerFraction() * 100, 0) + "%).").
        RETURN FALSE.
    }
    RETURN TRUE.
}

LOCAL FUNCTION _coastWaitBodyLimit {
    PARAMETER targetBody.
    PARAMETER stayInBody.
    IF stayInBody {
        RETURN SHIP:BODY <> targetBody OR HASNODE OR SHIP:STATUS <> "ORBITING"
            OR NOT (SHIP:PERIAPSIS > 0 AND SHIP:ORBIT:ECCENTRICITY < 1)
            OR SHIP:ORBIT:HASNEXTPATCH.
    }
    RETURN SHIP:BODY = targetBody.
}

GLOBAL FUNCTION waitUntilOrSOI {
    PARAMETER targetBody.
    PARAMETER targetUt.
    PARAMETER pollInterval IS 10.
    PARAMETER alarmId IS "".
    PARAMETER solarRef IS -1.
    PARAMETER checkPreWarpHealth IS TRUE.
    // A landing-window retry waits IN this body, rather than FOR entry.
    PARAMETER stayInBody IS FALSE.

    // Never inherit an unguarded warp from a caller, quickload or manual UI.
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF ABORT OR _coastWaitBodyLimit(targetBody,stayInBody) { RETURN. }

    IF checkPreWarpHealth {
        SET solarRef TO trySolarHoldTick(solarRef, targetUt).
    } ELSE IF PHASES_HAS_SOLAR AND shipHasSolarPanels() AND solarRef < 0 {
        SET solarRef TO MAX(shipSolarFlow(), 0).
    }
    LOCAL waitSeconds IS MAX(0, targetUt - TIME:SECONDS).
    IF NOT ABORT AND alarmId <> "" AND COAST_AUTO_WARP > 0
            AND waitSeconds >= COAST_AUTO_WARP_MIN
            AND idealCoastWarpRate(waitSeconds) > 0
            AND solarCoastCanWarp(solarRef, "SOI coast")
            AND (NOT checkPreWarpHealth
                OR coastHealthCheck("SOI coast pre-warp", targetUt))
            AND NOT ABORT AND NOT _coastWaitBodyLimit(targetBody,stayInBody) {
        SET waitSeconds TO MAX(0, targetUt - TIME:SECONDS).
        IF COAST_HEALTH_CHECK > 0
                AND waitSeconds >= COAST_AUTO_WARP_MIN * 2 {
            LOCAL midUt IS TIME:SECONDS + waitSeconds / 2.
            LOCAL healthAlarmId IS coastEnsureHealthAlarm(
                midUt, "SOI coast health").
            mLog("SOI coast: midpoint health check in T+"
                + ROUND(midUt - TIME:SECONDS, 0) + "s.").
            IF healthAlarmId <> "" AND coastAutoWarp(midUt, "SOI coast midpoint", healthAlarmId) {
                UNTIL TIME:SECONDS >= midUt OR _coastWaitBodyLimit(targetBody,stayInBody) OR ABORT {
                    SET solarRef TO trySolarHoldTick(solarRef, midUt).
                    WAIT MIN(pollInterval, MAX(0, midUt - TIME:SECONDS)).
                }
                IF WARP > 0 {
                    SET WARP TO 0.
                    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
                    WAIT 1.
                }
                IF NOT ABORT AND NOT _coastWaitBodyLimit(targetBody,stayInBody)
                        AND coastHealthCheck("SOI coast midpoint", targetUt) {
                    SET solarRef TO trySolarHoldTick(-1, targetUt).
                    IF NOT ABORT AND NOT _coastWaitBodyLimit(targetBody,stayInBody)
                            AND solarCoastCanWarp(solarRef, "SOI coast") {
                        coastAutoWarp(targetUt, "SOI coast", alarmId).
                    }
                }
            }
            // A declined warp still owns the alarm created above.
            IF healthAlarmId <> "" { DELETEALARM(healthAlarmId). }
        } ELSE {
            coastAutoWarp(targetUt, "SOI coast", alarmId).
        }
    }
    UNTIL TIME:SECONDS >= targetUt OR _coastWaitBodyLimit(targetBody,stayInBody) OR ABORT {
        SET solarRef TO trySolarHoldTick(solarRef, targetUt).
        WAIT MIN(pollInterval, MAX(0, targetUt - TIME:SECONDS)).
    }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
}

