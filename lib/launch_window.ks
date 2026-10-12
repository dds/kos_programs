// ============================================================
// launch_window.ks — Shared plane timing (0:/lib/launch_window.ks)
// Only geometry and final liftoff timing; PRELAUNCH owns planning/UI.
// ============================================================

@LAZYGLOBAL OFF.

// Seconds before the geometric plane crossing to lift off. Calibrate
// per vehicle from PARK telemetry; never include reboot/loading time.
GLOBAL PRELAUNCH_PLANE_LEAD IS 0.
GLOBAL LAUNCH_PLANE_LEAD IS -1.
GLOBAL LAUNCH_WINDOW_TOLERANCE IS 2.

LOCAL FUNCTION _windowNorm360 {
    PARAMETER angle.
    RETURN MOD(MOD(angle, 360) + 360, 360).
}

GLOBAL FUNCTION launchPlaneReachable {
    PARAMETER latitude_, inclination_.
    RETURN ABS(latitude_) <= MIN(inclination_, 180 - inclination_)
        AND ABS(latitude_) < 90.
}

GLOBAL FUNCTION launchPlaneEta {
    PARAMETER ascendingNode, targetLan, targetInc.
    IF NOT launchPlaneReachable(SHIP:LATITUDE, targetInc) { RETURN -1. }
    // Equatorial planes have no unique crossing/LAN.
    IF targetInc <= 0 OR targetInc >= 180 { RETURN 0. }
    LOCAL relLng IS 0.
    IF ABS(targetInc - 90) > 0.001 {
        LOCAL ratio IS TAN(SHIP:LATITUDE) / TAN(targetInc).
        SET relLng TO ARCSIN(MAX(-1, MIN(1, ratio))).
    }
    IF NOT ascendingNode { SET relLng TO 180 - relLng. }
    LOCAL nodeAngle IS _windowNorm360(targetLan + relLng
        - SHIP:BODY:ROTATIONANGLE - SHIP:LONGITUDE).
    RETURN nodeAngle / 360 * SHIP:BODY:ROTATIONPERIOD.
}

GLOBAL FUNCTION launchPlaneWindow {
    PARAMETER targetLan, targetInc, leadTime, minimumWait IS 0.
    IF NOT launchPlaneReachable(SHIP:LATITUDE, targetInc) { RETURN 0. }
    LOCAL best IS 0.
    LOCAL bestWait IS -1.
    LOCAL epoch IS TIME:SECONDS.
    FOR ascendingNode IN LIST(TRUE, FALSE) {
        LOCAL waitTime IS launchPlaneEta(ascendingNode, targetLan, targetInc) - leadTime.
        UNTIL waitTime >= minimumWait {
            SET waitTime TO waitTime + SHIP:BODY:ROTATIONPERIOD.
        }
        IF bestWait < 0 OR waitTime < bestWait {
            SET bestWait TO waitTime.
            SET best TO LEXICON("wait", waitTime, "ut", epoch + waitTime,
                "inc", (CHOOSE targetInc IF ascendingNode ELSE -targetInc),
                "node", (CHOOSE "AN" IF ascendingNode ELSE "DN")).
        }
    }
    RETURN best.
}

GLOBAL FUNCTION launchPlaneLead {
    IF LAUNCH_PLANE_LEAD >= 0 { RETURN LAUNCH_PLANE_LEAD. }
    RETURN MAX(0, PRELAUNCH_PLANE_LEAD).
}

// Called after the LAUNCH band has loaded and all slow setup is done.
// A saved PLANE window can be recalculated here without loading planners.
// Rendezvous/transfer windows need PRELAUNCH to re-evaluate their geometry.
GLOBAL FUNCTION launchWaitForLiftoff {
    LOCAL plan IS stateGet("launch_window", 0).
    LOCAL timed IS plan <> 0.
    LOCAL launchUt IS TIME:SECONDS + 8.
    IF timed {
        IF plan["body"] <> SHIP:BODY:NAME {
            mLogError("Launch window belongs to another body; replanning.").
            stateRemove("launch_window").
            stateSet("phase", "PRELAUNCH").
            RETURN FALSE.
        }
        SET launchUt TO plan["ut"].
    }
    UNTIL ABORT {
        IF timed AND launchUt < TIME:SECONDS + 8 {
            IF plan["kind"] <> "PLANE" {
                mLogWarn("Launch window missed during setup; returning to PRELAUNCH.").
                stateRemove("launch_window").
                stateSet("phase", "PRELAUNCH").
                RETURN FALSE.
            }
            LOCAL win IS launchPlaneWindow(plan["lan"], plan["inc"], plan["lead"], 15).
            IF win = 0 {
                mLogError("Target plane no longer reachable; holding launch.").
                yieldToPrompt().
                RETURN FALSE.
            }
            SET launchUt TO win["ut"].
            // Replace the lexicon: mutating the cached state in place
            // would make stateSet think nothing changed and skip disk I/O.
            SET plan TO LEXICON("kind", "PLANE", "body", plan["body"],
                "ut", launchUt, "launchInc", win["inc"],
                "lan", plan["lan"], "inc", plan["inc"], "lead", plan["lead"]).
            stateSet("launch_window", plan).
            stateSet("prelaunch_plane_ut", launchUt).
            mLogWarn("Launch setup missed the window; next plane crossing selected.").
        }
        IF timed {
            SET LAUNCH_INCLINATION TO plan["launchInc"].
        }
        LOCAL alarmId IS "".
        IF timed AND launchUt - 30 > TIME:SECONDS {
            SET alarmId TO kacEnsureAlarm("Prelaunch window", launchUt - 30,
                "Ascent loaded; waiting for timed liftoff.").
        }
        IF NOT timed {
            mLog("Launch countdown armed: liftoff in 8s; ABORT to hold.").
            SET launchUt TO TIME:SECONDS + 8.
        }
        LOCAL nextNoticeUt IS 0.
        LOCAL lastSecond IS -1.
        UNTIL TIME:SECONDS >= launchUt OR ABORT {
            LOCAL remaining IS launchUt - TIME:SECONDS.
            LOCAL seconds IS CEILING(remaining).
            // Stay quiet during long warps. KAC stops warp at T-30s;
            // final-hour notices use game time and never catch up in a burst.
            IF remaining <= 3600 AND remaining > 10 AND TIME:SECONDS >= nextNoticeUt {
                mLog("Waiting for launch window: liftoff in "
                    + ROUND(remaining / 60, 1) + "min; ABORT to hold.").
                SET nextNoticeUt TO TIME:SECONDS + 900.
            }
            IF remaining <= 10 AND seconds <> lastSecond {
                HUDTEXT("Liftoff in " + seconds + "s - ABORT to hold", 2, 2, 15, WHITE, FALSE).
                IF seconds <= 3 { GETVOICE(0):PLAY(NOTE(440, 0.1)). }
                SET lastSecond TO seconds.
            }
            IF remaining <= 10 { SET WARP TO 0. }
            WAIT MIN(0.2, MAX(0.001, remaining)).
        }
        SET WARP TO 0.
        IF alarmId <> "" { DELETEALARM(alarmId). }
        IF NOT ABORT AND TIME:SECONDS <= launchUt + MAX(0, LAUNCH_WINDOW_TOLERANCE) {
            RETURN TRUE.
        }
        IF NOT timed { SET launchUt TO TIME:SECONDS + 8. }
        // A warp jump or slow frame can miss the deadline. Re-evaluate
        // before igniting; never convert a timed launch into launch-now.
    }
    mLog("Launch held by operator.").
    yieldToPrompt().
    RETURN FALSE.
}
