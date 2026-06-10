// ============================================================
// payload_release.ks  —  Payload impact-disposal and release
// (0:/lib/payload_release.ks)
//
// Split out of maneuver_orbit.ks so the XFER_ORBIT band no
// longer carries ~25KB of ScanSat/payload disposal machinery on
// missions that never use it. The DROP_FOR_IMPACT_AND_RAISE_PE
// phase loads this lib as its own band (one extra reboot on the
// missions that DO use it).
//
// phaseDropForImpactAndRaisePe — dispatcher (ScanSat vs generic)
// phaseScanSatImpactRelease    — lower Pe, release mapper, recover
// phasePayloadImpactRelease    — lower Pe, release payload
// ============================================================

LOCAL FUNCTION _bodyImpactFloor {
    LOCAL body_ IS SHIP:ORBIT:BODY.
    IF body_:ATM:EXISTS { RETURN body_:ATM:HEIGHT + 1000. }
    RETURN 5000.
}

GLOBAL FUNCTION phaseDropForImpactAndRaisePe {
    IF CFG:HASKEY("SCANSAT_RELEASE_AFTER_CAPTURE")
            AND CFG["SCANSAT_RELEASE_AFTER_CAPTURE"] > 0 {
        phaseScanSatImpactRelease().
        RETURN.
    }
    phasePayloadImpactRelease().
}

