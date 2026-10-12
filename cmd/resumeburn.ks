// Resume an interrupted XING burn NOW using its retained live node.
// Inspect staging/trajectory first; requires the updated maneuver library.
// Usage: RUNPATH("0:/cmd/resumeburn.ks").
@LAZYGLOBAL OFF.

IF stateGet("phase", "") <> "XING" OR NOT maneuverBurnInterrupted() {
    PRINT "No interrupted XING burn to resume.".
    RETURN.
}
IF NOT HASNODE {
    PRINT "Cannot resume: the interrupted maneuver node is missing.".
    RETURN.
}
IF ABORT {
    PRINT "ABORT is set. Clear it deliberately before resuming the burn.".
    RETURN.
}
SET BURN_RESUME_REQUESTED TO TRUE.
resumeMission().
SET BURN_RESUME_REQUESTED TO FALSE.
