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
    IF stateGet("scansat_recovered", "false") = "true" {
        scienceStartScanners().
        WAIT 1.
        scienceScanStatus().
        nextPhase(_payloadSeq()).
        RETURN.
    }

    scienceStartScanners().
    WAIT 1.
    scienceScanStatus().

    LOCAL tag IS "scansat_decoupler".
    IF CFG:HASKEY("SCANSAT_DECOUPLER_TAG") { SET tag TO CFG["SCANSAT_DECOUPLER_TAG"]. }

    IF CFG:HASKEY("SCANSAT_DISPOSE_BEFORE_RELEASE")
            AND CFG["SCANSAT_DISPOSE_BEFORE_RELEASE"] > 0 {
        IF NOT _scanSatImpactThenRecover(tag) { RETURN. }
        nextPhase(_payloadSeq()).
        RETURN.
    }

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

LOCAL FUNCTION _scanSatImpactThenRecover {
    PARAMETER tag.

    LOCAL impactPe IS 2000.
    IF CFG:HASKEY("SCANSAT_DISPOSE_PE") { SET impactPe TO CFG["SCANSAT_DISPOSE_PE"]. }

    LOCAL recoveryPe IS 75000.
    LOCAL recoveryAp IS 75000.
    IF CFG:HASKEY("SCANSAT_RECOVERY_PE") { SET recoveryPe TO CFG["SCANSAT_RECOVERY_PE"]. }
    ELSE IF CFG:HASKEY("TARGET_PE") { SET recoveryPe TO CFG["TARGET_PE"]. }
    IF CFG:HASKEY("SCANSAT_RECOVERY_AP") { SET recoveryAp TO CFG["SCANSAT_RECOVERY_AP"]. }
    ELSE IF CFG:HASKEY("TARGET_AP") { SET recoveryAp TO CFG["TARGET_AP"]. }

    mLogWarn("STATS scansat-impact-release setup PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " impactPeKm=" + ROUND(impactPe/1000,1)
        + " recoveryPeKm=" + ROUND(recoveryPe/1000,1)
        + " recoveryApKm=" + ROUND(recoveryAp/1000,1)).

    _disposeScanSatCarrier().

    IF SHIP:PERIAPSIS > impactPe {
        mLogWarn("SCANsat attached disposal did not reach impact Pe; continuing recovery sequence anyway.").
    }

    IF tag <> "" {
        LOCAL released IS _releaseTaggedPayload(tag, "SCANsat").
        IF NOT released {
            mLogError("SCANsat release failed after impact setup — tag '" + tag
                + "' missing or not decouplable.").
            HUDTEXT("ERROR: SCANsat not released", 8, 2, 16, RED, FALSE).
            RETURN FALSE.
        }
    } ELSE {
        mLogWarn("SCANSAT_DECOUPLER_TAG blank — mapper still attached after disposal burn.").
    }

    stateSet("scansat_released_time", TIME:SECONDS).
    mLogWarn("STATS scansat-release result mass=" + ROUND(SHIP:MASS,3)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    WAIT 0.5.

    IF CFG:HASKEY("SCANSAT_STAGE_AFTER_RELEASE")
            AND CFG["SCANSAT_STAGE_AFTER_RELEASE"] > 0 {
        STAGE.
        mLog("SCANsat staged after release.").
        WAIT 1.
        mLogWarn("STATS scansat-stage result mass=" + ROUND(SHIP:MASS,3)
            + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
            + " availableThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).
    }

    SET SAS TO TRUE.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    WAIT 2.

    IF NOT _scanSatRecoverOrbit(recoveryPe, recoveryAp) { RETURN FALSE. }
    stateSet("scansat_recovered", "true").
    HUDTEXT("SCANsat recovered to mapping orbit", 8, 2, 16, GREEN, FALSE).
    mLog("SCANsat released and recovered to mapping orbit.").
    RETURN TRUE.
}

LOCAL FUNCTION _scanSatRecoverOrbit {
    PARAMETER recoveryPe.
    PARAMETER recoveryAp.

    mLogWarn("STATS scansat-recover setup PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " targetPeKm=" + ROUND(recoveryPe/1000,1)
        + " targetApKm=" + ROUND(recoveryAp/1000,1)).

    LOCAL burnOk IS _scanSatBurn({ RETURN planCircularize(). }, "SCANsat recovery circularize").
    IF NOT burnOk {
        RETURN FALSE.
    }

    IF SHIP:APOAPSIS < recoveryAp * 0.95 {
        SET burnOk TO _scanSatBurn({ RETURN _scanSatPlanRaiseAp(recoveryAp). }, "SCANsat recovery raise Ap").
        IF NOT burnOk {
            RETURN FALSE.
        }
    } ELSE {
        mLog("SCANsat recovery Ap already near target.").
    }

    IF SHIP:PERIAPSIS < recoveryPe * 0.95 {
        SET burnOk TO _scanSatBurn({ RETURN _scanSatPlanRaisePeAtAp(recoveryPe). }, "SCANsat recovery raise Pe").
        IF NOT burnOk {
            RETURN FALSE.
        }
    } ELSE {
        mLog("SCANsat recovery Pe already safe.").
    }

    IF SHIP:ORBIT:ECCENTRICITY > 0.01
            OR ABS(SHIP:APOAPSIS - recoveryAp) > recoveryAp * 0.1 {
        SET burnOk TO _scanSatBurn({ RETURN planCircularize(). }, "SCANsat recovery recircularize").
        IF NOT burnOk {
            RETURN FALSE.
        }
    } ELSE {
        mLog("SCANsat recovery recircularize skipped; orbit already close.").
    }

    orbitSummary().
    mLogWarn("STATS scansat-recover result PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    RETURN TRUE.
}

LOCAL FUNCTION _scanSatBurn {
    PARAMETER planFn.
    PARAMETER label.

    LOCAL success IS FALSE.
    LOCAL tries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planFn:CALL().
        WAIT 1.
        mLogWarn("STATS scansat-burn setup label=" + label
            + " dv=" + ROUND(NEXTNODE:DELTAV:MAG,1)
            + " eta=" + ROUND(NEXTNODE:ETA,1)).
        SET success TO executeManeuver().
        IF NOT success {
            SET tries TO tries + 1.
            mLogWarn("SCANsat burn missed: " + label + " attempt=" + tries + ".").
            IF tries >= 3 {
                mLogError("SCANsat recovery burn failed: " + label + ".").
                RETURN FALSE.
            }
            WAIT 5.
        }
    }
    RETURN TRUE.
}

LOCAL FUNCTION _scanSatPlanRaiseAp {
    PARAMETER targetAp.

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL rBurn IS bodyR + SHIP:PERIAPSIS.
    LOCAL rTarget IS bodyR + targetAp.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, vNew - vNow).
    ADD nd.
    mLog("SCANsat raise Ap node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetAp=" + ROUND(targetAp/1000,1) + "km").
    mLogWarn("STATS scansat-raise-ap plan dv=" + ROUND(nd:DELTAV:MAG,1)
        + " targetApKm=" + ROUND(targetAp/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    archivePlannedManeuverLog("scansat-raise-ap").
    RETURN nd.
}

LOCAL FUNCTION _scanSatPlanRaisePeAtAp {
    PARAMETER targetPe.

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL rBurn IS bodyR + SHIP:APOAPSIS.
    LOCAL rTarget IS bodyR + targetPe.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:APOAPSIS):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(TIME:SECONDS + ETA:APOAPSIS, 0, 0, vNew - vNow).
    ADD nd.
    mLog("SCANsat raise Pe node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPe=" + ROUND(targetPe/1000,1) + "km").
    mLogWarn("STATS scansat-raise-pe plan dv=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    archivePlannedManeuverLog("scansat-raise-pe").
    RETURN nd.
}
