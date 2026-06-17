// ============================================================
// scansat_ops.ks - SCANsat payload phase implementation
// (0:/lib/scansat_ops.ks)
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL SCANSAT_DECOUPLER_TAG IS "".
GLOBAL SCANSAT_DISPOSE_CARRIER IS 0.
GLOBAL SCANSAT_DISPOSE_BEFORE_RELEASE IS 0.
GLOBAL SCANSAT_STAGE_AFTER_RELEASE IS 0.
GLOBAL SCANSAT_DISPOSE_PE IS -1.
GLOBAL SCANSAT_DISPOSE_MAX_TIME IS 600.
GLOBAL SCANSAT_RECOVERY_PE IS -1.
GLOBAL SCANSAT_RECOVERY_AP IS -1.
GLOBAL SCANSAT_AUTO_DEORBIT IS 0.
GLOBAL SCANSAT_DEORBIT_PE IS -1.
GLOBAL SCANSAT_DEORBIT_MAX_TIME IS 600.
GLOBAL SCANSAT_POWER_GUARD IS 0.
GLOBAL SCANSAT_POWER_LOW IS 0.2.
GLOBAL SCANSAT_POWER_RESUME IS 0.5.
GLOBAL SCANSAT_TARGET_COVERAGE IS -1.
GLOBAL SCANSAT_REQUIRED_TYPES IS "".
GLOBAL SOLAR_REORIENT_PERIOD IS 0.

LOCAL FUNCTION _payloadSeq {
    RETURN launchSeq.
}

GLOBAL FUNCTION phaseScanSatOps {
    UNLOCK STEERING.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    SET SAS TO TRUE.

    orbitSummary().
    mLog("SCANsat payload on station at " + getTarget() + ".").

    LOCAL tag IS "scansat_decoupler".
    SET tag TO SCANSAT_DECOUPLER_TAG.

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

    IF SCANSAT_DISPOSE_BEFORE_RELEASE > 0 {
        IF NOT _scanSatImpactThenRecover(tag) { RETURN. }
        nextPhase(_payloadSeq()).
        RETURN.
    }

    IF tag <> "" {
        LOCAL released IS _releaseTaggedPayload(tag, "SCANsat").
        IF NOT released {
            mLogError("SCANsat release failed - tag '" + tag
                + "' missing or not decouplable.").
            HUDTEXT("ERROR: SCANsat not released", 8, 2, 16, RED, FALSE).
            RETURN.
        }
    } ELSE {
        mLogWarn("SCANSAT_DECOUPLER_TAG blank - leaving mapper attached.").
    }

    stateSet("scansat_released_time", TIME:SECONDS).
    mLog("SCANsat deployed. Continuing primary mission.").
    HUDTEXT("SCANsat deployed", 5, 2, 16, GREEN, FALSE).

    IF SCANSAT_DISPOSE_CARRIER > 0 {
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

// On-station: hold the best measured solar attitude, then, when
// SCANSAT_POWER_GUARD is set, duty-cycle the scanners on battery state.
LOCAL FUNCTION _scanSatOnStation {
    orientForSolar().
    IF SCANSAT_POWER_GUARD > 0 {
        scansatDutyCycle().
    }
}

LOCAL FUNCTION _scanSatAutoDeorbitEnabled {
    RETURN SCANSAT_AUTO_DEORBIT > 0
        AND SCANSAT_AUTO_DEORBIT > 0.
}

LOCAL FUNCTION _scanSatRequiredTypes {
    LOCAL raw IS "LOW_RES_ALTIMETRY,LOW_RES_RESOURCES,BIOME".
    IF SCANSAT_REQUIRED_TYPES <> "" {
        SET raw TO SCANSAT_REQUIRED_TYPES.
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
    LOCAL _r IS requiredType:TOLOWER.
    IF t = _r { RETURN TRUE. }
    IF _r:CONTAINS("alt") {
        RETURN t:CONTAINS("alt")
            AND (t:CONTAINS("low") OR t:CONTAINS("lo")).
    }
    IF _r:CONTAINS("resource") {
        RETURN t:CONTAINS("resource")
            AND (t:CONTAINS("low") OR t:CONTAINS("lo")).
    }
    IF _r:CONTAINS("biome") {
        RETURN t:CONTAINS("biome").
    }
    RETURN t:CONTAINS(_r).
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
    IF SCANSAT_TARGET_COVERAGE >= 0 {
        SET targetCoverage TO SCANSAT_TARGET_COVERAGE.
    }
    LOCAL requiredTypes IS _scanSatRequiredTypes().

    mLog("SCANsat mapping until required coverage >= "
        + ROUND(targetCoverage, 1) + "% for "
        + requiredTypes:JOIN(", ") + ".").
    HUDTEXT("SCANsat mapping to " + ROUND(targetCoverage, 1) + "%",
        8, 2, 15, GREEN, FALSE).

    LOCAL lowFrac IS 0.30.
    LOCAL resumeFrac IS 0.60.
    SET lowFrac TO SCANSAT_POWER_LOW.
    SET resumeFrac TO SCANSAT_POWER_RESUME.

    scienceStartScanners().
    LOCAL scansOn IS TRUE.
    orientForSolar().
    LOCAL lastOrient IS TIME:SECONDS.
    LOCAL reorientPeriod IS 43200.
    IF SOLAR_REORIENT_PERIOD > 0 {
        SET reorientPeriod TO SOLAR_REORIENT_PERIOD.
    }
    LOCAL nextStatus IS 0.
    LOCAL done IS FALSE.

    UNTIL done OR stateGet("scansat_deorbit_requested", "false") = "true" {
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
    IF SCANSAT_DEORBIT_PE >= 0 {
        SET targetPe TO SCANSAT_DEORBIT_PE.
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
    IF SCANSAT_DEORBIT_MAX_TIME > 0 {
        SET maxTime TO SCANSAT_DEORBIT_MAX_TIME.
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
    IF SCANSAT_DISPOSE_PE >= 0 {
        SET targetPe TO SCANSAT_DISPOSE_PE.
    }
    LOCAL maxTime IS 600.
    IF SCANSAT_DISPOSE_MAX_TIME > 0 {
        SET maxTime TO SCANSAT_DISPOSE_MAX_TIME.
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

    LOCAL impactPe IS SCANSAT_DISPOSE_PE.
    IF impactPe < 0 { SET impactPe TO 2000. }

    LOCAL recoveryPe IS SCANSAT_RECOVERY_PE.
    LOCAL recoveryAp IS SCANSAT_RECOVERY_AP.
    IF recoveryPe < 0 { SET recoveryPe TO TARGET_PE. }
    IF recoveryPe < 0 { SET recoveryPe TO 75000. }
    IF recoveryAp < 0 { SET recoveryAp TO TARGET_AP. }
    IF recoveryAp < 0 { SET recoveryAp TO 75000. }

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
            mLogError("SCANsat release failed after impact setup - tag '" + tag
                + "' missing or not decouplable.").
            HUDTEXT("ERROR: SCANsat not released", 8, 2, 16, RED, FALSE).
            RETURN FALSE.
        }
    } ELSE {
        mLogWarn("SCANSAT_DECOUPLER_TAG blank - mapper still attached after disposal burn.").
    }

    stateSet("scansat_released_time", TIME:SECONDS).
    mLogWarn("STATS scansat-release result mass=" + ROUND(SHIP:MASS,3)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    WAIT 0.5.

    IF SCANSAT_STAGE_AFTER_RELEASE > 0 {
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
