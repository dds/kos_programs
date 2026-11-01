// Accept only a proved, physically stopped escape with a harmless node tail.
// RUNPATH("0:/cmd/escaperecover.ks"). Then REBOOT. No burn is executed here.
@LAZYGLOBAL OFF.
LOCAL FUNCTION _cmdEscapeRecover {
    IF NOT HOMECONNECTION:ISCONNECTED {
        PRINT "Escape recovery command needs an archive link; connected reboot also loads automatic recovery.". RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("maneuver").
    // These libraries contain definitions only. Refresh them explicitly so
    // a manual command can recover an old loaded ESCAPE band without a
    // reboot; apply the selected profile after their config defaults.
    RUNPATH("0:/lib/escape_handoff.ks").
    RUNPATH("0:/lib/return_escape.ks").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    IF vehicle = "" OR mid = "" { RETURN. }
    IF NOT bootApplyMissionConfig(vehicle,mid,HOMECONNECTION:ISCONNECTED) { RETURN. }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    // This explicit manual acknowledgement can run at a held prompt. Keep
    // automatic recovery strict and restore any old/new yield request.
    LOCAL priorYield IS phaseShouldYield.
    SET phaseShouldYield TO FALSE.
    LOCAL accepted IS returnEscapeRecover(SEQUENCE).
    SET phaseShouldYield TO priorYield OR phaseShouldYield.
    IF NOT accepted {
        PRINT "Escape recovery refused: require this mission's stopped ESCAPE residual <=1m/s and1%, a safe actual parent orbit, COAST then SHAPE/MCC, Abort clear and idle controls.".
        PRINT "Only the original burn tail can be removed automatically; any different node is preserved.".
        PRINT "Saved phase="+stateGet("phase","")+" burnPhase="+stateGet("burn_phase","")
            +" residual="+stateGetNum("burn_abort_residual",-1)+" abort="+ABORT.
        IF HASNODE {
            PRINT "Retained node dV="+NEXTNODE:DELTAV:MAG+" UT="+NEXTNODE:TIME
                +" original burn UT="+stateGetNum("burn_node_time",-1)+".".
        }
        LOCAL actual IS SHIP:ORBIT.
        IF actual:HASNEXTPATCH { SET actual TO actual:NEXTPATCH. }
        PRINT "Actual trajectory body="+actual:BODY:NAME+" ecc="+actual:ECCENTRICITY+".".
        IF actual:ECCENTRICITY >= 0 AND actual:ECCENTRICITY < 1 {
            PRINT "Bound trajectory Pe="+actual:PERIAPSIS+" Ap="+actual:APOAPSIS+".".
        }
        PRINT "Inspect cmd/burnreport.ks and the actual parent-body orbit. No burn or phase change.".
        RETURN.
    }
    LOCAL nextBand IS phaseBandForPhase("COAST").
    stateSaveReloadState("ESCAPE_RECOVERED","COAST",nextBand).
    IF stateGet("phase","") <> "COAST" OR stateGet("reload_required","") <> "true"
            OR stateGet("reload_next_phase","") <> "COAST" OR stateGet("reload_next_band","") <> nextBand {
        PRINT "Escape accepted but phase checkpoint failed; retry this command. No burn started.". RETURN.
    }
    PRINT "Achieved escape accepted; original cutoff report retained. REBOOT. to coast and run the scheduled correction.".
}
_cmdEscapeRecover().
