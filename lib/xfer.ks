// ============================================================
// xfer.ks  —  Transfer & arrival phases  (0:/lib/xfer.ks)
// ============================================================

GLOBAL xferSeq IS LIST().

LOCAL MAX_RETRIES IS 5.

GLOBAL FUNCTION phaseRendezvous {
    LOCAL targetName IS "".
    IF CFG:HASKEY("RENDEZVOUS_TARGET") { SET targetName TO CFG["RENDEZVOUS_TARGET"]. }
    IF CFG:HASKEY("ASTEROID_TARGET")   { SET targetName TO CFG["ASTEROID_TARGET"]. }

    IF targetName = "" {
        mLogWarn("RDV phase requested but no RENDEZVOUS_TARGET or ASTEROID_TARGET configured.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL targetVessel IS VESSEL(targetName).
    LOCAL opts IS _rendezvousOptions().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    orbitSummary().
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS planRendezvous(targetVessel, opts).
        IF nd = 0 {
            mLogError("Rendezvous planner failed for " + targetName + ".").
            RETURN.
        }
        mLog("Rendezvous planned with " + targetName + ".").
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Rendezvous burn missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError("Rendezvous failed after " + retries + " attempts.").
                RETURN.
            }
            WAIT 10.
        }
    }

    orbitSummary().
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseTransfer {
    LOCAL target IS missionTargetBody().
    orbitSummary().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    IF HASNODE {
        LOCAL existing IS NEXTNODE.
        LOCAL pending IS stateGet("burn_pending", "false").
        mLogWarn("STATS transfer resume existing-node pending=" + pending
            + " burnPhase=" + stateGet("burn_phase", "")
            + " dv="
            + ROUND(existing:DELTAV:MAG,1)
            + " eta=" + ROUND(existing:ETA,1)
            + " body=" + SHIP:BODY:NAME).
        SET success TO executeManeuver().
        IF success {
            orbitSummary().
            nextPhase(xferSeq).
            RETURN.
        }
        mLogWarn("Existing transfer node was not usable; replanning.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    } ELSE IF stateGet("burn_pending", "false") = "true" {
        mLogWarn("STATS transfer resume missing-node pending=true burnPhase="
            + stateGet("burn_phase", "")
            + " burnDv=" + ROUND(stateGetNum("burn_dv", 0),1)
            + " — replanning.").
    }

    UNTIL success {
        LOCAL xLan IS -1.
        LOCAL xAoP IS -1.
        IF CFG:HASKEY("CAPTURE_LAN") { SET xLan TO CFG["CAPTURE_LAN"]. }
        IF CFG:HASKEY("CAPTURE_AOP") { SET xAoP TO CFG["CAPTURE_AOP"]. }
        planTransfer(target, CFG["CAPTURE_PE"], xLan, xAoP).
        mLog("Transfer planned.").
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Transfer missed (attempt " + retries + ") — waiting 10s and replanning.").
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            IF retries >= MAX_RETRIES {
                mLogError("Transfer failed after " + retries + " attempts — halting.").
                RETURN.
            }
            WAIT 10.
        }
    }
    nextPhase(xferSeq).
}

LOCAL FUNCTION _rendezvousOptions {
    LOCAL opts IS LEXICON().
    IF CFG:HASKEY("ASTEROID_MAX_DEPART_ORBITS") {
        opts:ADD("MAX_DEPART_ORBITS", CFG["ASTEROID_MAX_DEPART_ORBITS"]).
    }
    IF CFG:HASKEY("ASTEROID_DEPART_SAMPLES") {
        opts:ADD("DEPART_SAMPLES", CFG["ASTEROID_DEPART_SAMPLES"]).
    }
    IF CFG:HASKEY("ASTEROID_TOF_SAMPLES") {
        opts:ADD("TOF_SAMPLES", CFG["ASTEROID_TOF_SAMPLES"]).
    }
    IF CFG:HASKEY("ASTEROID_MIN_TOF") {
        opts:ADD("MIN_TOF", CFG["ASTEROID_MIN_TOF"]).
    }
    IF CFG:HASKEY("ASTEROID_MAX_TOF") {
        opts:ADD("MAX_TOF", CFG["ASTEROID_MAX_TOF"]).
    }
    IF CFG:HASKEY("ASTEROID_ARRIVAL_WEIGHT") {
        opts:ADD("ARRIVAL_WEIGHT", CFG["ASTEROID_ARRIVAL_WEIGHT"]).
    }
    IF CFG:HASKEY("ASTEROID_REFINE_ITERS") {
        opts:ADD("REFINE_ITERS", CFG["ASTEROID_REFINE_ITERS"]).
    }
    RETURN opts.
}

