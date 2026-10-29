// Restore the Kerbin entry Pe at the approaching apoapsis; altitudes in metres.
// RUNPATH("0:/cmd/reentrype.ks",53000).
// Run outside atmosphere on the outbound leg. Existing nodes are preserved.
@LAZYGLOBAL OFF.
PARAMETER targetPe IS 53000.

LOCAL FUNCTION _cmdReentrype {
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("reentry_pe").
    IF NOT (targetPe >= 52000 AND targetPe <= 54000) {
        PRINT "Target must be within the Kerbin 52000-54000m entry corridor.". RETURN.
    }
    IF SHIP:BODY:NAME <> "Kerbin" OR NOT SHIP:BODY:ATM:EXISTS
            OR NOT (SHIP:ALTITUDE > SHIP:BODY:ATM:HEIGHT
                AND SHIP:ORBIT:ECCENTRICITY < 1 AND SHIP:PERIAPSIS > 0
                AND SHIP:APOAPSIS > SHIP:BODY:ATM:HEIGHT
                AND VDOT(SHIP:POSITION-SHIP:BODY:POSITION,SHIP:VELOCITY:ORBIT) > 0
                AND ETA:APOAPSIS > 30) {
        PRINT "Requires an outbound, bound Kerbin orbit outside atmosphere, before apoapsis.". RETURN.
    }
    IF HASNODE OR maneuverBurnInterrupted() {
        PRINT "Existing/interrupted maneuver retained. Inspect it before requesting a new correction.". RETURN.
    }
    IF ABS(SHIP:PERIAPSIS-targetPe) <= 250 {
        PRINT "Pe is already within 250m of target; no correction needed.". RETURN.
    }
    LOCAL repair IS restoreEntryPe(targetPe,52000,54000).
    IF NOT repair["OK"] {
        PRINT "Pe correction failed: " + repair["REASON"] + ". Inspect the log and any remaining node.". RETURN.
    }
    PRINT "Pe repair result: " + repair["REASON"] + ". Reboot to resume the existing aerobrake mission.".
}

_cmdReentrype().
