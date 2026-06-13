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
    orientForSolar().
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

    LOCAL tag IS "scansat_decoupler".
    IF CFG:HASKEY("SCANSAT_DECOUPLER_TAG") { SET tag TO CFG["SCANSAT_DECOUPLER_TAG"]. }

    IF stateGet("scansat_recovered", "false") = "true" {
        scienceStartScanners().
        WAIT 1.
        scienceScanStatus().
        IF _scanSatAutoDeorbitEnabled() {
            _scanSatMapThenDeorbit().
            RETURN.
        }
        _scanSatOnStation().
        nextPhase(_payloadSeq()).
        RETURN.
    }

    IF stateGet("scansat_released_time", "") <> "" {
        // Resume after a mid-SCANSAT_OPS crash. Orbit correction is not
        // available in this band (maneuver.ks doesn't fit on an OCTO).
        // RAISE/INCLINE should have delivered the correct orbit before this
        // phase ran; if they did not, log it and continue anyway.
        mLogWarn("STATS scansat-ops resume PeKm="
            + ROUND(SHIP:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
        stateSet("scansat_recovered", "true").
        scienceStartScanners().
        WAIT 1.
        scienceScanStatus().
        IF _scanSatAutoDeorbitEnabled() {
            _scanSatMapThenDeorbit().
            RETURN.
        }
        _scanSatOnStation().
        nextPhase(_payloadSeq()).
        RETURN.
    }

    scienceStartScanners().
    WAIT 1.
    scienceScanStatus().
    // Sun-point before any release so the mapper separates with
    // its best measured solar attitude already set.
    orientForSolar().

    IF tag <> "" AND SHIP:PARTSTAGGED(tag):LENGTH = 0 {
        mLogWarn("SCANsat decoupler tag '" + tag
            + "' missing in ops; assuming payload was already released.").
        stateSet("scansat_released_time", TIME:SECONDS).
        stateSet("scansat_recovered", "true").
        scienceStartScanners().
        WAIT 1.
        scienceScanStatus().
        IF _scanSatAutoDeorbitEnabled() {
            _scanSatMapThenDeorbit().
            RETURN.
        }
        _scanSatOnStation().
        nextPhase(_payloadSeq()).
        RETURN.
    }

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
    } ELSE IF _scanSatAutoDeorbitEnabled() {
        _scanSatMapThenDeorbit().
        RETURN.
    } ELSE {
        // The CPU stays with the mapper: hold station.
        _scanSatOnStation().
    }

    nextPhase(_payloadSeq()).
}

// On-station: hold the best measured solar attitude, then — when
// SCANSAT_POWER_GUARD is set — duty-cycle the scanners on
// battery state (AmpYear's tiers proved too blunt for this).
LOCAL FUNCTION _scanSatOnStation {
    orientForSolar().
    IF CFG:HASKEY("SCANSAT_POWER_GUARD")
            AND CFG["SCANSAT_POWER_GUARD"] > 0 {
        scansatDutyCycle().
    }
}

LOCAL FUNCTION _scanSatAutoDeorbitEnabled {
    RETURN CFG:HASKEY("SCANSAT_AUTO_DEORBIT")
        AND CFG["SCANSAT_AUTO_DEORBIT"] > 0.
}

LOCAL FUNCTION _scanSatRequiredTypes {
    LOCAL raw IS "LOW_RES_ALTIMETRY,LOW_RES_RESOURCES,BIOME".
    IF CFG:HASKEY("SCANSAT_REQUIRED_TYPES") {
        SET raw TO CFG["SCANSAT_REQUIRED_TYPES"].
    }
    LOCAL out IS LIST().
    FOR item IN raw:SPLIT(",") {
        LOCAL trimmed IS item:TRIM.
        IF trimmed <> "" { out:ADD(trimmed). }
    }
    RETURN out.
}

