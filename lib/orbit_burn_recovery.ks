// ============================================================
// orbit_burn_recovery.ks - Accept a harmless tail, NOT a failed capture.
// Loaded only by capture/orbit shaping. The executor stays strict.
// Actual safe orbit + benign cutoff evidence authorize remeasurement;
// SHAPE still owns every requested final orbit tolerance and fuel limit.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL ORBIT_RESIDUAL_RECOVERY_DV IS 0.25.

LOCAL FUNCTION _orbitRecoverySafe {
    PARAMETER phaseLabel.
    PARAMETER floorAlt.
    PARAMETER ceilingAlt.
    RETURN NOT ABORT AND NOT phaseShouldYield AND WARP = 0
        AND SHIP = KUNIVERSE:ACTIVEVESSEL AND stateGet("phase","") = phaseLabel
        AND LIST("CAPTURE","SHAPE","DEPARTURE_SHAPE"):CONTAINS(phaseLabel)
        AND SHIP:STATUS = "ORBITING" AND NOT SHIP:ORBIT:HASNEXTPATCH
        AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
        AND floorAlt >= 0 AND floorAlt < 1e30
        AND SHIP:PERIAPSIS > 0 AND SHIP:PERIAPSIS >= floorAlt
        AND SHIP:APOAPSIS >= SHIP:PERIAPSIS
        AND SHIP:APOAPSIS+SHIP:BODY:RADIUS < SHIP:BODY:SOIRADIUS
        AND (ceilingAlt < 0 OR SHIP:PERIAPSIS <= ceilingAlt)
        AND SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
        AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

LOCAL FUNCTION _orbitRecoveryNodeOwned {
    PARAMETER receipt.
    RETURN NOT HASNODE OR (ALLNODES:LENGTH = 1
        AND ABS(NEXTNODE:TIME-receipt["NODE_UT"]) < 0.5
        AND NEXTNODE:DELTAV:MAG >= 0
        AND NEXTNODE:DELTAV:MAG <= MIN(ORBIT_RESIDUAL_RECOVERY_DV,receipt["LIMIT"])).
}

GLOBAL FUNCTION orbitBurnRecover {
    PARAMETER phaseLabel.
    PARAMETER floorAlt.
    PARAMETER ceilingAlt.
    IF NOT _orbitRecoverySafe(phaseLabel,floorAlt,ceilingAlt)
            OR NOT (ORBIT_RESIDUAL_RECOVERY_DV > 0 AND ORBIT_RESIDUAL_RECOVERY_DV <= 0.25) { RETURN FALSE. }
    LOCAL receipt IS stateGet("orbit_burn_recovery",LEXICON()).
    LOCAL replay IS receipt:HASKEY("PHASE") AND receipt:HASKEY("MISSION")
        AND receipt:HASKEY("LAUNCH") AND receipt:HASKEY("BODY")
        AND receipt:HASKEY("NODE_UT") AND receipt:HASKEY("RESIDUAL") AND receipt:HASKEY("LIMIT").
    IF replay {
        SET replay TO receipt["PHASE"] = phaseLabel AND receipt["MISSION"] = stateGet("mission_id","")
            AND receipt["LAUNCH"] = stateGetNum("launch_time",0) AND receipt["BODY"] = SHIP:BODY:NAME.
    }
    IF receipt:LENGTH > 0 AND NOT replay { RETURN FALSE. }
    IF NOT replay {
        IF NOT maneuverBurnInterrupted() OR stateGet("burn_body","") <> SHIP:BODY:NAME
                OR stateGet("burn_abort_reason","") <> "residual-outside-tolerance"
                OR stateGet("burn_mission_id",stateGet("mission_id","")) <> stateGet("mission_id","")
                OR stateGetNum("burn_launch_time",stateGetNum("launch_time",0)) <> stateGetNum("launch_time",0)
                OR stateGet("mission_id","") = "" { RETURN FALSE. }
        LOCAL planned IS stateGetNum("burn_dv",-1).
        LOCAL residual IS stateGetNum("burn_abort_residual",-1).
        LOCAL report IS stateGet("last_burn_report","").
        LOCAL started IS stateGetNum("burn_start_time",-1).
        LOCAL aborted IS stateGetNum("burn_abort_time",-1).
        IF NOT (planned > 0 AND planned < 1e30 AND ORBIT_RESIDUAL_RECOVERY_DV > 0
                    AND ORBIT_RESIDUAL_RECOVERY_DV <= 0.25
                    AND residual >= 0 AND residual <= MIN(ORBIT_RESIDUAL_RECOVERY_DV,planned*0.01)
                    AND started >= stateGetNum("launch_time",0) AND aborted >= started
                    AND aborted <= TIME:SECONDS AND TIME:SECONDS < 1e30
                    AND stateGetNum("burn_node_time",-1) > 0
                    AND stateGetNum("burn_node_time",-1) <= TIME:SECONDS)
                OR NOT (report:CONTAINS("phase="+phaseLabel+" ")
                    AND report:CONTAINS("body="+SHIP:BODY:NAME+" ")
                    AND report:CONTAINS("cutoffFault=residual-outside-tolerance ")
                    AND report:CONTAINS("shutdownAttempted=False thrustStopped=True")
                    AND (report:CONTAINS("reason=live-node-trim ")
                        OR report:CONTAINS("reason=live-thrust-axis-trim ")
                        OR report:CONTAINS("reason=live-vector-passed-target "))) { RETURN FALSE. }
        SET receipt TO LEXICON("PHASE",phaseLabel,"MISSION",stateGet("mission_id",""),
            "LAUNCH",stateGetNum("launch_time",0),"BODY",SHIP:BODY:NAME,
            "NODE_UT",stateGetNum("burn_node_time",-1),"RESIDUAL",residual,
            "LIMIT",MIN(ORBIT_RESIDUAL_RECOVERY_DV,planned*0.01)).
    }
    // A manual deletion of the old tail is fine. An unrelated/future node
    // is not ours to discard. Recheck the live residual as well as the log.
    IF NOT _orbitRecoveryNodeOwned(receipt) OR NOT thrustCutoffOk()
            OR NOT _orbitRecoverySafe(phaseLabel,floorAlt,ceilingAlt)
            OR NOT _orbitRecoveryNodeOwned(receipt) { RETURN FALSE. }
    // Intent precedes node removal/marker cleanup: CAPTURE must never repeat
    // its successful insertion if power is lost during the cleanup writes.
    IF NOT replay { stateSet("orbit_burn_recovery",receipt). }
    IF NOT _orbitRecoverySafe(phaseLabel,floorAlt,ceilingAlt) OR NOT _orbitRecoveryNodeOwned(receipt) { RETURN FALSE. }
    maneuverAcceptHandoff("accept-achieved-orbit").
    IF HASNODE OR NOT _orbitRecoverySafe(phaseLabel,floorAlt,ceilingAlt) {
        yieldToPrompt(). RETURN FALSE.
    }
    mLogSummary("STATS orbit-burn recovery phase="+phaseLabel+" residual="+receipt["RESIDUAL"]
        +" replay="+replay+" Pe="+SHIP:PERIAPSIS+" Ap="+SHIP:APOAPSIS
        +" finalGoalDeferred=True").
    RETURN TRUE.
}