GLOBAL FUNCTION phaseCoast {
    LOCAL target IS missionTargetBody().
    SET SAS TO TRUE.
    UNLOCK STEERING.
    mLog("Coasting to " + target:NAME + " SOI.").
    waitForSOI(target).
    orbitSummary().
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCapture {
    LOCAL target IS missionTargetBody().
    WAIT 2.
    mLog("Planning capture into elliptical orbit at " + target:NAME + ".").
    mLogWarn("STATS capture phase setup target=" + target:NAME
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).
    
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        
        // 1. Resolve target altitude from config
        LOCAL captureAlt IS CFG["TARGET_PE"].
        IF CFG:HASKEY("TARGET_AP") { SET captureAlt TO CFG["TARGET_AP"]. }

        // 2. Delegate math to your existing library function
        planCapture(target, captureAlt).

        // 3. Execute with standard retry logic
        SET success TO executeManeuver().
        
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Capture missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError("Capture failed after " + retries + " attempts — halting.").
                RETURN.
            }
            WAIT 10.
        }
    }
    
    orbitSummary().
    mLogWarn("STATS capture phase result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    mLog("Capture complete. Moving to finalization phase.").
    nextPhase(xferSeq).
}

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

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    IF NOT _scanSatDisposeAttached(impactPe) { RETURN. }

    IF tag <> "" {
        IF NOT _releaseTaggedPayloadXfer(tag, "SCANsat") {
            mLogError("SCANsat release failed after impact setup — tag '" + tag
                + "' missing or not decouplable.").
            HUDTEXT("ERROR: SCANsat not released", 8, 2, 16, RED, FALSE).
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

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    _scanSatPlanPeAtAp(recoveryPe, "SCANsat recover Pe").
    IF NOT _executeScanSatStep("SCANsat recover Pe") { RETURN. }

    IF SHIP:ORBIT:ECCENTRICITY > 0.01
            OR ABS(SHIP:APOAPSIS - recoveryAp) > recoveryAp * 0.1 {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planCircularize().
        IF NOT _executeScanSatStep("SCANsat recovery recircularize") { RETURN. }
    }

    stateSet("scansat_recovered", "true").
    orbitSummary().
    mLogWarn("STATS scansat-impact-release result PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    nextPhase(xferSeq).
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
            IF retries >= 3 {
                mLogError(label + " failed after " + retries + " attempts.").
                RETURN FALSE.
            }
            WAIT 5.
        }
    }
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

    LOCAL status IS "complete".
    IF SHIP:PERIAPSIS > targetPe AND SHIP:AVAILABLETHRUST <= 0 {
        SET status TO "out-of-thrust".
    } ELSE IF SHIP:PERIAPSIS > targetPe {
        SET status TO "timeout".
    }
    mLogWarn("STATS scansat-dispose result status=" + status
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " duration=" + ROUND(TIME:SECONDS - startT,1)).

    IF status = "complete" { RETURN TRUE. }
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
    LOCAL targetBody IS missionTargetBody().
    WAIT 2.
    mLog("Planning unified PE, INC, LAN, and AoP alignment at Apoapsis...").

    // 1. Safely extract all 4 target parameters
    LOCAL targetPe  IS -1.
    LOCAL targetInc IS -1.
    LOCAL targetAoP IS -1.
    LOCAL targetLan IS -1.

    IF CFG:HASKEY("TARGET_PE")   { SET targetPe TO CFG["TARGET_PE"]. }
    IF CFG:HASKEY("CAPTURE_INC") { SET targetInc TO CFG["CAPTURE_INC"]. }
    IF CFG:HASKEY("CAPTURE_AOP") { SET targetAoP TO CFG["CAPTURE_AOP"]. }
    IF CFG:HASKEY("CAPTURE_LAN") { SET targetLan TO CFG["CAPTURE_LAN"]. }

    IF targetPe < 0 AND targetInc < 0 AND targetAoP < 0 AND targetLan < 0 {
        mLog("No finalization targets specified. Skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    
    // Plant the base node exactly at Apoapsis
    LOCAL burnTime IS TIME:SECONDS + ETA:APOAPSIS.
    LOCAL nd IS NODE(burnTime, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    // --- FITNESS FUNCTION ---
    LOCAL FUNCTION getFinalScore {
        LOCAL p IS nd:ORBIT. 
        
        IF p:PERIAPSIS < 0 { RETURN 9999999. } // Impact safety catch

        LOCAL peErr  IS 0.
        LOCAL incErr IS 0.
        LOCAL aopErr IS 0.
        LOCAL lanErr IS 0.

        IF targetPe >= 0 { SET peErr TO ABS(p:PERIAPSIS - targetPe) / 1000. }
        IF targetInc >= 0 { SET incErr TO ABS(p:INCLINATION - targetInc). }
        
        IF targetAoP >= 0 {
            LOCAL rawAoP IS ABS(p:ARGUMENTOFPERIAPSIS - targetAoP).
            IF rawAoP > 180 { SET rawAoP TO 360 - rawAoP. }
            SET aopErr TO rawAoP.
        }
        
        IF targetLan >= 0 {
            LOCAL rawLan IS ABS(p:LAN - targetLan).
            IF rawLan > 180 { SET rawLan TO 360 - rawLan. }
            SET lanErr TO rawLan.
        }

        // Weighting: 
        // PE keeps us alive (highest priority). 
        // INC is likely already close, but heavily weighted to prevent the solver from breaking it.
        // LAN and AOP are dialed in using the remaining Normal/Radial flexibility.
        RETURN (peErr * 10) + (incErr * 50) + (lanErr * 25) + (aopErr * 20).
    }
    

    // --- 4-AXIS HILL CLIMB (Prograde, Radial, Normal, TIME) ---
    LOCAL currentScore IS getFinalScore().
    
    // We now step both Delta-V and Time
    LOCAL stepDv IS 10.0. 
    LOCAL stepTime IS 120.0. // Start by shifting the node in 2-minute increments
    LOCAL minStepDv IS 0.01.
    LOCAL iter IS 0.

    UNTIL stepDv < minStepDv OR iter > 300 {
        SET iter TO iter + 1.
        LOCAL improved IS FALSE.

        LOCAL basePro  IS nd:PROGRADE.
        LOCAL baseRad  IS nd:RADIALOUT.
        LOCAL baseNor  IS nd:NORMAL.
        LOCAL baseTime IS nd:TIME.

        // The 8 directions to probe (6 spatial, 2 temporal)
        LOCAL probes IS LIST(
            LIST(stepDv, 0, 0, 0), LIST(-stepDv, 0, 0, 0),
            LIST(0, stepDv, 0, 0), LIST(0, -stepDv, 0, 0),
            LIST(0, 0, stepDv, 0), LIST(0, 0, -stepDv, 0),
            LIST(0, 0, 0, stepTime), LIST(0, 0, 0, -stepTime)
        ).

        LOCAL bestProbeScore IS currentScore.
        LOCAL bestPro  IS basePro.
        LOCAL bestRad  IS baseRad.
        LOCAL bestNor  IS baseNor.
        LOCAL bestTime IS baseTime.

        FOR p IN probes {
            SET nd:PROGRADE TO basePro + p[0].
            SET nd:RADIALOUT TO baseRad + p[1].
            SET nd:NORMAL TO baseNor + p[2].
            SET nd:TIME TO baseTime + p[3].
            WAIT 0.01. // Allow KSP conics to update

            LOCAL probeScore IS getFinalScore().
            IF probeScore < bestProbeScore {
                SET bestProbeScore TO probeScore.
                SET bestPro  TO nd:PROGRADE.
                SET bestRad  TO nd:RADIALOUT.
                SET bestNor  TO nd:NORMAL.
                SET bestTime TO nd:TIME.
                SET improved TO TRUE.
            }
            
            // Reset for the next probe in the loop
            SET nd:PROGRADE TO basePro.
            SET nd:RADIALOUT TO baseRad.
            SET nd:NORMAL TO baseNor.
            SET nd:TIME TO baseTime.
        }

        IF improved {
            // Step in the winning direction
            SET nd:PROGRADE TO bestPro.
            SET nd:RADIALOUT TO bestRad.
            SET nd:NORMAL TO bestNor.
            SET nd:TIME TO bestTime.
            SET currentScore TO bestProbeScore.
        } ELSE {
            // Shrink both search spaces to refine the exact node
            SET stepDv TO stepDv * 0.5.
            SET stepTime TO stepTime * 0.5. 
        }
    }
    // 3. Evaluate and execute the resulting maneuver
    LOCAL totalDv IS nd:DELTAV:MAG.
    mLog("Finalization Converged: dV=" + ROUND(totalDv, 1) + " m/s").
    
    LOCAL resultMsg IS "Result ->".
    IF targetPe >= 0  { SET resultMsg TO resultMsg + " Pe: " + ROUND(nd:ORBIT:PERIAPSIS/1000, 1) + "km". }
    IF targetInc >= 0 { SET resultMsg TO resultMsg + " Inc: " + ROUND(nd:ORBIT:INCLINATION, 1) + "°". }
    IF targetAoP >= 0 { SET resultMsg TO resultMsg + " AoP: " + ROUND(nd:ORBIT:ARGUMENTOFPERIAPSIS, 1) + "°". }
    mLog(resultMsg).
    archivePlannedManeuverLog("elliptical-finalization").

    // Execution loop integrating your retry architecture
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Finalization burn missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError("Finalization failed after " + retries + " attempts. Halting.").
                RETURN.
            }
            WAIT 10.
        }
    }

    orbitSummary().
    mLog("Orbit finalization complete!").
    nextPhase(xferSeq).
}
