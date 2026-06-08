// ============================================================
// maneuver_orbit.ks  —  Post-capture orbit adjustment phases
// (0:/lib/maneuver_orbit.ks)
//
// phaseCirc                  — circularize or handle impact threat
// phaseRaiseAlt              — raise Pe/Ap to target ellipse or relay alt
// phaseInclCorrect           — correct orbital inclination
// phaseElliptical            — unified PE/INC/LAN/AoP hill-climb solver
// phaseScanSatImpactRelease  — SCANsat disposal + release + recovery
// ============================================================

LOCAL MAX_RETRIES IS 5.

GLOBAL FUNCTION phaseCirc {
    IF CFG:HASKEY("SCANSAT_RELEASE_AFTER_CAPTURE")
            AND CFG["SCANSAT_RELEASE_AFTER_CAPTURE"] > 0 {
        mLog("CIRC redirected to SCANsat impact/release profile.").
        stateSet("phase", "SCANSAT_IMPACT_RELEASE").
        phaseScanSatImpactRelease().
        RETURN.
    }

    LOCAL circStatus IS "complete".
    mLogWarn("STATS circ phase setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    IF _impactThreat() {
        LOCAL safePe IS CFG["PARKING_ALT"].
        IF CFG:HASKEY("CAPTURE_PE") AND CFG["CAPTURE_PE"] > safePe {
            SET safePe TO CFG["CAPTURE_PE"].
        }
        mLog("Impact threat — raising Pe to safe " + ROUND(safePe/1000,0) + "km.").
        LOCAL success IS FALSE.
        LOCAL retries IS 0.
        UNTIL success {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            planRaisePeNow(safePe).
            WAIT 2.
            SET success TO executeManeuver().
            IF NOT success {
                SET retries TO retries + 1.
                mLog("Raise Pe missed (attempt " + retries + ") — waiting 10s.").
                IF retries >= MAX_RETRIES {
                    mLogError("Raise Pe failed after " + retries + " attempts — halting.").
                    RETURN.
                }
                WAIT 10.
            }
        }
    } ELSE IF SHIP:ORBIT:ECCENTRICITY < CFG["CIRC_ECC_TOL"] {
        mLog("Already circular (ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4) + ").").
        SET circStatus TO "skipped".
    } ELSE {
        LOCAL success IS FALSE.
        LOCAL retries IS 0.
        UNTIL success {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            planCircularize().
            SET success TO executeManeuver().
            IF NOT success {
                SET retries TO retries + 1.
                mLog("Circ burn missed (attempt " + retries + ") — waiting 10s.").
                IF retries >= MAX_RETRIES {
                    mLogError("Circ failed after " + retries + " attempts — halting.").
                    RETURN.
                }
                WAIT 10.
            }
        }
    }
    orbitSummary().
    mLogWarn("STATS circ phase result status=" + circStatus
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    nextPhase(xferSeq).
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
    stateSet("phase", "SCANSAT_IMPACT_RELEASE").
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
    stateSet("phase", "PAYLOAD_IMPACT_RELEASE").
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
    LOCAL current IS stateGet("phase", ""):TOUPPER.
    IF DEFINED xferSeq {
        FROM { LOCAL i IS 0. } UNTIL i >= xferSeq:LENGTH STEP { SET i TO i + 1. } DO {
            IF xferSeq[i]:TOUPPER = current {
                IF i + 1 < xferSeq:LENGTH { RETURN xferSeq[i + 1]:TOUPPER. }
                RETURN "".
            }
        }
    }
    RETURN "".
}

LOCAL FUNCTION _bodyImpactFloor {
    LOCAL body_ IS SHIP:ORBIT:BODY.
    IF body_:ATM:EXISTS { RETURN body_:ATM:HEIGHT + 1000. }
    RETURN 5000.
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
    IF CFG:HASKEY("PAYLOAD_CLEARANCE_DIR") { SET dirName TO CFG["PAYLOAD_CLEARANCE_DIR"]:TOUPPER. }
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

GLOBAL FUNCTION phaseRaiseAlt {
    LOCAL elliptical IS CFG:HASKEY("TARGET_PE") AND CFG:HASKEY("TARGET_AP").
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    mLogWarn("STATS raise phase setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " elliptical=" + elliptical).

    IF elliptical {
        LOCAL targetPe IS CFG["TARGET_PE"].
        LOCAL targetAp IS CFG["TARGET_AP"].
        mLog("Target ellipse: Pe=" + ROUND(targetPe/1000,0) + "km  Ap=" + ROUND(targetAp/1000,0) + "km.").

        IF ABS(SHIP:PERIAPSIS - targetPe) > targetPe * 0.05 {
            mLog("Raising Pe to " + ROUND(targetPe/1000,0) + "km at Ap.").
            _burnWithRetry(
                { LOCAL rAp IS bodyR + SHIP:APOAPSIS. LOCAL rPe IS bodyR + targetPe. LOCAL tSMA IS (rAp + rPe) / 2. LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:APOAPSIS):ORBIT:MAG. LOCAL vNew IS SQRT(mu * (2/rAp - 1/tSMA)). RETURN NODE(TIME:SECONDS + ETA:APOAPSIS, 0, 0, vNew - vNow). },
                "Raise Pe").
        } ELSE {
            mLog("Pe already within tolerance.").
        }

        IF ABS(SHIP:APOAPSIS - targetAp) > targetAp * 0.02 {
            LOCAL burnTA IS 0.
            IF CFG:HASKEY("CAPTURE_AOP") {
                LOCAL targetAoP IS CFG["CAPTURE_AOP"].
                SET burnTA TO targetAoP - SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
                UNTIL burnTA >= 0 { SET burnTA TO burnTA + 360. }
                UNTIL burnTA < 360 { SET burnTA TO burnTA - 360. }
                mLog("Raise Ap at TA=" + ROUND(burnTA,1) + "deg for AoP=" + ROUND(targetAoP,1) + "deg.").
            } ELSE {
                mLog("Raising Ap to " + ROUND(targetAp/1000,0) + "km at Pe.").
            }
            _burnWithRetry(
                { LOCAL eta_ IS etaToTrueAnomaly(burnTA). LOCAL burnTime IS TIME:SECONDS + eta_. LOCAL rBurn IS bodyR + _altAtTA(burnTA). LOCAL rTarget IS bodyR + targetAp. LOCAL tSMA IS (rBurn + rTarget) / 2. LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG. LOCAL vNew IS SQRT(mu * (2/rBurn - 1/tSMA)). RETURN NODE(burnTime, 0, 0, vNew - vNow). },
                "Raise Ap").
        } ELSE {
            mLog("Ap already within tolerance.").
        }
    } ELSE {
        LOCAL targetAp IS CFG["RELAY_ALT"].
        IF SHIP:APOAPSIS > targetAp * 0.99 {
            mLog("Already at target Ap.").
            mLogWarn("STATS raise phase result status=skipped PeKm="
                + ROUND(SHIP:PERIAPSIS/1000,1)
                + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
            nextPhase(xferSeq).
            RETURN.
        }
        mLog("Raising Ap to " + ROUND(targetAp/1000,0) + "km.").
        _burnWithRetry(
            { LOCAL rBurn IS bodyR + SHIP:PERIAPSIS. LOCAL rTarget IS bodyR + targetAp. LOCAL tSMA IS (rBurn + rTarget) / 2. LOCAL vNow IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG. LOCAL vNew IS SQRT(mu * (2/rBurn - 1/tSMA)). RETURN NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, vNew - vNow). },
            "Raise Ap").
    }

    orbitSummary().
    mLogWarn("STATS raise phase result status=complete PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).
    nextPhase(xferSeq).
}

LOCAL FUNCTION _burnWithRetry {
    PARAMETER planFn.
    PARAMETER label.
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS planFn:CALL().
        ADD nd.
        mLog(label + ": dV=" + ROUND(nd:DELTAV:MAG,1) + " m/s").
        archivePlannedManeuverLog(label).
        WAIT 2.
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog(label + " missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError(label + " failed after " + retries + " attempts.").
                RETURN.
            }
            WAIT 10.
        }
    }
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
        SET dirName TO CFG["SCANSAT_CLEARANCE_DIR"]:TOUPPER.
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

GLOBAL FUNCTION phaseInclCorrect {
    LOCAL targetInc IS resolveTargetInclination().
    LOCAL currentInc IS SHIP:ORBIT:INCLINATION.
    mLogWarn("STATS incline phase setup current=" + ROUND(currentInc,2)
        + " target=" + ROUND(targetInc,2)
        + " tol=" + CFG["INCL_TOLERANCE"]).

    IF currentInc > 90 AND targetInc < 90 {
        mLogWarn("Retrograde orbit detected (inc=" + ROUND(currentInc,1)
            + "deg) but target is prograde (" + ROUND(targetInc,1)
            + "deg) — plane change would cost ~600m/s. Skipping.").
        mLogWarn("STATS incline phase result status=skipped reason=retrograde-safety current="
            + ROUND(currentInc,2)
            + " target=" + ROUND(targetInc,2)).
        HUDTEXT("WARNING: Retrograde orbit — skipping incl correction",
            8, 2, 15, YELLOW, FALSE).
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL deltaInc IS ABS(currentInc - targetInc).
    IF deltaInc <= CFG["INCL_TOLERANCE"] {
        mLog("Inclination within tolerance — skipping.").
        mLogWarn("STATS incline phase result status=skipped current="
            + ROUND(currentInc,2)
            + " target=" + ROUND(targetInc,2)).
        nextPhase(xferSeq).
        RETURN.
    }

    mLog("Correcting inclination: " + ROUND(currentInc,2)
        + "deg -> " + ROUND(targetInc,2)
        + "deg  delta=" + ROUND(deltaInc,2) + "deg").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    planInclinationChange(targetInc).

    IF NEXTNODE:DELTAV:MAG > CFG["MAX_INCL_CHANGE_DV"] {
        mLogWarn("Inclination correction would cost " + ROUND(NEXTNODE:DELTAV:MAG,0)
            + "m/s — exceeds MAX_INCL_CHANGE_DV. Skipping.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        nextPhase(xferSeq).
        RETURN.
    }

    executeManeuver().
    orbitSummary().
    mLogWarn("STATS incline phase result status=complete current="
        + ROUND(SHIP:ORBIT:INCLINATION,2)
        + " target=" + ROUND(targetInc,2)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    nextPhase(xferSeq).
}

LOCAL FUNCTION _altAtTA {
    PARAMETER ta.
    LOCAL sma IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL ecc IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL r_ IS sma * (1 - ecc^2) / (1 + ecc * COS(ta)).
    RETURN r_ - SHIP:ORBIT:BODY:RADIUS.
}

LOCAL FUNCTION _impactThreat {
    LOCAL myBody IS SHIP:ORBIT:BODY.
    LOCAL pe   IS SHIP:PERIAPSIS.

    IF myBody:ATM:EXISTS {
        RETURN pe < myBody:ATM:HEIGHT + 1000.
    }

    RETURN pe < 5000.
}

GLOBAL FUNCTION phaseElliptical {
    WAIT 2.
    mLog("Planning bounded elliptical orbit finalization.").

    LOCAL targetPe  IS -1.
    LOCAL targetAp  IS -1.
    LOCAL targetInc IS -1.
    LOCAL targetAoP IS -1.

    IF CFG:HASKEY("TARGET_PE")   { SET targetPe TO CFG["TARGET_PE"]. }
    IF CFG:HASKEY("TARGET_AP")   { SET targetAp TO CFG["TARGET_AP"]. }
    IF CFG:HASKEY("CAPTURE_INC") { SET targetInc TO CFG["CAPTURE_INC"]. }
    IF CFG:HASKEY("CAPTURE_AOP") { SET targetAoP TO CFG["CAPTURE_AOP"]. }

    IF targetPe < 0 AND targetAp < 0 AND targetAoP < 0 {
        mLog("No elliptical finalization targets specified. Skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }

    IF targetPe >= 0 AND NOT _ellipticalRecoveryWindowSafe(targetPe) {
        mLogError("Elliptical recovery halted: apoapsis burn occurs after impact.").
        mLogWarn("STATS elliptical precheck status=blocked reason=recovery-window"
            + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + " targetPeKm=" + ROUND(targetPe/1000,1)
            + " floorPeKm=" + ROUND(_bodyImpactFloor()/1000,1)
            + " etaAp=" + ROUND(ETA:APOAPSIS,1)
            + " etaPe=" + ROUND(ETA:PERIAPSIS,1)).
        PRINT " ".
        PRINT "  ELLIPTICAL RECOVERY HOLD".
        PRINT "  Apoapsis burn is after impact. Manual control is available.".
        yieldToPrompt().
        RETURN.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL maxDv IS 300.
    IF CFG:HASKEY("ELLIPTICAL_MAX_NODE_DV") { SET maxDv TO CFG["ELLIPTICAL_MAX_NODE_DV"]. }

    IF targetPe >= 0 AND ABS(SHIP:PERIAPSIS - targetPe) > MAX(5000, targetPe * 0.01) {
        LOCAL burnTime IS TIME:SECONDS + ETA:APOAPSIS.
        LOCAL rAp IS bodyR + SHIP:APOAPSIS.
        LOCAL rPe IS bodyR + targetPe.
        LOCAL tSMA IS (rAp + rPe) / 2.
        LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG.
        LOCAL vNew IS SQRT(mu * (2/rAp - 1/tSMA)).
        LOCAL nd IS NODE(burnTime, 0, 0, vNew - vNow).
        ADD nd.
        WAIT 0.2.
        IF _ellipticalNodeBad(nd, targetPe, targetAp, targetInc, maxDv, "raise-pe") {
            REMOVE nd.
            yieldToPrompt().
            RETURN.
        }
        mLog("Elliptical raise Pe: dV=" + ROUND(nd:DELTAV:MAG,1)
            + " m/s  Pe=" + ROUND(nd:ORBIT:PERIAPSIS/1000,1)
            + "km Ap=" + ROUND(nd:ORBIT:APOAPSIS/1000,1) + "km").
        archivePlannedManeuverLog("elliptical-raise-pe").
        IF NOT _executeEllipticalStep("Elliptical raise Pe") { RETURN. }
    } ELSE {
        mLog("Elliptical Pe already within tolerance.").
    }

    IF targetAoP >= 0 {
        LOCAL aopErr IS _angleDiff(SHIP:ORBIT:ARGUMENTOFPERIAPSIS, targetAoP).
        IF ABS(aopErr) > 3 {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            LOCAL aopNode IS planAoPChange(targetAoP).
            IF aopNode <> 0 AND aopNode:ISTYPE("Node") {
                WAIT 0.2.
                IF _ellipticalNodeBad(aopNode, targetPe, targetAp, targetInc, maxDv, "aop") {
                    REMOVE aopNode.
                    yieldToPrompt().
                    RETURN.
                }
                IF NOT _executeEllipticalStep("Elliptical AoP trim") { RETURN. }
            }
        } ELSE {
            mLog("Elliptical AoP already within tolerance.").
        }
    }

    orbitSummary().
    mLog("Orbit finalization complete!").
    nextPhase(xferSeq).
}

LOCAL FUNCTION _ellipticalRecoveryWindowSafe {
    PARAMETER targetPe.
    IF SHIP:PERIAPSIS >= _bodyImpactFloor() { RETURN TRUE. }
    LOCAL margin IS 60.
    IF CFG:HASKEY("ELLIPTICAL_RECOVERY_MARGIN") { SET margin TO CFG["ELLIPTICAL_RECOVERY_MARGIN"]. }
    RETURN ETA:APOAPSIS + margin < ETA:PERIAPSIS.
}

LOCAL FUNCTION _angleDiff {
    PARAMETER current.
    PARAMETER target.
    LOCAL err IS current - target.
    IF err > 180 { SET err TO err - 360. }
    IF err < -180 { SET err TO err + 360. }
    RETURN err.
}

LOCAL FUNCTION _ellipticalNodeBad {
    PARAMETER nd.
    PARAMETER targetPe.
    PARAMETER targetAp.
    PARAMETER targetInc.
    PARAMETER maxDv.
    PARAMETER label.

    LOCAL p IS nd:ORBIT.
    LOCAL bad IS FALSE.
    LOCAL reason IS "".
    IF nd:DELTAV:MAG > maxDv {
        SET bad TO TRUE.
        SET reason TO "dv-cap".
    } ELSE IF p:HASNEXTPATCH {
        SET bad TO TRUE.
        SET reason TO "escape".
    } ELSE IF targetPe >= 0 AND ABS(p:PERIAPSIS - targetPe) > MAX(25000, targetPe * 0.15) {
        SET bad TO TRUE.
        SET reason TO "pe-error".
    } ELSE IF targetAp >= 0 AND ABS(p:APOAPSIS - targetAp) > MAX(50000, targetAp * 0.15) {
        SET bad TO TRUE.
        SET reason TO "ap-error".
    } ELSE IF targetInc >= 0 AND ABS(_angleDiff(p:INCLINATION, targetInc)) > 5 {
        SET bad TO TRUE.
        SET reason TO "inc-error".
    }

    IF bad {
        mLogError("Elliptical " + label + " node rejected: " + reason + ".").
        mLogWarn("STATS elliptical rejected label=" + label
            + " reason=" + reason
            + " dv=" + ROUND(nd:DELTAV:MAG,1)
            + " PeKm=" + ROUND(p:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(p:APOAPSIS/1000,1)
            + " inc=" + ROUND(p:INCLINATION,1)
            + " AoP=" + ROUND(p:ARGUMENTOFPERIAPSIS,1)).
        PRINT " ".
        PRINT "  ELLIPTICAL NODE REJECTED".
        PRINT "  " + reason + ". Manual control is available.".
    }
    RETURN bad.
}

LOCAL FUNCTION _executeEllipticalStep {
    PARAMETER label.
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog(label + " missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError(label + " failed after " + retries + " attempts.").
                yieldToPrompt().
                RETURN FALSE.
            }
            WAIT 10.
        }
    }
    RETURN TRUE.
}
