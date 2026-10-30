// Release an explicit fuel reserve and retarget the existing Kerbin return.
// RUNPATH("0:/cmd/returnmcc.ks",52000,0). Then REBOOT. No burn starts here.
@LAZYGLOBAL OFF.
PARAMETER targetPe IS 52000.
PARAMETER reserveDv IS 0.

LOCAL FUNCTION _cmdReturnmcc {
    IF NOT (targetPe >= 52000 AND targetPe <= 54000
            AND reserveDv >= 0 AND reserveDv < 1e30) {
        PRINT "Use a Kerbin Pe in 52000-54000m and a finite nonnegative reserve. Nothing changed.". RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    LOCAL FUNCTION ready {
        RETURN stateGet("phase","") = "MCC"
            AND stateGet("mission_type","") = "kerbin_return"
            AND SHIP:BODY:NAME = "Kerbin" AND SHIP:BODY:ATM:EXISTS
            AND SHIP:ALTITUDE > SHIP:BODY:ATM:HEIGHT
            AND ETA:PERIAPSIS >= 600 AND ETA:PERIAPSIS < 1e30
            AND NOT HASNODE
            AND NOT (stateGet("burn_pending","false") = "true"
                AND stateGet("burn_started","false") = "true")
            AND NOT ABORT AND SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
            AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
    }
    IF NOT ready() {
        PRINT "Requires a stopped Kerbin-return MCC outside atmosphere, at least600s to Pe, no node/interrupted burn and Abort clear. Nothing changed.". RETURN.
    }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF NOT ready() {
        PRINT "Flight context changed while settling warp. Mission and settings retained.". RETURN.
    }
    // A safe54km Pe alone must not skip the requested52km correction.
    // Keep the existing52-54km floor/ceiling; acquire within250m of the goal.
    missionOverrideUpdate(LEXICON("CAPTURE_PE",targetPe,
        "REENTRY_PE",targetPe,"AEROBRAKE_PE",targetPe,
        "MCC_RETURN_RESERVE_DV",reserveDv,"MCC_RETURN_DV_CAP",-1,
        "MCC_AEROBRAKE_SAFE_PE_MIN",MAX(52000,targetPe-250),
        "MCC_AEROBRAKE_SAFE_PE_MAX",MIN(54000,targetPe+250),
        "AEROBRAKE_CORRECTION_PE_MIN",52000,"AEROBRAKE_CORRECTION_PE_MAX",54000,
        "AEROBRAKE_BRAKE_PE_FLOOR",52000,
        "RETURN_TRIM_PE_MIN",52000,"RETURN_TRIM_PE_MAX",54000)).
    PRINT "Return MCC target=" + targetPe + "m; protected reserve=" + reserveDv + "m/s.".
    PRINT "REBOOT. to plan within live remaining fuel. Mission, staging and entry assistance preserved.".
    PRINT "No burn started here. An unaffordable or invalid correction still holds for review.".
}

_cmdReturnmcc().
