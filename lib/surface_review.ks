// ============================================================
// surface_review.ks - Operator-selected next site or surface return.
// (0:/lib/surface_review.ks)
// No ascent, invented wake deadline or automatic mission completion.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION phaseSurfaceReview {
    IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR ABORT OR WARP <> 0 OR HASNODE
            OR SHIP:BODY:NAME <> getTarget() OR SHIP:STATUS <> "LANDED"
            OR NOT (SHIP:VELOCITY:SURFACE:MAG <= 0.5)
            OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:MAINTHROTTLE > 0
            OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0
            OR stateGet("burn_pending","false") = "true"
            OR stateGet("burn_started","false") = "true"
            OR stateGet("deorbit_burn_started","false") = "true" {
        mLogError("Surface review requires a settled idle landing; mission and nodes retained.").
        yieldToPrompt(). RETURN.
    }
    IF NOT thrustCutoffOk() { yieldToPrompt(). RETURN. }
    UNLOCK STEERING.
    SAS OFF.
    BRAKES ON.
    PRINT "SURFACE REVIEW: science dwell complete; no automatic relaunch.".
    LOCAL quotes IS CHAR(34).
    IF MISSION_EXCURSIONS > 0 {
        PRINT "Next site: select a waypoint here, RUNPATH(" + quotes + "0:/cmd/visit.ks" + quotes + "). then REBOOT.".
        PRINT "Or RUNPATH(" + quotes + "0:/cmd/visit.ks" + quotes + ",LEXICON(" + quotes
            + "lat" + quotes + ",latitude," + quotes + "lng" + quotes + ",longitude)). then REBOOT.".
    }
    IF SEQUENCE:CONTAINS("SURFACE_RETURN_SETUP") {
        PRINT "Return to Kerbin: RUNPATH(" + quotes + "0:/cmd/setphase.ks" + quotes + "," + quotes
            + "SURFACE_RETURN_SETUP" + quotes + "). then REBOOT.".
    }
    mLogSummary("STATS surface-review body=" + SHIP:BODY:NAME
        + " visit=" + stateGetNum("surface_visit",0) + " remainingDv=" + SHIP:DELTAV:VACUUM
        + " automaticResume=False").
    yieldToPrompt().
}
