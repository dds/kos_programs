// Inspect limits; explicit percentage repairs legacy unsaved burn limiting.
// RUNPATH("0:/cmd/enginelimits.ks").  // status
// RUNPATH("0:/cmd/enginelimits.ks",100). // all nonzero-limit engines
@LAZYGLOBAL OFF.
PARAMETER limitPercent IS -1.

LOCAL FUNCTION _cmdEngineLimits {
    RUNPATH("1:/lib/boot_lib"). bootPreamble().
    IF NOT limitPercent:ISTYPE("Scalar") OR NOT (limitPercent = -1 OR (limitPercent > 0 AND limitPercent <= 100)) {
        PRINT "Use no argument for status, or a percentage above 0 through 100.". RETURN.
    }
    IF limitPercent >= 0 {
        IF ABORT OR WARP <> 0 OR SHIP <> KUNIVERSE:ACTIVEVESSEL
                OR stateGet("burn_started","false") = "true"
                OR NOT (SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
                    AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
            PRINT "Requires stopped, unflown setup at 1x, active vessel, Abort clear and all thrust/throttle zero.". RETURN.
        }
        FOR eng IN SHIP:ENGINES {
            IF eng:THRUSTLIMIT > 0 { SET eng:THRUSTLIMIT TO limitPercent. }
        }
        // Once per explicit hardware change; never poll FORCECALC in a loop.
        SHIP:DELTAV:FORCECALC().
        PRINT "Nonzero engine limits set to "+limitPercent+"%; zero limits retained. Stock dV is recalculating.".
    }
    FOR eng IN SHIP:ENGINES {
        PRINT eng:NAME+" uid="+eng:UID+" limit="+eng:THRUSTLIMIT+"% ignition="+eng:IGNITION.
    }
    PRINT "No engine activation, staging, throttle or mission change.".
}

_cmdEngineLimits().
