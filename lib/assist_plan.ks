// Opportunistic mission branch. Ordinary powered flight is the fallback.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _assistFallback {
    PARAMETER reason.
    mLogSummary("STATS assist mission decision=fallback reason=" + reason).
    // Skip the coast-only phase. A reboot between these durable transitions
    // sees no active flight and makes the same fallback without a new search.
    IF nextPhase(xferSeq) = "ASSIST_COAST" { nextPhase(xferSeq). }
    ELSE { assistFlightHold("assist-coast-missing-from-sequence"). }
}

GLOBAL FUNCTION phaseAssist {
    LOCAL phaseIndex IS 0.
    UNTIL phaseIndex >= xferSeq:LENGTH OR xferSeq[phaseIndex] = "ASSIST" { SET phaseIndex TO phaseIndex+1. }
    IF phaseIndex+2 >= xferSeq:LENGTH OR xferSeq[phaseIndex+1] <> "ASSIST_COAST" {
        assistFlightHold("invalid-assist-sequence"). RETURN.
    }
    IF NOT assistFlightIdle() { assistFlightHold("unsafe-planning-context"). RETURN. }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    LOCAL flight IS stateGet("assist_flight",LEXICON()).
    IF flight:LENGTH = 0 {
        IF HASNODE { assistFlightHold("existing-maneuver"). RETURN. }
        IF MISSION_ASSIST_ROUTE:LENGTH = 0 { _assistFallback("disabled"). RETURN. }
        LOCAL bodies IS assistRouteBodies(MISSION_ASSIST_ROUTE).
        IF bodies:LENGTH <> MISSION_ASSIST_ROUTE:LENGTH {
            assistFlightHold("invalid-route"). RETURN.
        }
        LOCAL settings IS assistContinuationSettings().
        IF settings:LENGTH = 0 { assistFlightHold("invalid-terminal-continuation"). RETURN. }
        LOCAL evidence IS assistEvaluate(0,MISSION_ASSIST_ROUTE,bodies).
        IF NOT evidence["OK"] { _assistFallback(evidence["REASON"]). RETURN. }
        SET flight TO LEXICON("mission",stateGet("mission_id",""),
            "launch",stateGetNum("launch_time",0),"vehicle",stateGet("vehicle",""),
            "route",MISSION_ASSIST_ROUTE,"settings",settings,"reserve",ASSIST_RESERVE_DV,
            "index",0,"lastBody","","lastPeUt",0,"alarm","","peAlarm","","status","coast").
        IF NOT assistFlightAffordable(flight,evidence) { _assistFallback("native-route-budget-or-timing"). RETURN. }
        // Entry costs zero. Refinement cannot improve that cost; adopt only
        // the existing safe/free moon science pass without buying a detour.
        IF assistGoalMode(MISSION_ASSIST_ROUTE) = "ORBIT" {
            LOCAL result IS planAssistRefinement(MISSION_ASSIST_ROUTE).
            IF NOT assistFlightIdle() { assistFlightHold("planning-interrupted"). RETURN. }
            IF result["OK"] {
                LOCAL nd IS result["NODE"].
                SET flight["node"] TO LEXICON("ut",nd:TIME,"body",SHIP:BODY:NAME,
                    "pro",nd:PROGRADE,"rad",nd:RADIALOUT,"normal",nd:NORMAL).
                SET flight TO assistFlightStore(flight,"planned").
            } ELSE {
                IF HASNODE { assistFlightHold("planning-node-changed"). RETURN. }
                // No profitable correction is needed to preserve an already
                // safe complete itinerary. Re-prove the raw unburned route.
                SET evidence TO assistEvaluate(0,MISSION_ASSIST_ROUTE,bodies).
                IF NOT assistFlightAffordable(flight,evidence) { _assistFallback("native-route-changed"). RETURN. }
            }
        }
        IF flight["status"] = "coast" { SET flight TO assistFlightStore(flight,"coast"). }
    }
    IF NOT assistFlightBound(flight) { assistFlightHold("saved-flight-mismatch"). RETURN. }
    IF flight["status"] <> "planned" AND flight["status"] <> "burning" AND flight["status"] <> "coast" {
        assistFlightHold("invalid-plan-status"). RETURN.
    }
    LOCAL bodies IS assistRouteBodies(flight["route"]).
    IF bodies:LENGTH <> flight["route"]:LENGTH { assistFlightHold("saved-route-invalid"). RETURN. }
    IF flight["status"] = "planned" {
        IF NOT assistFlightNodeMatches(flight) { assistFlightHold("saved-node-mismatch"). RETURN. }
        LOCAL evidence IS assistEvaluate(NEXTNODE,flight["route"],bodies).
        IF NOT assistFlightAffordable(flight,evidence) { assistFlightHold("preburn-route-budget-or-timing"). RETURN. }
        LOCAL baseline IS assistEvaluate(0,flight["route"],bodies).
        IF baseline["OK"] AND evidence["COST"]+ASSIST_MIN_GAIN > baseline["COST"] {
            // A stale preview must not spend fuel on an improvement that
            // disappeared while rebooted. The existing native route remains.
            REMOVE NEXTNODE.
            SET flight TO assistFlightStore(flight,"coast").
            mLogSummary("STATS assist correction decision=skip reason=gain-no-longer-present").
        } ELSE {
            LOCAL duration IS arrivalBurnSeconds(NEXTNODE:DELTAV:MAG).
            IF NOT (duration >= 0 AND duration < 1e30 AND SHIP:ORBIT:HASNEXTPATCH
                    AND NEXTNODE:TIME-duration/2 > TIME:SECONDS+30
                    AND NEXTNODE:TIME+duration/2+120 < TIME:SECONDS+SHIP:ORBIT:NEXTPATCHETA) {
                assistFlightHold("correction-window-changed"). RETURN.
            }
            SET flight TO assistFlightStore(flight,"burning").
            IF NOT executeManeuver() { assistFlightHold("correction-incomplete"). RETURN. }
        }
    }
    IF HASNODE OR NOT assistFlightIdle() { assistFlightHold("unfinished-correction"). RETURN. }
    LOCAL evidence IS assistEvaluate(0,flight["route"],bodies).
    IF NOT assistFlightAffordable(flight,evidence) {
        assistFlightHold("postburn-native-route-or-budget"). RETURN.
    }
    // A reboot after executor cleanup revalidates the actual route instead
    // of burning again. A remaining interrupted node always requires review.
    SET flight TO assistFlightStore(flight,"coast").
    mLogSummary("STATS assist mission decision=coast captureDv=" + evidence["CAPTURE_DV"]
        + " reserveDv=" + flight["reserve"] + " remainingDv=" + SHIP:DELTAV:VACUUM).
    nextPhase(xferSeq).
}
