// ============================================================
// payload_ops.ks  —  Shared payload phase implementations
// (0:/lib/payload_ops.ks)
// ============================================================

LOCAL FUNCTION _payloadSeq {
    RETURN launchSeq.
}

GLOBAL FUNCTION phaseTargetedDeorbit {
    LOCAL targetInfo IS targetResolveDeorbitTarget().
    IF targetInfo["FOUND"] {
        mLog("STATS probe target source=" + targetInfo["SOURCE"]
            + " lat=" + ROUND(targetInfo["LAT"],4)
            + " lng=" + ROUND(targetInfo["LNG"],4)).
        IF NOT targetReachable(targetInfo["LAT"]) {
            mLogWarn("Target lat=" + targetInfo["LAT"]
                + " not reachable from inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
                + "deg — proceeding with best effort.").
        }
    }
    targetedDeorbit().
    nextPhase(_payloadSeq()).
}

GLOBAL FUNCTION phaseReleaseProbe {
    LOCAL parts IS SHIP:PARTSTAGGED("probe_decoupler").
    IF parts:LENGTH = 0 {
        mLogError("No part tagged 'probe_decoupler' — cannot release probe.").
        HUDTEXT("ERROR: probe_decoupler missing!", 10, 2, 18, RED, FALSE).
        RETURN.
    }

    IF hasFixedPanels(parts[0]) {
        mLog("Fixed solar panels detected — orienting sunward.").
        HUDTEXT("Orienting for solar panels...", 3, 2, 13, CYAN, FALSE).
        LOCK sunDir TO (SUN:POSITION - SHIP:POSITION):NORMALIZED.
        SET SAS TO FALSE.
        LOCK STEERING TO sunDir.
        LOCAL alignDeadline IS TIME:SECONDS + 60.
        WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, sunDir) < 5
            OR TIME:SECONDS > alignDeadline.
        mLog("Sun angle: " + ROUND(VANG(SHIP:FACING:FOREVECTOR, sunDir), 1) + "deg.").
        WAIT 2.
        UNLOCK STEERING.
        UNLOCK sunDir.
    }

    SET SAS TO TRUE.
    WAIT 1.

    LOCAL lChutes IS SHIP:PARTSTAGGED("probe_chute").
    IF lChutes:LENGTH > 0 {
        FOR c IN lChutes {
            IF c:HASMODULE("ModuleParachute") {
                LOCAL modu IS c:GETMODULE("ModuleParachute").
                IF modu:HASEVENT("Arm Parachute") {
                    modu:DOEVENT("Arm Parachute").
                    mLog("Probe chute armed.").
                } ELSE IF modu:HASEVENT("Deploy") {
                    modu:DOEVENT("Deploy").
                    mLog("Probe chute deployed/armed.").
                }
            }
        }
    } ELSE {
        mLogWarn("No parts tagged 'probe_chute' — trying AG5.").
        AG5 ON.
    }

    WAIT 0.2.

    LOCAL dc IS parts[0].
    IF dc:HASMODULE("ModuleDecouple") {
        dc:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF dc:HASMODULE("ModuleAnchoredDecoupler") {
        dc:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogError("probe_decoupler has no recognized decouple module.").
        RETURN.
    }
    WAIT 0.5.

    stateSet("probe_released_time", TIME:SECONDS).
    mLog("Probe released. Relay mass: " + ROUND(SHIP:MASS,2) + "t.").
    nextPhase(_payloadSeq()).
}

GLOBAL FUNCTION phaseRelayOps {
    UNLOCK STEERING.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    SET SAS TO TRUE.
    orbitSummary().
    orientForSolar().
    mLog("Relay on station at " + getTarget() + ".").
    HUDTEXT("Relay deployed: " + getTarget(), 8, 2, 18, GREEN, FALSE).
    LOCAL n IS 0.
    UNTIL n >= 5 { WAIT 60. orbitSummary(). SET n TO n + 1. }
    nextPhase(_payloadSeq()).
}

GLOBAL FUNCTION phaseLandDeorbit {
    LOCAL deorbitOk IS landingTargetedDeorbit().
    IF NOT deorbitOk {
        mLogError("Landing deorbit did not meet target tolerance; holding phase.").
        stateSet("phase", "LAND_DEORBIT").
        WAIT UNTIL FALSE.
    }
    nextPhase(_payloadSeq()).
}

GLOBAL FUNCTION phaseLandAssist {
    landingAssistStage().
    nextPhase(_payloadSeq()).
}

GLOBAL FUNCTION phaseLand {
    landExecute().
    nextPhase(_payloadSeq()).
}
