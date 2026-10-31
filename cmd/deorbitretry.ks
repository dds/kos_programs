// Discard only the next UNFLOWN landing node; keep target/mission/overrides.
// RUNPATH("0:/cmd/deorbitretry.ks"). Then REBOOT to replan the saved target.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _cmdDeorbitretry {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    LOCAL FUNCTION ready {
        LOCAL phase IS stateGet("phase","").
        RETURN ((phase = "LAND_DEORBIT"
                AND (SHIP:BODY:NAME = "Mun" OR SHIP:BODY:NAME = "Minmus" OR SHIP:BODY:NAME = "Ike"))
                OR (phase = "ATMO_DEORBIT" AND SHIP:BODY:ATM:EXISTS AND SHIP:PERIAPSIS > SHIP:BODY:ATM:HEIGHT))
            AND SHIP:STATUS = "ORBITING" AND SHIP:PERIAPSIS > 0
            AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
            AND NOT SHIP:ORBIT:HASNEXTPATCH
            AND stateGet("deorbit_burn_started","false") <> "true"
            AND NOT (stateGet("burn_pending","false") = "true"
                AND stateGet("burn_started","false") = "true")
            AND NOT ABORT AND SHIP:THRUST <= 0.001
            AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
    }
    IF NOT ready() {
        PRINT "Deorbit retry requires unflown LAND_DEORBIT/ATMO_DEORBIT in stable parking orbit, Abort clear and all thrust/throttle zero. Nothing changed.".
        RETURN.
    }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF NOT ready() {
        PRINT "Vehicle state changed while settling warp; node and mission preserved.".
        RETURN.
    }
    IF HASNODE {
        LOCAL nd IS NEXTNODE.
        // Capture suffixes before REMOVE: a detached node cannot be read.
        LOCAL nodeUt IS nd:TIME.
        LOCAL nodeDv IS nd:DELTAV:MAG.
        REMOVE nd.
        mLog("STATS deorbit retry removed=True nodeUt=" + nodeUt + " dv=" + nodeDv
            + " targetPreserved=True phase=" + stateGet("phase","")).
        IF ADDONS:KAC:AVAILABLE {
            LOCAL alarmName IS kacShipAlarmName("Deorbit burn").
            FOR alarm IN LISTALARMS("All") {
                IF alarm:NAME = alarmName { DELETEALARM(alarm:ID). }
            }
        }
    }
    IF stateGet("phase","") = "ATMO_DEORBIT" { stateRemove("atmo_deorbit_plan"). }
    PRINT "Saved landing target, mission/return sequence and all overrides preserved.".
    IF HASNODE {
        PRINT "Another maneuver remains and was preserved. Review it before rebooting.".
    } ELSE {
        PRINT "REBOOT. to plan and execute a new deorbit for the saved target. No burn started here.".
    }
}

_cmdDeorbitretry().
