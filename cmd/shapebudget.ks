// Grant further SHAPE allowance without erasing spent dV or fuel reserves.
// RUNPATH("0:/cmd/shapebudget.ks",1500). Then REBOOT. No burn starts here.
@LAZYGLOBAL OFF.
PARAMETER additionalDv.

LOCAL FUNCTION _cmdShapebudget {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    IF NOT (additionalDv > 0 AND additionalDv < 1e30) {
        PRINT "Specify a finite positive additional allowance in m/s. Nothing changed.". RETURN.
    }
    IF stateGet("phase","") <> "SHAPE" OR ABORT OR HASNODE
            OR SHIP:STATUS <> "ORBITING"
            OR NOT (SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
                AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
        PRINT "Requires SHAPE, stable orbit, no node, Abort clear and idle thrust/throttle. Nothing changed.". RETURN.
    }
    LOCAL id IS SHIP:BODY:NAME + ":" + stateGetNum("launch_time", 0).
    LOCAL spent IS 0.
    IF stateGet("shape_budget_id","") = id {
        SET spent TO stateGetNum("shape_budget_spent",0).
    }
    IF NOT (spent >= 0 AND spent < 1e30 AND spent+additionalDv < 1e30) {
        PRINT "Invalid saved shaping allowance. Nothing changed.". RETURN.
    }
    missionOverrideUpdate(LEXICON("SHAPE_TOTAL_DV_CAP",spent+additionalDv)).
    PRINT "SHAPE additional allowance="+additionalDv+"m/s; cumulative cap="+(spent+additionalDv)+"m/s.".
    PRINT "Recorded expenditure, per-burn cap and fuel reserve preserved. REBOOT. to replan.".
}

_cmdShapebudget().
