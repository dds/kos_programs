// Replan SHAPE or LAND_PREP from the achieved orbit after an interrupted burn.
// RUNPATH("0:/cmd/shaperetry.ks"). Then REBOOT. Does not ignite or advance.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _cmdShaperetry {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    LOCAL FUNCTION ready {
        LOCAL floorAlt IS 0.
        IF SHIP:BODY:ATM:EXISTS { SET floorAlt TO SHIP:BODY:ATM:HEIGHT. }
        LOCAL phase_ IS stateGet("phase","").
        RETURN (phase_ = "SHAPE" OR phase_ = "LAND_PREP")
            AND stateGet("burn_phase","") = phase_
            AND stateGet("burn_body","") = SHIP:BODY:NAME
            AND stateGet("burn_pending","false") = "true"
            AND stateGet("burn_started","false") = "true"
            AND SHIP:STATUS = "ORBITING" AND SHIP:PERIAPSIS > floorAlt
            AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
            AND NOT SHIP:ORBIT:HASNEXTPATCH
            AND NOT ABORT AND SHIP:THRUST <= 0.001
            AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
    }
    LOCAL FUNCTION resetShape {
        IF NOT ready() {
            PRINT "Orbit retry requires its SHAPE/LAND_PREP interrupted burn, matching body, stable orbit, Abort clear and all thrust/throttle zero. Nothing changed.".
            RETURN FALSE.
        }
        SET WARP TO 0.
        WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
        IF NOT ready() {
            PRINT "Vehicle state changed while settling warp; node and state preserved.".
            RETURN FALSE.
        }
        IF HASNODE {
            LOCAL nodeUt IS NEXTNODE:TIME.
            IF NOT (ABS(nodeUt - stateGetNum("burn_node_time",-1)) < 0.5) {
                PRINT "Remaining node does not match the interrupted SHAPE burn. Nothing changed.".
                PRINT "Inspect it; if it is an unwanted SHAPE retry node, REMOVE NEXTNODE. then run this command again.".
                RETURN FALSE.
            }
            REMOVE NEXTNODE.
        }
        // Keep last_burn_report, budget ledger, mission, phase and overrides.
        // bootPreamble restores any interrupted CPU setting before clearing it.
        stateRemovePrefix("burn_").
        mLog("STATS shape retry reset=True phase="+stateGet("phase","")+" replan=achieved-orbit budgetPreserved=True").
        RETURN TRUE.
    }
    IF resetShape() {
        PRINT "Interrupted orbit-shaping attempt cleared; achieved orbit and mission budget retained.".
        PRINT "REBOOT. to load updates and plan remaining corrections. No burn started here.".
    }
}

_cmdShaperetry().
