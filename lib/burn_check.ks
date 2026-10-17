// Archive-only diagnostic; deliberately absent from dependencyLibs.
// The owning executor passes private read-only calculations as delegates.
@LAZYGLOBAL OFF.
PARAMETER accelerationFn.
PARAMETER governorFn.

LOCAL FUNCTION _burnCheckMain {
    PRINT "Burn diagnostics: no ignition, staging, or node changes.".
    PRINT "Saved phase=" + stateGet("phase", "")
        + " status=" + stateGet("burn_status", "")
        + " reason=" + stateGet("burn_abort_reason", "").
    PRINT stateGet("last_burn_report", "No saved cutoff report.").
    PRINT "Controls: suppressAutopilot=" + CONFIG:SUPPRESSAUTOPILOT
        + " IPU=" + CONFIG:IPU + " burnMinIpu=" + BURN_MIN_IPU + " ABORT=" + ABORT
        + " stage=" + STAGE:NUMBER + " ready=" + STAGE:READY.
    PRINT "Hardware: thrust=" + ROUND(SHIP:THRUST,3)
        + " available=" + ROUND(SHIP:AVAILABLETHRUST,3)
        + " usableAcc=" + ROUND(accelerationFn:CALL(),3)
        + " pilotThrottle=" + ROUND(SHIP:CONTROL:PILOTMAINTHROTTLE,3).
    LOCAL processors IS LIST().
    LIST PROCESSORS IN processors.
    FOR processor_ IN processors {
        PRINT "CPU tag='" + processor_:TAG + "' mode=" + processor_:MODE
            + " part=" + processor_:PART:NAME.
    }
    FOR eng IN SHIP:ENGINES {
        PRINT "Engine " + eng:NAME + " stage=" + eng:STAGE
            + " decoupledIn=" + eng:DECOUPLEDIN
            + " ignition=" + eng:IGNITION + " flameout=" + eng:FLAMEOUT
            + " limit=" + ROUND(eng:THRUSTLIMIT,1)
            + " available=" + ROUND(eng:AVAILABLETHRUST,3)
            + " possible=" + ROUND(eng:POSSIBLETHRUST,3).
    }
    IF NOT HASNODE {
        PRINT "No node: retain a planned node to probe the throttle governor.".
        RETURN.
    }
    LOCAL nd IS NEXTNODE.
    LOCAL bdv IS nd:DELTAV:MAG.
    IF bdv <= 0 OR NOT (bdv < 1e30) OR NOT (nd:BURNVECTOR:MAG > 0) {
        PRINT "Invalid or empty node; skipping governor probe.".
        RETURN.
    }
    LOCAL ignitionVec IS nd:BURNVECTOR.
    LOCAL fixed IS bdv <= BURN_FIXED_NODE_MAX_DV
        AND SHIP:ORBIT:ECCENTRICITY >= BURN_FIXED_NODE_MIN_ECC.
    PRINT "Node: dv=" + ROUND(bdv,3) + " eta=" + ROUND(nd:ETA,1)
        + " fixed=" + fixed + " align=" + ROUND(VANG(SHIP:FACING:FOREVECTOR, ignitionVec),1).
    // Fresh local state: these probes cannot latch the real executor's cutoff.
    FOR command IN LIST(0, 1) {
        LOCAL cutoff IS LEX("reason", "", "rem", -1, "time", 0,
            "lastTick", TIME:SECONDS, "tickDt", 0.02, "output", 0,
            "bestRem", -1, "fixed", fixed,
            "heartbeat", TIME:SECONDS, "impulseTime", TIME:SECONDS,
            "impulse", 0, "lastAcc", SHIP:THRUST / MAX(0.01, SHIP:MASS),
            "impulseCap", bdv + MAX(BURN_IMPULSE_MARGIN_DV, bdv * BURN_IMPULSE_MARGIN_FRAC)).
        LOCAL started IS TIME:SECONDS.
        SET cutoff["heartbeat"] TO started.
        LOCAL output IS governorFn:CALL(nd, ignitionVec, command, cutoff).
        LOCAL finished IS TIME:SECONDS.
        PRINT "STATS throttle-probe command=" + command + " output=" + ROUND(output,4)
            + " reason='" + cutoff["reason"] + "' elapsed=" + ROUND(finished - started,3)
            + " heartbeatAge=" + ROUND(finished - cutoff["heartbeat"],3)
            + " watchdogSeconds=" + BURN_COMMAND_TIMEOUT.
    }
}

_burnCheckMain().