LOCAL FUNCTION _scanSatTypeMatches {
    PARAMETER scanType.
    PARAMETER requiredType.
    LOCAL t IS scanType:TOLOWER.
    LOCAL r IS requiredType:TOLOWER.
    IF t = r { RETURN TRUE. }
    IF r:CONTAINS("alt") {
        RETURN t:CONTAINS("alt")
            AND (t:CONTAINS("low") OR t:CONTAINS("lo")).
    }
    IF r:CONTAINS("resource") {
        RETURN t:CONTAINS("resource")
            AND (t:CONTAINS("low") OR t:CONTAINS("lo")).
    }
    IF r:CONTAINS("biome") {
        RETURN t:CONTAINS("biome").
    }
    RETURN t:CONTAINS(r).
}

LOCAL FUNCTION _scanSatCoverageFor {
    PARAMETER coverage.
    PARAMETER requiredType.
    LOCAL best IS -1.
    FOR scanType IN coverage:KEYS {
        IF _scanSatTypeMatches(scanType, requiredType) {
            SET best TO MAX(best, coverage[scanType]).
        }
    }
    RETURN best.
}

LOCAL FUNCTION _scanSatMapDone {
    PARAMETER requiredTypes.
    PARAMETER targetCoverage.
    LOCAL coverage IS scienceScanCoverage().
    LOCAL done IS TRUE.
    LOCAL line IS "".
    FOR requiredType IN requiredTypes {
        LOCAL pct IS _scanSatCoverageFor(coverage, requiredType).
        SET line TO line + requiredType + "=".
        IF pct < 0 {
            SET line TO line + "missing ".
            SET done TO FALSE.
        } ELSE {
            SET line TO line + ROUND(pct, 1) + "% ".
            IF pct < targetCoverage { SET done TO FALSE. }
        }
    }
    mLogWarn("STATS scansat required-coverage target="
        + ROUND(targetCoverage, 1) + " " + line:TRIM).
    RETURN done.
}

LOCAL FUNCTION _scanSatWaitForRequiredCoverage {
    LOCAL targetCoverage IS 99.
    IF CFG:HASKEY("SCANSAT_TARGET_COVERAGE") {
        SET targetCoverage TO CFG["SCANSAT_TARGET_COVERAGE"].
    }
    LOCAL requiredTypes IS _scanSatRequiredTypes().

    mLog("SCANsat mapping until required coverage >= "
        + ROUND(targetCoverage, 1) + "% for "
        + requiredTypes:JOIN(", ") + ".").
    HUDTEXT("SCANsat mapping to " + ROUND(targetCoverage, 1) + "%",
        8, 2, 15, GREEN, FALSE).

    LOCAL lowFrac IS 0.30.
    LOCAL resumeFrac IS 0.60.
    IF CFG:HASKEY("SCANSAT_POWER_LOW") { SET lowFrac TO CFG["SCANSAT_POWER_LOW"]. }
    IF CFG:HASKEY("SCANSAT_POWER_RESUME") { SET resumeFrac TO CFG["SCANSAT_POWER_RESUME"]. }

    scienceStartScanners().
    LOCAL scansOn IS TRUE.
    orientForSolar().
    LOCAL lastOrient IS TIME:SECONDS.
    LOCAL reorientPeriod IS 43200.
    IF CFG:HASKEY("SOLAR_REORIENT_PERIOD") {
        SET reorientPeriod TO CFG["SOLAR_REORIENT_PERIOD"].
    }
    LOCAL nextStatus IS 0.
    LOCAL done IS FALSE.

    UNTIL done OR AG10
            OR stateGet("scansat_deorbit_requested", "false") = "true" {
        LOCAL frac IS shipPowerFraction().
        IF scansOn AND frac < lowFrac {
            scienceStopScanners().
            SET scansOn TO FALSE.
            mLog("SCANsat scans off for charging at "
                + ROUND(frac * 100, 0) + "% EC.").
        } ELSE IF NOT scansOn AND frac > resumeFrac {
            orientForSolar().
            SET lastOrient TO TIME:SECONDS.
            scienceStartScanners().
            SET scansOn TO TRUE.
            mLog("SCANsat scans resumed at "
                + ROUND(frac * 100, 0) + "% EC.").
        }

        IF TIME:SECONDS - lastOrient > reorientPeriod {
            orientForSolar().
            SET lastOrient TO TIME:SECONDS.
        }

        IF TIME:SECONDS >= nextStatus {
            SET nextStatus TO TIME:SECONDS + 600.
            scienceScanStatus().
            SET done TO _scanSatMapDone(requiredTypes, targetCoverage).
        }
        WAIT 30.
    }

    IF AG10 {
        mLogWarn("SCANsat mapping wait paused by AG10 before required coverage.").
        scienceStartScanners().
        yieldToPrompt().
        RETURN FALSE.
    }
    IF stateGet("scansat_deorbit_requested", "false") = "true" {
        mLogWarn("SCANsat deorbit override requested before required coverage.").
        scienceStopScanners().
        RETURN TRUE.
    }
    mLog("SCANsat required coverage complete.").
    scienceStopScanners().
    RETURN TRUE.
}

