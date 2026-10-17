// Shared end-of-burn contract. Call only after the burn owner has stopped
// publishing positive commands. No staging or engine activation here.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION thrustCutoff {
    PARAMETER releaseLock IS TRUE.
    PARAMETER verifyTime IS 0.25.
    LOCAL started IS TIME:SECONDS.
    LOCAL forced IS FALSE.
    LOCK THROTTLE TO 0.
    SET SHIP:CONTROL:MAINTHROTTLE TO 0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    WAIT 0.02.
    UNTIL SHIP:THRUST <= 0.001 OR TIME:SECONDS - started >= MAX(1, verifyTime + 0.5) {
        IF NOT forced AND TIME:SECONDS - started >= MAX(0.02, verifyTime) {
            SET forced TO TRUE.
            FOR eng IN SHIP:ENGINES {
                IF eng:IGNITION AND eng:THRUST > 0.001
                        AND NOT eng:THROTTLELOCK AND eng:ALLOWSHUTDOWN {
                    eng:SHUTDOWN.
                }
            }
        }
        SET SHIP:CONTROL:MAINTHROTTLE TO 0.
        SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
        WAIT 0.02.
    }
    IF releaseLock AND SHIP:THRUST <= 0.001 {
        UNLOCK THROTTLE.
        // Unlock can expose a pilot setting or another controller. Check
        // a further physics step before declaring the handoff complete.
        SET SHIP:CONTROL:MAINTHROTTLE TO 0.
        SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
        WAIT 0.02.
        IF NOT (SHIP:THRUST <= 0.001) OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0
                OR SHIP:CONTROL:MAINTHROTTLE > 0 {
            LOCK THROTTLE TO 0.
            SET SHIP:CONTROL:MAINTHROTTLE TO 0.
            SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
            SET forced TO TRUE.
            FOR eng IN SHIP:ENGINES {
                IF eng:IGNITION AND eng:THRUST > 0.001
                        AND NOT eng:THROTTLELOCK AND eng:ALLOWSHUTDOWN {
                    eng:SHUTDOWN.
                }
            }
            WAIT 0.02.
        }
    }
    LOCAL stopped IS SHIP:THRUST <= 0.001 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0
        AND SHIP:CONTROL:MAINTHROTTLE <= 0.
    // A bad thrust sample must report a failed cutoff, not crash JSON
    // serialization before the hold can be requested.
    LOCAL recordedThrust IS SHIP:THRUST.
    IF NOT (ABS(recordedThrust) < 1e30) { SET recordedThrust TO "invalid". }
    stateSet("last_thrust_cutoff", LEX("ut", TIME:SECONDS,
        "phase", stateGet("phase", ""), "forced", forced, "stopped", stopped,
        "thrust", recordedThrust, "rawThrottle", SHIP:CONTROL:MAINTHROTTLE,
        "pilotThrottle", SHIP:CONTROL:PILOTMAINTHROTTLE)).
    IF forced OR NOT stopped {
        // A forced shutdown is a failed burn even if physical thrust stops.
        // The phase machine must not treat the planned burn as successful.
        mLogError("STATS thrust-cutoff fault forced=" + forced
            + " stopped=" + stopped + " thrust=" + SHIP:THRUST
            + " rawThrottle=" + SHIP:CONTROL:MAINTHROTTLE
            + " pilotThrottle=" + SHIP:CONTROL:PILOTMAINTHROTTLE).
        yieldToPrompt().
    }
    RETURN LEX("forced", forced, "stopped", stopped).
}

GLOBAL FUNCTION thrustCutoffOk {
    PARAMETER releaseLock IS TRUE.
    LOCAL check IS thrustCutoff(releaseLock).
    RETURN check["stopped"] AND NOT check["forced"].
}
