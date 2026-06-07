// ============================================================
// payload_ops.ks  —  Shared payload phase implementations
// (0:/lib/payload_ops.ks)
// ============================================================

LOCAL FUNCTION _payloadSeq {
    IF DEFINED fr3Seq { RETURN fr3Seq. }
    RETURN launchSeq.
}

GLOBAL FUNCTION phaseTargetedDeorbit {
    LOCAL targetInfo IS targetResolveDeorbitTarget().
    IF targetInfo["FOUND"] {
        mLogWarn("STATS probe target source=" + targetInfo["SOURCE"]
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
    mLog("Relay on station at " + MISSION["target"] + ".").
    HUDTEXT("Relay deployed: " + MISSION["target"], 8, 2, 18, GREEN, FALSE).
    LOCAL n IS 0.
    UNTIL n >= 5 { WAIT 60. orbitSummary(). SET n TO n + 1. }
    nextPhase(_payloadSeq()).
}

GLOBAL FUNCTION phaseScanSatOps {
    UNLOCK STEERING.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    SET SAS TO TRUE.

    orbitSummary().
    mLog("SCANsat payload on station at " + MISSION["target"] + ".").
    scienceStartScanners().
    WAIT 1.
    scienceScanStatus().

    LOCAL tag IS "scansat_decoupler".
    IF CFG:HASKEY("SCANSAT_DECOUPLER_TAG") { SET tag TO CFG["SCANSAT_DECOUPLER_TAG"]. }
    IF tag <> "" {
        LOCAL released IS _releaseTaggedPayload(tag, "SCANsat").
        IF NOT released {
            mLogError("SCANsat release failed — tag '" + tag
                + "' missing or not decouplable.").
            HUDTEXT("ERROR: SCANsat not released", 8, 2, 16, RED, FALSE).
            RETURN.
        }
    } ELSE {
        mLogWarn("SCANSAT_DECOUPLER_TAG blank — leaving mapper attached.").
    }

    stateSet("scansat_released_time", TIME:SECONDS).
    mLog("SCANsat deployed. Continuing primary mission.").
    HUDTEXT("SCANsat deployed", 5, 2, 16, GREEN, FALSE).

    IF CFG:HASKEY("SCANSAT_DISPOSE_CARRIER")
            AND CFG["SCANSAT_DISPOSE_CARRIER"] > 0 {
        _disposeScanSatCarrier().
    }

    nextPhase(_payloadSeq()).
}

GLOBAL FUNCTION phaseLandDeorbit {
    landingTargetedDeorbit().
    nextPhase(_payloadSeq()).
}

GLOBAL FUNCTION phaseLandAssist {
    landingAssistStage().
    nextPhase(_payloadSeq()).
}

GLOBAL FUNCTION phaseLand {
    landingExecute().
    nextPhase(_payloadSeq()).
}

LOCAL FUNCTION _releaseTaggedPayload {
    PARAMETER tagName.
    PARAMETER label.

    LOCAL parts IS SHIP:PARTSTAGGED(tagName).
    IF parts:LENGTH = 0 { RETURN FALSE. }

    LOCAL dc IS parts[0].
    IF dc:HASMODULE("ModuleDecouple") {
        dc:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF dc:HASMODULE("ModuleAnchoredDecoupler") {
        dc:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        RETURN FALSE.
    }

    WAIT 0.5.
    mLog(label + " released via '" + tagName + "'. Remaining mass: "
        + ROUND(SHIP:MASS,2) + "t.").
    RETURN TRUE.
}

LOCAL FUNCTION _disposeScanSatCarrier {
    LOCAL targetPe IS 0.
    IF CFG:HASKEY("SCANSAT_DISPOSE_PE") {
        SET targetPe TO CFG["SCANSAT_DISPOSE_PE"].
    }
    LOCAL maxTime IS 600.
    IF CFG:HASKEY("SCANSAT_DISPOSE_MAX_TIME") {
        SET maxTime TO CFG["SCANSAT_DISPOSE_MAX_TIME"].
    }

    WAIT 1.
    mLogWarn("STATS scansat-dispose setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " availThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).

    IF SHIP:AVAILABLETHRUST <= 0 {
        mLogWarn("STATS scansat-dispose result status=no-thrust PeKm="
            + ROUND(SHIP:PERIAPSIS/1000,1)).
        RETURN.
    }

    SET SAS TO FALSE.
    LOCK STEERING TO SHIP:RETROGRADE.
    LOCAL startT IS TIME:SECONDS.
    LOCAL aligned IS FALSE.
    UNTIL aligned OR TIME:SECONDS - startT > 45 {
        IF VANG(SHIP:FACING:FOREVECTOR, SHIP:RETROGRADE:FOREVECTOR) < 5 {
            SET aligned TO TRUE.
        }
        WAIT 0.1.
    }

    IF NOT aligned {
        mLogWarn("SCANsat carrier disposal starting with poor retrograde alignment.").
    }

    LOCK THROTTLE TO 1.
    UNTIL SHIP:PERIAPSIS < targetPe
            OR SHIP:AVAILABLETHRUST <= 0
            OR TIME:SECONDS - startT > maxTime {
        LOCK STEERING TO SHIP:RETROGRADE.
        WAIT 0.1.
    }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    LOCAL status IS "complete".
    IF SHIP:PERIAPSIS >= targetPe AND SHIP:AVAILABLETHRUST <= 0 {
        SET status TO "out-of-thrust".
    } ELSE IF SHIP:PERIAPSIS >= targetPe {
        SET status TO "timeout".
    }
    mLogWarn("STATS scansat-dispose result status=" + status
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " duration=" + ROUND(TIME:SECONDS - startT,1)).
}
