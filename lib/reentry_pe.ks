// ============================================================
// reentry_pe.ks — shared native-validated apoapsis Pe repair
// (0:/lib/reentry_pe.ks). The repair may spend the fuel protected from
// optional aerobrake assistance, using the active-stage fuel budget and
// shared maneuver executor. No repair is planned inside atmosphere.
// ============================================================
@LAZYGLOBAL OFF.

// Reserve one quarter of the native 250m planning tolerance for cutoff.
// dPe/dv at apoapsis follows directly from vis-viva. A low orbit usually
// needs only the normal 0.05m/s trim, not a 0.005m/s moving-vector chase.
GLOBAL FUNCTION reentryPeTrimLimit {
    PARAMETER desiredPe.
    LOCAL apoRadius IS SHIP:BODY:RADIUS+SHIP:APOAPSIS.
    LOCAL peRadius IS SHIP:BODY:RADIUS+desiredPe.
    LOCAL apoSpeed IS SQRT(2*SHIP:BODY:MU*peRadius/(apoRadius*(apoRadius+peRadius))).
    LOCAL sensitivity IS apoSpeed*(apoRadius+peRadius)^2/SHIP:BODY:MU.
    RETURN MIN(MIN(BURN_TRIM_ABS_COMPLETE_DV,BURN_TRIM_COMPLETE_MAX_DV),
        MIN(0.05,MAX(0.001,62.5/sensitivity))).
}

// Reconcile ONLY a physically stopped, tiny-residual Pe repair whose live
// orbit already meets its goal. A durable intent binds automatic recovery
// to this burn across reboots. Legacy acceptance is an explicit operator
// command: it accepts the current safe Kerbin orbit as its baseline.
GLOBAL FUNCTION reentryPeRecover {
    PARAMETER targetPe.
    PARAMETER peLow.
    PARAMETER peHigh.
    PARAMETER allowLegacy IS FALSE.
    IF ABORT OR stateGet("phase","") <> "AEROBRAKE"
            OR NOT maneuverBurnInterrupted()
            OR stateGet("burn_body","") <> SHIP:BODY:NAME
            OR stateGet("burn_abort_reason","") <> "residual-outside-tolerance"
            OR NOT (stateGetNum("burn_abort_residual",-1) >= 0
                AND stateGetNum("burn_abort_residual",-1) <= 0.05
                AND stateGetNum("burn_dv",-1) > 0.05
                AND stateGetNum("burn_dv",-1) <= 20
                AND stateGetNum("burn_node_time",-1) > 0)
            OR NOT SHIP:BODY:ATM:EXISTS OR SHIP:ORBIT:HASNEXTPATCH
            OR NOT (SHIP:ALTITUDE > SHIP:BODY:ATM:HEIGHT
                AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
                AND targetPe >= peLow AND targetPe <= peHigh
                AND peLow > 0 AND peHigh < SHIP:BODY:ATM:HEIGHT
                AND ABS(SHIP:PERIAPSIS-targetPe) <= 500
                AND SHIP:PERIAPSIS >= peLow AND SHIP:PERIAPSIS <= peHigh
                AND SHIP:APOAPSIS > SHIP:BODY:ATM:HEIGHT
                AND SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
                AND SHIP:CONTROL:MAINTHROTTLE <= 0
                AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) { RETURN FALSE. }
    LOCAL report IS stateGet("last_burn_report","").
    IF NOT (report:CONTAINS("cutoffFault=residual-outside-tolerance")
            AND report:CONTAINS("shutdownAttempted=False")
            AND report:CONTAINS("thrustStopped=True")
            AND (report:CONTAINS("reason=live-thrust-axis-trim")
                OR report:CONTAINS("reason=live-node-trim"))) { RETURN FALSE. }
    IF HASNODE {
        IF ABS(NEXTNODE:TIME-stateGetNum("burn_node_time",-1)) >= 0.5
                OR NOT (NEXTNODE:DELTAV:MAG >= 0 AND NEXTNODE:DELTAV:MAG <= 0.05) {
            RETURN FALSE.
        }
    }
    LOCAL intent IS stateGet("reentry_pe_intent",LEXICON()).
    IF intent:LENGTH > 0 {
        FOR field IN LIST("mission","launch","phase","body","nodeUt",
                "targetPe","peLow","peHigh","startAp","startInc") {
            IF NOT intent:HASKEY(field) { RETURN FALSE. }
        }
        IF intent["mission"] <> stateGet("mission_id","")
                OR intent["launch"] <> stateGetNum("launch_time",-1)
                OR intent["phase"] <> stateGet("phase","")
                OR intent["body"] <> SHIP:BODY:NAME
                OR ABS(intent["nodeUt"]-stateGetNum("burn_node_time",-1)) >= 0.5
                OR intent["targetPe"] <> targetPe
                OR intent["peLow"] <> peLow OR intent["peHigh"] <> peHigh
                OR NOT (ABS(SHIP:APOAPSIS-intent["startAp"]) <= 100
                    AND ABS(SHIP:ORBIT:INCLINATION-intent["startInc"]) <= 0.1) {
            RETURN FALSE.
        }
    } ELSE {
        IF NOT allowLegacy OR SHIP:BODY:NAME <> "Kerbin" { RETURN FALSE. }
    }
    IF NOT thrustCutoffOk() { RETURN FALSE. }
    stateSet("reentry_pe_reconciled",LEXICON("ut",TIME:SECONDS,
        "nodeUt",stateGetNum("burn_node_time",-1),
        "residual",stateGetNum("burn_abort_residual",-1),
        "Pe",SHIP:PERIAPSIS,"Ap",SHIP:APOAPSIS,"legacy",intent:LENGTH = 0)).
    maneuverAcceptHandoff().
    stateRemove("reentry_pe_intent").
    stateRemove("aerobrake_entry_only").
    mLogWarn("STATS reentry-pe status=reconciled nativePe=" + SHIP:PERIAPSIS
        + " nativeAp=" + SHIP:APOAPSIS + " legacy=" + (intent:LENGTH = 0)).
    RETURN TRUE.
}

