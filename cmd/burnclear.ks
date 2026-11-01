// ============================================================
// Dismiss a manually finished review-phase burn after deleting its tail.
// RUNPATH("0:/cmd/burnclear.ks"). No burn, node or phase change.
// This explicit operator acknowledgement is NOT automatic burn recovery.
// ============================================================
@LAZYGLOBAL OFF.

LOCAL FUNCTION _cmdBurnclear {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("excursion").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    IF vehicle = "" OR mid = "" { RETURN. }
    IF NOT bootApplyMissionConfig(vehicle,mid,HOMECONNECTION:ISCONNECTED) { RETURN. }
    LOCAL phase_ IS stateGet("phase","").
    LOCAL FUNCTION ready {
        // The visible tail must have been removed by the operator. Never
        // delete a node, dismiss another phase's burn or infer success from
        // the mere absence of a node. Keep automatic recovery unchanged.
        LOCAL blocker IS excursionBlockReason().
        IF blocker <> "saved-burn-pending" AND blocker <> "saved-burn-started" { RETURN FALSE. }
        IF NOT LIST("SCIENCE_OPS","SCANSAT_OPS","DONE","LANDING_REVIEW","SURFACE_REVIEW"):CONTAINS(phase_) {
            RETURN FALSE.
        }
        IF SHIP:BODY:ATM:EXISTS OR NOT excursionOrbitSafe() OR NOT (SHIP:PERIAPSIS >= 10000)
                OR NOT (SHIP:APOAPSIS >= SHIP:PERIAPSIS AND SHIP:APOAPSIS+SHIP:BODY:RADIUS < SHIP:BODY:SOIRADIUS)
                OR HASNODE OR stateGet("phase","") <> phase_
                OR stateGet("vehicle","") <> vehicle OR stateGet("mission_id","") <> mid
                OR stateGet("burn_phase","") <> phase_ OR stateGet("burn_body","") <> SHIP:BODY:NAME
                OR stateGet("burn_mission_id","") <> mid
                OR stateGetNum("burn_launch_time",-1) <> stateGetNum("launch_time",0)
                OR stateGet("burn_pending","false") <> "true" OR stateGet("burn_started","false") <> "true"
                OR stateGet("deorbit_burn_started","false") = "true" OR stateGet("hop_route_active",FALSE)
                OR stateGet("burn_status","") <> "interrupted"
                OR stateGet("burn_abort_reason","") <> "residual-outside-tolerance" { RETURN FALSE. }
        LOCAL planned IS stateGetNum("burn_dv",-1).
        LOCAL residual IS stateGetNum("burn_abort_residual",-1).
        LOCAL started IS stateGetNum("burn_start_time",-1).
        LOCAL aborted IS stateGetNum("burn_abort_time",-1).
        LOCAL nodeUt IS stateGetNum("burn_node_time",-1).
        LOCAL report IS stateGet("last_burn_report","").
        RETURN planned > 0 AND planned < 1e30 AND residual >= 0 AND residual <= MIN(0.25,planned)
            AND started >= stateGetNum("launch_time",0) AND aborted >= started AND aborted <= TIME:SECONDS
            AND nodeUt > 0 AND nodeUt <= TIME:SECONDS AND TIME:SECONDS < 1e30
            AND report:CONTAINS("phase="+phase_+" ") AND report:CONTAINS("body="+SHIP:BODY:NAME+" ")
            AND report:CONTAINS("cutoffFault=residual-outside-tolerance ")
            AND report:CONTAINS("shutdownAttempted=False thrustStopped=True")
            AND (report:CONTAINS("reason=live-node-trim ")
                OR report:CONTAINS("reason=live-thrust-axis-trim ")
                OR report:CONTAINS("reason=live-vector-passed-target ")).
    }
    IF NOT ready() {
        PRINT "Burn clear requires an enabled airless review mission, safe orbit with Pe>=10km, Abort clear, zero thrust/throttle, no node, and its matching stopped residual-only burn <=0.25m/s.".
        PRINT "Nothing changed. Inspect the exact saved attempt with cmd/burnreport.ks.".
        RETURN.
    }
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF NOT ready() OR NOT thrustCutoffOk() OR NOT ready() {
        PRINT "Burn clear context changed; saved attempt retained.". RETURN.
    }
    // Save the operator's decision before removing the exact attempt fields
    // in one state write. A reboot sees either the old attempt or no attempt;
    // departure history, hardware restoration, reports and budgets stay put.
    LOCAL outcome IS "STATS burn handoff decision=operator-accept-achieved-orbit phase=" + phase_
        + " ut=" + TIME:SECONDS + " priorAbort=" + stateGet("burn_abort_reason","")
        + " priorResidual=" + stateGetNum("burn_abort_residual",-1).
    stateSet("last_burn_handoff",outcome).
    LOCAL dismissed IS LEXICON().
    FOR key IN LIST("pending","started","phase","mission_id","launch_time","node_time",
            "start_time","dv","status","body","pause_reason","abort_reason","abort_detail",
            "abort_time","abort_residual","abort_paused") {
        SET dismissed[key] TO stateGet("burn_"+key,"").
    }
    stateRemoveMatchingPrefixed("burn_",dismissed).
    IF stateGet("burn_pending","false") = "true" OR stateGet("burn_started","false") = "true" {
        PRINT "Burn clear did not finish; saved attempt retained. Inspect cmd/burnreport.ks.". RETURN.
    }
    mLogSummary(outcome).
    PRINT "Saved manual burn tail dismissed; cutoff report, mission phase and fuel budget retained.".
    PRINT "Run the intended orbit/visit command again. No burn or phase change was made here.".
}

_cmdBurnclear().
