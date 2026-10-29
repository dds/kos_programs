// Accept an already-achieved Kerbin Pe repair, including a legacy tiny-
// residual abort without repair intent. Does not burn, stage or change phase.
// RUNPATH("0:/cmd/reentryresume.ks"). Then REBOOT.
@LAZYGLOBAL OFF.
PARAMETER targetPe IS 53000.

LOCAL FUNCTION _cmdReentryresume {
    IF ABORT OR NOT (targetPe >= 52000 AND targetPe <= 54000)
            OR SHIP:BODY:NAME <> "Kerbin"
            OR NOT (SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
                AND SHIP:CONTROL:MAINTHROTTLE <= 0
                AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
        PRINT "Requires idle thrust/throttle, Abort clear and a Kerbin target in 52000-54000m. Nothing changed.".
        RETURN.
    }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("reentry_pe").
    // Refresh function-only source when an old RUNONCEPATH is still resident.
    IF HOMECONNECTION:ISCONNECTED AND EXISTS("0:/lib/reentry_pe.ks") {
        RUNPATH("0:/lib/reentry_pe.ks").
    }
    IF NOT reentryPeRecover(targetPe,52000,54000,TRUE) {
        PRINT "Repair not accepted: requires AEROBRAKE, a stopped tiny-residual trim and an already-safe live orbit outside atmosphere.".
        PRINT "Interrupted burn and unrelated nodes retained. Inspect the log before retrying.".
        RETURN.
    }
    PRINT "Current entry orbit verified; tiny-residual repair accepted. Historical burn report retained.".
    PRINT "REBOOT. to continue AEROBRAKE. No burn or staging started by this command.".
}

_cmdReentryresume().