GLOBAL FUNCTION reentryPeNodeOk {
    PARAMETER nd.
    PARAMETER desiredPe.
    PARAMETER peLow.
    PARAMETER peHigh.
    RETURN nd:TIME > TIME:SECONDS+30 AND nd:DELTAV:MAG > 0.05
        AND nd:DELTAV:MAG <= 20
        AND MIN(SHIP:DELTAV:VACUUM,STAGE:DELTAV:VACUUM) >= nd:DELTAV:MAG+0.5
        AND ABS(nd:ORBIT:PERIAPSIS-desiredPe) <= 250
        AND nd:ORBIT:PERIAPSIS >= peLow AND nd:ORBIT:PERIAPSIS <= peHigh
        AND ABS(nd:ORBIT:APOAPSIS-SHIP:APOAPSIS) <= 100
        AND ABS(nd:ORBIT:INCLINATION-SHIP:ORBIT:INCLINATION) <= 0.01
        AND ABS(nd:RADIALOUT) < 0.000001 AND ABS(nd:NORMAL) < 0.000001.
}

GLOBAL FUNCTION restoreEntryPe {
    PARAMETER targetPe.
    PARAMETER peLow.
    PARAMETER peHigh.
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    LOCAL result IS LEXICON("OK",FALSE,"BURNED",FALSE,"REASON","invalid-context").
    IF ABORT OR HASNODE OR maneuverBurnInterrupted()
            OR SHIP:ORBIT:HASNEXTPATCH
            OR NOT SHIP:BODY:ATM:EXISTS
            OR NOT (SHIP:ALTITUDE > SHIP:BODY:ATM:HEIGHT
                AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
                AND SHIP:PERIAPSIS > 0 AND SHIP:APOAPSIS > SHIP:BODY:ATM:HEIGHT
                AND VDOT(SHIP:POSITION-SHIP:BODY:POSITION,SHIP:VELOCITY:ORBIT) > 0
                AND ETA:APOAPSIS > 30 AND ETA:APOAPSIS < 1e30
                AND targetPe >= peLow AND targetPe <= peHigh
                AND peLow > 0 AND peHigh < SHIP:BODY:ATM:HEIGHT) { RETURN result. }
    IF ABS(SHIP:PERIAPSIS-targetPe) <= 250 {
        RETURN LEXICON("OK",TRUE,"BURNED",FALSE,"REASON","within-tolerance").
    }
    LOCAL available IS MIN(SHIP:DELTAV:VACUUM,STAGE:DELTAV:VACUUM).
    IF NOT (available > 0.5 AND available < 1e30) {
        SET result["REASON"] TO "insufficient-fuel". RETURN result.
    }
    IF NOT thrustCutoffOk() { SET result["REASON"] TO "cutoff-failed". RETURN result. }
    LOCAL startInc IS SHIP:ORBIT:INCLINATION.
    LOCAL startAp IS SHIP:APOAPSIS.
    LOCAL nd IS planLowerPe(targetPe).
    IF NOT reentryPeNodeOk(nd,targetPe,peLow,peHigh) {
        SET result["REASON"] TO "native-node-rejected".
        IF nd:DELTAV:MAG+0.5 > available { SET result["REASON"] TO "insufficient-fuel". }
        IF nd:DELTAV:MAG <= 0.05 AND SHIP:PERIAPSIS >= peLow AND SHIP:PERIAPSIS <= peHigh {
            SET result["OK"] TO TRUE. SET result["REASON"] TO "below-execution-minimum".
        }
        mLogWarn("STATS reentry-pe status=rejected reason=" + result["REASON"]
            + " nativePe=" + nd:ORBIT:PERIAPSIS + " nativeAp=" + nd:ORBIT:APOAPSIS
            + " dv=" + nd:DELTAV:MAG).
        REMOVE nd. RETURN result.
    }
    mLog("STATS reentry-pe status=planned startPe=" + SHIP:PERIAPSIS
        + " startAp=" + SHIP:APOAPSIS + " targetPe=" + targetPe
        + " dv=" + nd:DELTAV:MAG + " nodeUt=" + nd:TIME).
    LOCAL oldAbs IS BURN_TRIM_ABS_COMPLETE_DV.
    LOCAL oldMax IS BURN_TRIM_COMPLETE_MAX_DV.
    LOCAL trimLimit IS reentryPeTrimLimit(targetPe).
    stateSet("reentry_pe_intent",LEXICON("mission",stateGet("mission_id",""),
        "launch",stateGetNum("launch_time",-1),"phase",stateGet("phase",""),
        "body",SHIP:BODY:NAME,"nodeUt",nd:TIME,"targetPe",targetPe,
        "peLow",peLow,"peHigh",peHigh,"startAp",SHIP:APOAPSIS,"startInc",startInc)).
    SET BURN_TRIM_ABS_COMPLETE_DV TO trimLimit.
    SET BURN_TRIM_COMPLETE_MAX_DV TO trimLimit.
    LOCAL success IS executeManeuver().
    SET BURN_TRIM_ABS_COMPLETE_DV TO oldAbs.
    SET BURN_TRIM_COMPLETE_MAX_DV TO oldMax.
    LOCAL stopped IS thrustCutoffOk().
    SET result["REASON"] TO "burn-failed-inspect-retained-node".
    IF stopped AND NOT success { SET success TO reentryPeRecover(targetPe,peLow,peHigh). }
    IF NOT stopped OR NOT success { RETURN result. }
    stateRemove("reentry_pe_intent").
    SET result["BURNED"] TO TRUE.
    SET result["OK"] TO ABS(SHIP:PERIAPSIS-targetPe) <= 500
        AND SHIP:PERIAPSIS >= peLow AND SHIP:PERIAPSIS <= peHigh
        AND ABS(SHIP:APOAPSIS-startAp) <= 100
        AND ABS(SHIP:ORBIT:INCLINATION-startInc) <= 0.1.
    SET result["REASON"] TO "flown-outside-corridor".
    IF result["OK"] { SET result["REASON"] TO "restored". }
    mLog("STATS reentry-pe status=flown reason=" + result["REASON"]
        + " Pe=" + SHIP:PERIAPSIS + " Ap=" + SHIP:APOAPSIS + " targetPe=" + targetPe).
    RETURN result.
}