LOCAL FUNCTION _scanSatSelfDeorbit {
    LOCAL targetPe IS 30000.
    IF CFG:HASKEY("SCANSAT_DEORBIT_PE") {
        SET targetPe TO CFG["SCANSAT_DEORBIT_PE"].
    }
    IF SHIP:PERIAPSIS < targetPe {
        mLog("SCANsat already on impact trajectory; Pe="
            + ROUND(SHIP:PERIAPSIS / 1000, 1) + "km.").
        stateSet("scansat_deorbit_complete", "true").
        WAIT UNTIL FALSE.
        RETURN.
    }

    mLogWarn("STATS scansat-self-deorbit setup PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " availThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).

    IF SHIP:AVAILABLETHRUST <= 0 {
        mLogError("SCANsat cannot self-deorbit: no available thrust.").
        yieldToPrompt().
        RETURN.
    }

    SET SAS TO FALSE.
    LOCK STEERING TO RETROGRADE.
    LOCAL startT IS TIME:SECONDS.
    UNTIL VANG(SHIP:FACING:FOREVECTOR, SHIP:RETROGRADE:FOREVECTOR) < 5
            OR TIME:SECONDS - startT > 60 {
        WAIT 0.1.
    }

    LOCK THROTTLE TO 1.
    LOCAL maxTime IS 600.
    IF CFG:HASKEY("SCANSAT_DEORBIT_MAX_TIME") {
        SET maxTime TO CFG["SCANSAT_DEORBIT_MAX_TIME"].
    }
    UNTIL SHIP:PERIAPSIS < targetPe
            OR SHIP:AVAILABLETHRUST <= 0
            OR TIME:SECONDS - startT > maxTime {
        LOCK STEERING TO RETROGRADE.
        WAIT 0.1.
    }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    LOCAL status_ IS "complete".
    IF SHIP:PERIAPSIS >= targetPe AND SHIP:AVAILABLETHRUST <= 0 {
        SET status_ TO "out-of-thrust".
    } ELSE IF SHIP:PERIAPSIS >= targetPe {
        SET status_ TO "timeout".
    }
    mLogWarn("STATS scansat-self-deorbit result status=" + status_
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " durationS=" + ROUND(TIME:SECONDS - startT,1)).

    stateSet("scansat_deorbit_complete", "true").
    mLog("SCANsat self-deorbit complete. Idling until impact/reentry.").
    WAIT UNTIL FALSE.
}

LOCAL FUNCTION _scanSatMapThenDeorbit {
    IF _scanSatWaitForRequiredCoverage() {
        _scanSatSelfDeorbit().
    }
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

    LOCAL status_ IS "complete".
    IF SHIP:PERIAPSIS >= targetPe AND SHIP:AVAILABLETHRUST <= 0 {
        SET status_ TO "out-of-thrust".
    } ELSE IF SHIP:PERIAPSIS >= targetPe {
        SET status_ TO "timeout".
    }
    mLogWarn("STATS scansat-dispose result status=" + status_
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

    stateSet("scansat_recovered", "true").
    mLogWarn("SCANsat released. Orbit correction not available in this band.").
    RETURN TRUE.
}
