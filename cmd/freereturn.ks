// ============================================================
// cmd/freereturn.ks — report free-return geometry for the current
// trajectory  (0:/cmd/freereturn.ks)
//
// Run after the transfer/encounter exists (post-XING) to see what the
// flyby would do to the return: the moon flyby periapsis and the
// post-flyby home periapsis vs the reentry target. This is the number
// (~4000 km on the broken plan) the FREE_RT_BPLANE solver drives down.
//
// Usage:
//   RUNPATH("0:/cmd/freereturn.ks").          // uses the mission target
//   RUNPATH("0:/cmd/freereturn.ks", "MUN").   // explicit moon
// ============================================================

PARAMETER bodyName IS "".

RUNPATH("1:/lib/boot_lib").
bootPreamble().
RUNONCEPATH("0:/lib/lib_bplane_math.ks").
RUNONCEPATH("0:/lib/free_return.ks").

LOCAL tgt IS 0.
IF bodyName <> "" {
    IF BODYEXISTS(bodyName) { SET tgt TO BODY(bodyName). }
} ELSE IF getTarget("") <> "" AND BODYEXISTS(getTarget("")) {
    SET tgt TO BODY(getTarget("")).
}

PRINT " ".
PRINT "  -- FREE-RETURN CHECK --".
IF tgt = 0 {
    PRINT "  No valid target body.".
    PRINT "  Usage: RUNPATH('0:/cmd/freereturn.ks', 'MUN').".
} ELSE {
    LOCAL pe IS freeReturnReport(tgt).
    IF pe < 0 {
        PRINT "  No return patch to " + tgt:BODY:NAME + " visible.".
        PRINT "  -> no encounter yet, the flyby doesn't exit in view,".
        PRINT "     or KSP's conic patch limit is too low to show it.".
    } ELSE {
        PRINT "  Post-flyby " + tgt:BODY:NAME + " Pe: "
            + ROUND(pe / 1000, 1) + " km".
        PRINT "  Free-return target Pe:   "
            + ROUND(freeReturnTargetPe() / 1000, 1) + " km".
        IF ABS(pe - freeReturnTargetPe()) <= FREE_RT_ACCEPT_TOL {
            PRINT "  -> already within the reentry corridor.".
        } ELSE {
            PRINT "  -> outside corridor; FREE_RT_BPLANE would correct it.".
        }
    }
    PRINT "  (full geometry in the STATS free-return log line)".
}
