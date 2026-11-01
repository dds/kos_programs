// Mission-level acceptance of an achieved escape, independent of node trim.
// No burn/staging/planning here. Strict cutoff evidence remains unchanged.
@LAZYGLOBAL OFF.
GLOBAL ESCAPE_RESIDUAL_RECOVERY_DV IS 1.

LOCAL FUNCTION _escapeCorrectionMode {
    PARAMETER seq.
    LOCAL idx IS 0.
    UNTIL idx >= seq:LENGTH {
        IF seq[idx] = "ESCAPE" {
            IF idx+2 < seq:LENGTH AND seq[idx+1] = "COAST"
                    AND LIST("MCC","SHAPE"):CONTAINS(seq[idx+2]) { RETURN seq[idx+2]. }
            RETURN "".
        }
        SET idx TO idx+1.
    }
    RETURN "".
}

LOCAL FUNCTION _escapeHandoffIdle {
    RETURN stateGet("phase","") = "ESCAPE" AND NOT ABORT AND NOT phaseShouldYield
        AND WARP = 0 AND SHIP = KUNIVERSE:ACTIVEVESSEL
        AND SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
        AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

LOCAL FUNCTION _escapeHandoffPatch {
    PARAMETER originName.
    PARAMETER mode.
    PARAMETER targetPe.
    PARAMETER peTolerance.
    LOCAL bodies IS LIST().
    LIST BODIES IN bodies.
    LOCAL origin IS 0.
    FOR candidate IN bodies { IF candidate:NAME = originName { SET origin TO candidate. } }
    IF origin = 0 { RETURN 0. }
    IF NOT origin:HASBODY { RETURN 0. }
    LOCAL parent IS origin:BODY.
    IF getTarget("") <> parent:NAME { RETURN 0. }
    LOCAL actual IS SHIP:ORBIT.
    IF SHIP:BODY = origin {
        // Examine the flown orbit, never the old node's predicted orbit.
        IF NOT actual:HASNEXTPATCH OR actual:NEXTPATCH:BODY <> parent { RETURN 0. }
        SET actual TO actual:NEXTPATCH.
    } ELSE IF SHIP:BODY <> parent { RETURN 0. }
    IF NOT (actual:BODY = parent AND actual:ECCENTRICITY >= 0 AND actual:ECCENTRICITY < 1
            AND actual:PERIAPSIS > 0 AND actual:APOAPSIS >= actual:PERIAPSIS
            AND actual:APOAPSIS+parent:RADIUS < parent:SOIRADIUS
            AND NOT actual:HASNEXTPATCH) { RETURN 0. }
    IF mode = "SHAPE" {
        LOCAL floorAlt IS 10000.
        IF DEFINED SHAPE_MIN_PE { SET floorAlt TO MAX(0,SHAPE_MIN_PE). }
        IF parent:ATM:EXISTS { SET floorAlt TO MAX(floorAlt,parent:ATM:HEIGHT+10000). }
        IF NOT (floorAlt >= 0 AND floorAlt < 1e30 AND actual:PERIAPSIS >= floorAlt) { RETURN 0. }
    } ELSE IF mode = "MCC" {
        // Entry missions retain their original Pe corridor. A future MCC
        // alone is not permission to coast on an unsafe atmospheric return.
        IF NOT (targetPe > 0 AND targetPe < 1e30 AND peTolerance > 0 AND peTolerance < 1e30
                AND ABS(actual:PERIAPSIS-targetPe) <= peTolerance) { RETURN 0. }
    } ELSE { RETURN 0. }
    RETURN actual.
}

LOCAL FUNCTION _escapeHandoffNodeOwned {
    PARAMETER receipt.
    RETURN NOT HASNODE OR (ALLNODES:LENGTH = 1
        AND ABS(NEXTNODE:TIME-receipt["NODE_UT"]) < 0.5
        AND NEXTNODE:DELTAV:MAG >= 0 AND NEXTNODE:DELTAV:MAG <= receipt["LIMIT"]).
}

LOCAL FUNCTION _escapeHandoffCurrent {
    PARAMETER receipt.
    RETURN _escapeHandoffIdle() AND receipt["MISSION"] = stateGet("mission_id","")
        AND receipt["MISSION"] <> "" AND receipt["LAUNCH"] = stateGetNum("launch_time",0).
}

GLOBAL FUNCTION escapeBurnRecover {
    PARAMETER seq.
    PARAMETER targetPe.
    PARAMETER peTolerance.
    IF NOT _escapeHandoffIdle()
            OR NOT (ESCAPE_RESIDUAL_RECOVERY_DV > 0 AND ESCAPE_RESIDUAL_RECOVERY_DV <= 1) { RETURN FALSE. }
    LOCAL mode IS _escapeCorrectionMode(seq).
    IF mode = "" { RETURN FALSE. }
    LOCAL receipt IS stateGet("escape_burn_handoff",LEXICON()).
    LOCAL replay IS receipt:LENGTH > 0.
    IF replay {
        FOR field IN LIST("MISSION","LAUNCH","ORIGIN","NODE_UT","RESIDUAL","LIMIT","PLANNED","MODE","PE") {
            IF NOT receipt:HASKEY(field) { RETURN FALSE. }
        }
        IF receipt["MISSION"] <> stateGet("mission_id","")
                OR receipt["LAUNCH"] <> stateGetNum("launch_time",0)
                OR receipt["MODE"] <> mode OR receipt["PE"] <> targetPe
                OR NOT (receipt["LIMIT"] > 0 AND receipt["LIMIT"] <= ESCAPE_RESIDUAL_RECOVERY_DV
                    AND receipt["PLANNED"] > 0 AND receipt["PLANNED"] < 1e30
                    AND receipt["LIMIT"] <= receipt["PLANNED"]*0.01
                    AND receipt["NODE_UT"] > 0 AND receipt["NODE_UT"] <= TIME:SECONDS
                    AND receipt["RESIDUAL"] >= 0 AND receipt["RESIDUAL"] <= receipt["LIMIT"]) { RETURN FALSE. }
        IF stateGet("burn_pending","false") = "true"
                AND stateGetNum("burn_node_time",-1) <> receipt["NODE_UT"] { RETURN FALSE. }
    } ELSE {
        LOCAL planned IS stateGetNum("burn_dv",-1).
        LOCAL residual IS stateGetNum("burn_abort_residual",-1).
        LOCAL started IS stateGetNum("burn_start_time",-1).
        LOCAL aborted IS stateGetNum("burn_abort_time",-1).
        LOCAL report IS stateGet("last_burn_report","").
        IF NOT (maneuverBurnInterrupted() AND stateGet("burn_status","") = "interrupted"
                AND stateGet("burn_mission_id","") = stateGet("mission_id","")
                AND stateGet("mission_id","") <> ""
                AND stateGetNum("burn_launch_time",-1) = stateGetNum("launch_time",0)
                AND stateGet("burn_abort_reason","") = "residual-outside-tolerance"
                AND planned > 0 AND planned < 1e30
                AND ESCAPE_RESIDUAL_RECOVERY_DV > 0 AND ESCAPE_RESIDUAL_RECOVERY_DV <= 1
                AND residual >= 0 AND residual <= MIN(ESCAPE_RESIDUAL_RECOVERY_DV,planned*0.01)
                AND started >= stateGetNum("launch_time",0) AND aborted >= started AND aborted <= TIME:SECONDS
                AND stateGetNum("burn_node_time",-1) > 0 AND stateGetNum("burn_node_time",-1) <= TIME:SECONDS
                AND TIME:SECONDS < 1e30
                AND report:CONTAINS("phase=ESCAPE ")
                AND report:CONTAINS("body="+stateGet("burn_body","")+" ")
                AND report:CONTAINS("cutoffFault=residual-outside-tolerance ")
                AND report:CONTAINS("shutdownAttempted=False thrustStopped=True")
                AND (report:CONTAINS("reason=live-node-trim ")
                    OR report:CONTAINS("reason=live-thrust-axis-trim ")
                    OR report:CONTAINS("reason=live-vector-passed-target "))) { RETURN FALSE. }
        SET receipt TO LEXICON("MISSION",stateGet("mission_id",""),"LAUNCH",stateGetNum("launch_time",0),
            "ORIGIN",stateGet("burn_body",""),"NODE_UT",stateGetNum("burn_node_time",-1),
            "RESIDUAL",residual,"LIMIT",MIN(ESCAPE_RESIDUAL_RECOVERY_DV,planned*0.01),
            "PLANNED",planned,"MODE",mode,"PE",targetPe).
    }
    IF NOT _escapeHandoffNodeOwned(receipt)
            OR _escapeHandoffPatch(receipt["ORIGIN"],mode,targetPe,peTolerance) = 0
            OR NOT thrustCutoffOk() OR NOT _escapeHandoffCurrent(receipt)
            OR NOT _escapeHandoffNodeOwned(receipt)
            OR mode <> _escapeCorrectionMode(seq)
            OR _escapeHandoffPatch(receipt["ORIGIN"],mode,targetPe,peTolerance) = 0 { RETURN FALSE. }
    IF NOT replay { stateSet("escape_burn_handoff",receipt). }
    // Receipt before node/marker cleanup makes an interrupted handoff
    // resumable without ever replanning/repeating a flown departure.
    LOCAL actual IS _escapeHandoffPatch(receipt["ORIGIN"],mode,targetPe,peTolerance).
    IF actual = 0 OR NOT _escapeHandoffCurrent(receipt) OR NOT _escapeHandoffNodeOwned(receipt)
            OR mode <> _escapeCorrectionMode(seq) { RETURN FALSE. }
    maneuverAcceptHandoff("accept-achieved-escape").
    IF HASNODE OR stateGet("burn_pending","false") = "true" OR stateGet("burn_started","false") = "true"
            OR NOT _escapeHandoffCurrent(receipt) { RETURN FALSE. }
    mLogSummary("STATS escape handoff decision=accept-achieved-escape residual="+receipt["RESIDUAL"]
        +" target="+actual:BODY:NAME+" Pe="+actual:PERIAPSIS+" Ap="+actual:APOAPSIS
        +" correction="+mode+" replay="+replay).
    RETURN TRUE.
}