GLOBAL FUNCTION phaseScanSatImpactRelease {
    LOCAL impactPe IS 2000.
    LOCAL recoveryPe IS 75000.
    LOCAL recoveryAp IS 75000.
    LOCAL tag IS "scansat_decoupler".

    IF CFG:HASKEY("SCANSAT_DISPOSE_PE") { SET impactPe TO CFG["SCANSAT_DISPOSE_PE"]. }
    IF CFG:HASKEY("SCANSAT_RECOVERY_PE") { SET recoveryPe TO CFG["SCANSAT_RECOVERY_PE"]. }
    ELSE IF CFG:HASKEY("TARGET_PE") { SET recoveryPe TO CFG["TARGET_PE"]. }
    IF CFG:HASKEY("SCANSAT_RECOVERY_AP") { SET recoveryAp TO CFG["SCANSAT_RECOVERY_AP"]. }
    ELSE IF CFG:HASKEY("TARGET_AP") { SET recoveryAp TO CFG["TARGET_AP"]. }
    IF CFG:HASKEY("SCANSAT_DECOUPLER_TAG") { SET tag TO CFG["SCANSAT_DECOUPLER_TAG"]. }

    mLogWarn("STATS scansat-impact-release setup PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " impactPeKm=" + ROUND(impactPe/1000,1)
        + " recoveryPeKm=" + ROUND(recoveryPe/1000,1)
        + " recoveryApKm=" + ROUND(recoveryAp/1000,1)).

    LOCAL alreadyReleased IS stateGet("scansat_released_time", "") <> "".

    IF NOT alreadyReleased {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        IF NOT _scanSatDisposeAttached(impactPe) {
            _scanSatImpactHalt("disposal burn failed before release").
            RETURN.
        }

        IF tag <> "" {
            IF NOT _releaseTaggedPayloadXfer(tag, "SCANsat") {
                mLogError("SCANsat release failed after impact setup — tag '" + tag
                    + "' missing or not decouplable.").
                HUDTEXT("ERROR: SCANsat not released", 8, 2, 16, RED, FALSE).
                _scanSatImpactHalt("release failed").
                RETURN.
            }
        } ELSE {
            mLogWarn("SCANSAT_DECOUPLER_TAG blank — mapper still attached after impact setup.").
        }

        stateSet("scansat_released_time", TIME:SECONDS).
        mLogWarn("STATS scansat-release result mass=" + ROUND(SHIP:MASS,3)
            + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
        WAIT 0.5.
    } ELSE {
        mLogWarn("SCANsat release already recorded; skipping decoupler search.").
    }

    IF NOT alreadyReleased
            AND CFG:HASKEY("SCANSAT_STAGE_AFTER_RELEASE")
            AND CFG["SCANSAT_STAGE_AFTER_RELEASE"] > 0 {
        STAGE.
        stateSet("scansat_staged", "true").
        mLog("SCANsat staged after release.").
        WAIT 1.
        mLogWarn("STATS scansat-stage result mass=" + ROUND(SHIP:MASS,3)
            + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
            + " availableThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).
    }

    IF NOT alreadyReleased {
        _scanSatClearDisposedStage().
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    IF NOT _scanSatRecoverPeDirect(recoveryPe) {
        _scanSatImpactHalt("direct recovery Pe burn failed").
        RETURN.
    }

    IF SHIP:APOAPSIS < recoveryAp * 0.95 {
        IF NOT _scanSatPlanAndExecuteRaiseAp(recoveryAp) {
            _scanSatImpactHalt("recovery Ap raise failed").
            RETURN.
        }
    }

    IF SHIP:ORBIT:ECCENTRICITY > 0.01
            OR ABS(SHIP:APOAPSIS - recoveryAp) > recoveryAp * 0.1 {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planCircularize().
        IF NOT _executeScanSatStep("SCANsat recovery recircularize") {
            _scanSatImpactHalt("recovery recircularize failed").
            RETURN.
        }
    }

    stateSet("scansat_recovered", "true").
    orbitSummary().
    mLogWarn("STATS scansat-impact-release result PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    nextPhase(xferSeq).
}

LOCAL FUNCTION _scanSatImpactHalt {
    PARAMETER reason.
    mLogError("SCANsat impact/release halted: " + reason + ".").
    stateSet("phase", "DROP_FOR_IMPACT_AND_RAISE_PE").
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    PRINT " ".
    PRINT "  SCANSAT RECOVERY HOLD".
    PRINT "  " + reason.
    PRINT "  Manual mode remains available; reboot/resume after review.".
    RETURN FALSE.
}

GLOBAL FUNCTION phasePayloadImpactRelease {
    LOCAL impactPe IS 2000.
    LOCAL tag IS "probe_decoupler".
    LOCAL label IS "payload".
    IF CFG:HASKEY("PAYLOAD_DISPOSE_PE") { SET impactPe TO CFG["PAYLOAD_DISPOSE_PE"]. }
    ELSE IF CFG:HASKEY("SCANSAT_DISPOSE_PE") { SET impactPe TO CFG["SCANSAT_DISPOSE_PE"]. }
    IF CFG:HASKEY("PAYLOAD_DECOUPLER_TAG") { SET tag TO CFG["PAYLOAD_DECOUPLER_TAG"]. }
    IF CFG:HASKEY("PAYLOAD_LABEL") { SET label TO CFG["PAYLOAD_LABEL"]. }

    mLogWarn("STATS payload-impact-release setup label=" + label
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " impactPeKm=" + ROUND(impactPe/1000,1)
        + " tag=" + tag).

    LOCAL stateKey IS "payload_" + label:TOLOWER + "_released_time".
    LOCAL alreadyReleased IS stateGet(stateKey, "") <> "".

    IF NOT _payloadRecoveryWindowSafe(impactPe, label) {
        _payloadImpactHalt("recovery burn window is after impact").
        RETURN.
    }

    IF NOT alreadyReleased {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        IF NOT _payloadDisposeAttached(impactPe) {
            _payloadImpactHalt("disposal burn failed before release").
            RETURN.
        }

        IF tag <> "" {
            IF NOT _releaseTaggedPayloadXfer(tag, label) {
                mLogError(label + " release failed after impact setup — tag '" + tag
                    + "' missing or not decouplable.").
                HUDTEXT("ERROR: payload not released", 8, 2, 16, RED, FALSE).
                _payloadImpactHalt("release failed").
                RETURN.
            }
        } ELSE {
            mLogWarn("PAYLOAD_DECOUPLER_TAG blank — payload still attached after disposal burn.").
        }

        stateSet(stateKey, TIME:SECONDS).
        mLogWarn("STATS payload-release result label=" + label
            + " mass=" + ROUND(SHIP:MASS,3)
            + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
        WAIT 0.5.
        _payloadClearDisposedStage().
    } ELSE {
        mLogWarn(label + " release already recorded; skipping decoupler search.").
    }

    orbitSummary().
    nextPhase(xferSeq).
}

LOCAL FUNCTION _payloadImpactHalt {
    PARAMETER reason.
    mLogError("Payload impact/release halted: " + reason + ".").
    stateSet("phase", "DROP_FOR_IMPACT_AND_RAISE_PE").
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    PRINT " ".
    PRINT "  PAYLOAD RELEASE HOLD".
    PRINT "  " + reason.
    PRINT "  Manual mode remains available; reboot/resume after review.".
    yieldToPrompt().
    RETURN FALSE.
}

LOCAL FUNCTION _payloadNextPhase {
    LOCAL current IS stateGet("phase", "").
    FROM { LOCAL i IS 0. } UNTIL i >= xferSeq:LENGTH STEP { SET i TO i + 1. } DO {
        IF xferSeq[i] = current {
            IF i + 1 < xferSeq:LENGTH { RETURN xferSeq[i + 1]. }
            RETURN "".
        }
    }
    RETURN "".
}


LOCAL FUNCTION _payloadRecoveryWindowSafe {
    PARAMETER targetPe.
    PARAMETER label.

    LOCAL nextPhase IS _payloadNextPhase().
    LOCAL floorPe IS _bodyImpactFloor().
    LOCAL margin IS 60.
    IF CFG:HASKEY("PAYLOAD_RECOVERY_MARGIN") { SET margin TO CFG["PAYLOAD_RECOVERY_MARGIN"]. }

    IF targetPe >= floorPe AND SHIP:PERIAPSIS >= floorPe {
        RETURN TRUE.
    }
    IF nextPhase <> "ELLIPTICAL" {
        RETURN TRUE.
    }

    LOCAL etaAp IS ETA:APOAPSIS.
    LOCAL etaPe IS ETA:PERIAPSIS.
    LOCAL safe IS etaAp + margin < etaPe.
    LOCAL statusText IS CHOOSE "ok" IF safe ELSE "blocked".
    mLogWarn("STATS payload-impact-release precheck label=" + label
        + " status=" + statusText
        + " reason=recovery-window"
        + " next=" + nextPhase
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " floorPeKm=" + ROUND(floorPe/1000,1)
        + " etaAp=" + ROUND(etaAp,1)
        + " etaPe=" + ROUND(etaPe,1)
        + " margin=" + ROUND(margin,1)).

    RETURN safe.
}

LOCAL FUNCTION _payloadDisposeAttached {
    PARAMETER targetPe.

    LOCAL maxTime IS 600.
    IF CFG:HASKEY("PAYLOAD_DISPOSE_MAX_TIME") { SET maxTime TO CFG["PAYLOAD_DISPOSE_MAX_TIME"]. }
    ELSE IF CFG:HASKEY("SCANSAT_DISPOSE_MAX_TIME") { SET maxTime TO CFG["SCANSAT_DISPOSE_MAX_TIME"]. }

    mLogWarn("STATS payload-dispose setup PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " maxTime=" + ROUND(maxTime,0)
        + " thrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).

    IF SHIP:PERIAPSIS <= targetPe {
        mLog("Payload carrier already on disposal Pe.").
        RETURN TRUE.
    }
    IF SHIP:AVAILABLETHRUST <= 0 {
        mLogWarn("Payload carrier disposal skipped: no available thrust.").
        RETURN FALSE.
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
        mLogWarn("Payload carrier disposal starting with poor retrograde alignment.").
    }

    LOCK THROTTLE TO 1.
    UNTIL SHIP:PERIAPSIS <= targetPe
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
    IF SHIP:PERIAPSIS > targetPe AND SHIP:AVAILABLETHRUST <= 0 {
        SET status_ TO "out-of-thrust".
    } ELSE IF SHIP:PERIAPSIS > targetPe {
        SET status_ TO "timeout".
    }
    mLogWarn("STATS payload-dispose result status=" + status_
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " duration=" + ROUND(TIME:SECONDS - startT,1)).

    IF status_ = "complete" { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _payloadClearDisposedStage {
    LOCAL clearDv IS 2.
    IF CFG:HASKEY("PAYLOAD_CLEARANCE_DV") { SET clearDv TO CFG["PAYLOAD_CLEARANCE_DV"]. }
    IF clearDv <= 0 {
        mLogWarn("STATS payload-clearance result status=disabled").
        RETURN TRUE.
    }

    LOCAL settleTime IS 3.
    IF CFG:HASKEY("PAYLOAD_CLEARANCE_SETTLE") { SET settleTime TO CFG["PAYLOAD_CLEARANCE_SETTLE"]. }
    LOCAL throttle_ IS 0.25.
    IF CFG:HASKEY("PAYLOAD_CLEARANCE_THROTTLE") { SET throttle_ TO CFG["PAYLOAD_CLEARANCE_THROTTLE"]. }
    SET throttle_ TO MAX(0.05, MIN(1, throttle_)).

    IF SHIP:AVAILABLETHRUST <= 0 OR SHIP:MASS <= 0 {
        mLogWarn("STATS payload-clearance result status=no-thrust").
        WAIT settleTime.
        RETURN FALSE.
    }

    LOCAL dirName IS "NORMAL".
    IF CFG:HASKEY("PAYLOAD_CLEARANCE_DIR") { SET dirName TO CFG["PAYLOAD_CLEARANCE_DIR"]. }
    LOCAL dirVec IS VCRS(SHIP:POSITION, SHIP:VELOCITY:ORBIT):NORMALIZED.
    IF dirName = "ANTINORMAL" {
        SET dirVec TO -dirVec.
    } ELSE IF dirName = "RADIALOUT" {
        SET dirVec TO SHIP:UP:VECTOR.
    } ELSE IF dirName = "RADIALIN" {
        SET dirVec TO -SHIP:UP:VECTOR.
    } ELSE IF dirName = "RIGHT" {
        SET dirVec TO SHIP:FACING:RIGHTVECTOR.
    }

    LOCAL burnTime IS clearDv / ((SHIP:AVAILABLETHRUST / SHIP:MASS) * throttle_).
    SET burnTime TO MAX(0.2, MIN(8, burnTime)).
    mLogWarn("STATS payload-clearance setup dv=" + ROUND(clearDv,1)
        + " dir=" + dirName
        + " throttle=" + ROUND(throttle_,2)
        + " burnTime=" + ROUND(burnTime,1)
        + " settle=" + ROUND(settleTime,1)).

    SET SAS TO FALSE.
    LOCK STEERING TO dirVec.
    LOCAL startT IS TIME:SECONDS.
    LOCAL aligned IS FALSE.
    UNTIL aligned OR TIME:SECONDS - startT > 10 {
        IF VANG(SHIP:FACING:FOREVECTOR, dirVec) < 8 { SET aligned TO TRUE. }
        WAIT 0.1.
    }
    IF NOT aligned {
        mLogWarn("Payload clearance nudge starting with poor alignment.").
    }

    LOCK THROTTLE TO throttle_.
    WAIT burnTime.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    WAIT settleTime.
    mLogWarn("STATS payload-clearance result status=complete PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    RETURN TRUE.
}

LOCAL FUNCTION _executeScanSatStep {
    PARAMETER label.

    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        IF NOT HASNODE {
            mLogError(label + " has no maneuver node.").
            RETURN FALSE.
        }
        WAIT 0.5.
        LOCAL maxDv IS 1000.
        IF CFG:HASKEY("SCANSAT_MAX_NODE_DV") { SET maxDv TO CFG["SCANSAT_MAX_NODE_DV"]. }
        IF NEXTNODE:DELTAV:MAG > maxDv {
            mLogError(label + " node rejected: dV="
                + ROUND(NEXTNODE:DELTAV:MAG,1)
                + " m/s exceeds SCANsat cap " + ROUND(maxDv,1) + " m/s.").
            mLogWarn("STATS scansat-burn rejected label=" + label
                + " dv=" + ROUND(NEXTNODE:DELTAV:MAG,1)
                + " cap=" + ROUND(maxDv,1)
                + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
                + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
            REMOVE NEXTNODE.
            RETURN FALSE.
        }
        mLogWarn("STATS scansat-burn setup label=" + label
            + " dv=" + ROUND(NEXTNODE:DELTAV:MAG,1)
            + " eta=" + ROUND(NEXTNODE:ETA,1)).
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog(label + " missed (attempt " + retries + ") — waiting 5s.").
            IF retries >= 1 AND NOT HASNODE {
                mLogWarn(label + " node was removed after miss; caller should replan.").
                RETURN FALSE.
            }
            IF retries >= 3 {
                mLogError(label + " failed after " + retries + " attempts.").
                RETURN FALSE.
            }
            WAIT 5.
        }
    }
    RETURN TRUE.
}

LOCAL FUNCTION _executeScanSatPlanStep {
    PARAMETER planFn.
    PARAMETER label.

    LOCAL tries IS 0.
    UNTIL tries >= 3 {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS planFn:CALL().
        IF nd = 0 {
            mLogWarn(label + " planner returned no node.").
        } ELSE {
            IF NOT HASNODE { ADD nd. }
            IF NEXTNODE:ETA < 30 {
                mLogWarn(label + " planned too close/past ETA="
                    + ROUND(NEXTNODE:ETA,1) + "; replanning next opportunity.").
                REMOVE NEXTNODE.
            } ELSE IF _executeScanSatStep(label) {
                RETURN TRUE.
            }
        }
        SET tries TO tries + 1.
        WAIT 5.
    }
    mLogError(label + " failed after replanning attempts.").
    RETURN FALSE.
}

LOCAL FUNCTION _scanSatRecoverPeDirect {
    PARAMETER requestedPe.

    LOCAL safePe IS 10000.
    IF CFG:HASKEY("SCANSAT_RECOVER_SAFE_PE") {
        SET safePe TO CFG["SCANSAT_RECOVER_SAFE_PE"].
    }
    LOCAL targetPe IS MIN(requestedPe, safePe).
    IF targetPe >= SHIP:APOAPSIS - 1000 {
        SET targetPe TO SHIP:APOAPSIS - 1000.
    }
    IF targetPe < 1000 { SET targetPe TO 1000. }

    LOCAL maxTime IS 120.
    IF CFG:HASKEY("SCANSAT_RECOVER_MAX_TIME") {
        SET maxTime TO CFG["SCANSAT_RECOVER_MAX_TIME"].
    }

    mLogWarn("STATS scansat-recover-direct setup PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " requestedPeKm=" + ROUND(requestedPe/1000,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " maxTime=" + ROUND(maxTime,0)
        + " thrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).

    IF SHIP:PERIAPSIS >= targetPe {
        mLog("SCANsat recovery Pe already safe.").
        RETURN TRUE.
    }
    IF SHIP:AVAILABLETHRUST <= 0 {
        mLogWarn("SCANsat direct recovery skipped: no available thrust.").
        RETURN FALSE.
    }

    SET SAS TO FALSE.
    LOCK STEERING TO SHIP:PROGRADE.
    LOCAL startT IS TIME:SECONDS.
    LOCAL aligned IS FALSE.
    UNTIL aligned OR TIME:SECONDS - startT > 30 {
        IF VANG(SHIP:FACING:FOREVECTOR, SHIP:PROGRADE:FOREVECTOR) < 5 {
            SET aligned TO TRUE.
        }
        WAIT 0.1.
    }
    IF NOT aligned {
        mLogWarn("SCANsat direct recovery starting with poor prograde alignment.").
    }

    LOCK THROTTLE TO 1.
    UNTIL SHIP:PERIAPSIS >= targetPe
            OR SHIP:AVAILABLETHRUST <= 0
            OR TIME:SECONDS - startT > maxTime {
        LOCK STEERING TO SHIP:PROGRADE.
        WAIT 0.1.
    }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    LOCAL status_ IS "complete".
    IF SHIP:PERIAPSIS < targetPe AND SHIP:AVAILABLETHRUST <= 0 {
        SET status_ TO "out-of-thrust".
    } ELSE IF SHIP:PERIAPSIS < targetPe {
        SET status_ TO "timeout".
    }
    mLogWarn("STATS scansat-recover-direct result status=" + status_
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " duration=" + ROUND(TIME:SECONDS - startT,1)).

    IF status_ = "complete" { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _scanSatPlanAndExecuteRaiseAp {
    PARAMETER recoveryAp.
    RETURN _executeScanSatPlanStep(
        { RETURN _scanSatPlanRaiseAp(recoveryAp). },
        "SCANsat recovery raise Ap").
}

LOCAL FUNCTION _scanSatClearDisposedStage {
    LOCAL clearDv IS 2.
    IF CFG:HASKEY("SCANSAT_CLEARANCE_DV") { SET clearDv TO CFG["SCANSAT_CLEARANCE_DV"]. }
    IF clearDv <= 0 {
        mLogWarn("STATS scansat-clearance result status=disabled").
        RETURN TRUE.
    }

    LOCAL settleTime IS 3.
    IF CFG:HASKEY("SCANSAT_CLEARANCE_SETTLE") { SET settleTime TO CFG["SCANSAT_CLEARANCE_SETTLE"]. }
    LOCAL throttle_ IS 0.25.
    IF CFG:HASKEY("SCANSAT_CLEARANCE_THROTTLE") { SET throttle_ TO CFG["SCANSAT_CLEARANCE_THROTTLE"]. }
    SET throttle_ TO MAX(0.05, MIN(1, throttle_)).

    IF SHIP:AVAILABLETHRUST <= 0 OR SHIP:MASS <= 0 {
        mLogWarn("STATS scansat-clearance result status=no-thrust").
        WAIT settleTime.
        RETURN FALSE.
    }

    LOCAL dirName IS "NORMAL".
    IF CFG:HASKEY("SCANSAT_CLEARANCE_DIR") {
        SET dirName TO CFG["SCANSAT_CLEARANCE_DIR"].
    }
    LOCAL dirVec IS VCRS(SHIP:POSITION, SHIP:VELOCITY:ORBIT):NORMALIZED.
    IF dirName = "ANTINORMAL" {
        SET dirVec TO -dirVec.
    } ELSE IF dirName = "RADIALOUT" {
        SET dirVec TO SHIP:UP:VECTOR.
    } ELSE IF dirName = "RADIALIN" {
        SET dirVec TO -SHIP:UP:VECTOR.
    } ELSE IF dirName = "RIGHT" {
        SET dirVec TO SHIP:FACING:RIGHTVECTOR.
    }

    LOCAL burnTime IS clearDv / ((SHIP:AVAILABLETHRUST / SHIP:MASS) * throttle_).
    SET burnTime TO MAX(0.2, MIN(8, burnTime)).
    mLogWarn("STATS scansat-clearance setup dv=" + ROUND(clearDv,1)
        + " dir=" + dirName
        + " throttle=" + ROUND(throttle_,2)
        + " burnTime=" + ROUND(burnTime,1)
        + " settle=" + ROUND(settleTime,1)).

    SET SAS TO FALSE.
    LOCK STEERING TO dirVec.
    LOCAL startT IS TIME:SECONDS.
    LOCAL aligned IS FALSE.
    UNTIL aligned OR TIME:SECONDS - startT > 10 {
        IF VANG(SHIP:FACING:FOREVECTOR, dirVec) < 8 { SET aligned TO TRUE. }
        WAIT 0.1.
    }
    IF NOT aligned {
        mLogWarn("SCANsat clearance nudge starting with poor alignment.").
    }

    LOCK THROTTLE TO throttle_.
    WAIT burnTime.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    WAIT settleTime.
    mLogWarn("STATS scansat-clearance result status=complete PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    RETURN TRUE.
}

LOCAL FUNCTION _scanSatDisposeAttached {
    PARAMETER targetPe.

    LOCAL maxTime IS 600.
    IF CFG:HASKEY("SCANSAT_DISPOSE_MAX_TIME") {
        SET maxTime TO CFG["SCANSAT_DISPOSE_MAX_TIME"].
    }

    mLogWarn("STATS scansat-dispose setup PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " maxTime=" + ROUND(maxTime,0)
        + " thrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).

    IF SHIP:PERIAPSIS <= targetPe {
        mLog("SCANsat carrier already on disposal Pe.").
        RETURN TRUE.
    }
    IF SHIP:AVAILABLETHRUST <= 0 {
        mLogWarn("SCANsat carrier disposal skipped: no available thrust.").
        RETURN FALSE.
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
    UNTIL SHIP:PERIAPSIS <= targetPe
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
    IF SHIP:PERIAPSIS > targetPe AND SHIP:AVAILABLETHRUST <= 0 {
        SET status_ TO "out-of-thrust".
    } ELSE IF SHIP:PERIAPSIS > targetPe {
        SET status_ TO "timeout".
    }
    mLogWarn("STATS scansat-dispose result status=" + status_
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " duration=" + ROUND(TIME:SECONDS - startT,1)).

    IF status_ = "complete" { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _scanSatPlanPeAtAp {
    PARAMETER targetPe.
    PARAMETER label.

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL burnTime IS TIME:SECONDS + ETA:APOAPSIS.
    LOCAL rBurn IS bodyR + SHIP:APOAPSIS.
    LOCAL rTarget IS bodyR + targetPe.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(burnTime, 0, 0, vNew - vNow).
    ADD nd.
    mLog(label + " node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPe=" + ROUND(targetPe/1000,1) + "km").
    archivePlannedManeuverLog(label).
    RETURN nd.
}

LOCAL FUNCTION _scanSatPlanRaiseAp {
    PARAMETER targetAp.

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL etaPe IS _scanSatNextApsisEta(ETA:PERIAPSIS).
    LOCAL burnTime IS TIME:SECONDS + etaPe.
    LOCAL rBurn IS bodyR + SHIP:PERIAPSIS.
    LOCAL rTarget IS bodyR + targetAp.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(burnTime, 0, 0, vNew - vNow).
    ADD nd.
    mLog("SCANsat raise Ap node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetAp=" + ROUND(targetAp/1000,1) + "km"
        + " etaPe=" + ROUND(etaPe,1)).
    mLogWarn("STATS scansat-raise-ap plan dv=" + ROUND(nd:DELTAV:MAG,1)
        + " targetApKm=" + ROUND(targetAp/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    archivePlannedManeuverLog("scansat-raise-ap").
    RETURN nd.
}

LOCAL FUNCTION _scanSatNextApsisEta {
    PARAMETER eta_.
    LOCAL outEta IS eta_.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    UNTIL outEta >= 30 {
        SET outEta TO outEta + period.
    }
    RETURN outEta.
}

LOCAL FUNCTION _releaseTaggedPayloadXfer {
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
