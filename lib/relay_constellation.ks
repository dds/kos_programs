// ============================================================
// relay_constellation.ks  —  Multi-relay deployment
// (0:/lib/relay_constellation.ks)
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL RELAY_COUNT IS 3.
GLOBAL RELAY_ALT IS -1.
GLOBAL TARGET_AP IS -1.


LOCAL CIRCULAR_ECC_LIMIT IS 0.01.

GLOBAL FUNCTION constellationDeploy {
    PARAMETER relayCount.
    PARAMETER targetAlt.
    PARAMETER bodyOverride IS "".

    LOCAL targetBody IS SHIP:ORBIT:BODY.
    IF bodyOverride <> "" { SET targetBody TO BODY(bodyOverride). }

    IF relayCount < 2 {
        mLogError("Constellation deploy requires at least two relays.").
        RETURN FALSE.
    }

    mLogPhase("CONSTELLATION DEPLOY").
    mLog("Deploying " + relayCount + " resonant relays at "
        + ROUND(targetAlt/1000,0) + "km around " + targetBody:NAME).

    LOCAL spacing IS 360 / relayCount.
    LOCAL phaseRatio IS (relayCount - 1) / relayCount.
    mLog("Angular spacing: " + ROUND(spacing,1)
        + "deg  phasing period ratio=" + ROUND(phaseRatio,3)).

    LOCAL releasedCount IS _syncRelayDeployedCount(relayCount).
    LOCAL pendingPhaseIdx IS _firstPendingPhase(relayCount).
    mLogWarn("STATS constellation setup count=" + relayCount
        + " released=" + releasedCount
        + " pendingPhase=" + pendingPhaseIdx
        + " targetAltKm=" + ROUND(targetAlt/1000,1)
        + " body=" + targetBody:NAME
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).

    IF pendingPhaseIdx = 0 AND NOT _ensureCircularBeforeDeploy(targetAlt) {
        mLogWarn("STATS constellation result status=circularize-failed"
            + " released=" + stateGetNum("relay_deployed_count", 0)).
        RETURN FALSE.
    }

    LOCAL idx IS 1.
    UNTIL idx > relayCount {
        IF _relayReleased(idx) {
            mLog("Relay " + idx + " already released; resuming ledger.").
        } ELSE {
            mLog("Deploying relay " + idx + " of " + relayCount).
            IF NOT _deployOneRelay(idx) {
                mLogError("Relay " + idx + " was not deployed; holding.").
                mLogWarn("STATS constellation result status=deploy-failed"
                    + " relay=" + idx
                    + " released=" + stateGetNum("relay_deployed_count", 0)).
                yieldToPrompt().
                RETURN FALSE.
            }
        }

        IF idx < relayCount AND NOT _relayPhaseComplete(idx) {
            IF NOT _phaseCarrierOneSlot(relayCount, targetAlt, targetBody, idx) {
                mLogError("Relay phasing failed after relay " + idx
                    + "; holding for operator review.").
                mLogWarn("STATS constellation result status=phase-failed"
                    + " relay=" + idx
                    + " released=" + stateGetNum("relay_deployed_count", 0)).
                yieldToPrompt().
                RETURN FALSE.
            }
        }
        SET idx TO idx + 1.
    }

    stateSet("relay_deployed_count", relayCount).
    mLog("Constellation deployment complete.").
    mLogWarn("STATS constellation result status=complete"
        + " released=" + relayCount
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).
    HUDTEXT("Constellation deployed!", 8, 2, 18, GREEN, FALSE).
    RETURN TRUE.
}

GLOBAL FUNCTION phaseRelayConstellation {
    LOCAL relayCount IS RELAY_COUNT.
    LOCAL targetAlt IS RELAY_ALT.
    IF targetAlt < 0 { SET targetAlt TO TARGET_AP. }
    IF targetAlt < 0 { SET targetAlt TO 500000. }

    IF constellationDeploy(relayCount, targetAlt) {
        nextPhase(xferSeq).
    }
}

LOCAL FUNCTION _deployOneRelay {
    PARAMETER relayIdx.

    LOCAL tag IS "relay_" + relayIdx.
    LOCAL parts IS SHIP:PARTSTAGGED(tag).
    IF parts:LENGTH = 0 {
        mLogError("No part tagged '" + tag + "' — skipping relay " + relayIdx + ".").
        RETURN FALSE.
    }

    SET SAS TO TRUE.
    WAIT 0.5.

    LOCAL dc IS parts[0].
    LOCAL activatedCount IS _activateRelayHardware(relayIdx).
    stateSet("relay_" + relayIdx + "_activation_count", activatedCount).
    mLog("Relay " + relayIdx + " activation before release: "
        + activatedCount + " deployable(s).").
    WAIT 1.0.

    IF dc:HASMODULE("ModuleDecouple") {
        dc:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF dc:HASMODULE("ModuleAnchoredDecoupler") {
        dc:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogError("relay_" + relayIdx + " has no decouple module.").
        RETURN FALSE.
    }

    WAIT 1.0.
    mLog("Relay " + relayIdx + " released at TA="
        + ROUND(SHIP:ORBIT:TRUEANOMALY,1) + "deg"
        + "  alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km").
    stateSet("relay_" + relayIdx + "_released", TIME:SECONDS).
    stateSet("relay_deployed_count", _countReleasedRelays(relayIdx)).
    RETURN TRUE.
}

LOCAL FUNCTION _phaseCarrierOneSlot {
    PARAMETER relayCount.
    PARAMETER targetAlt.
    PARAMETER targetBody.
    PARAMETER afterRelayIdx.

    LOCAL bodyR IS targetBody:RADIUS.
    LOCAL mu IS targetBody:MU.
    LOCAL targetR IS bodyR + targetAlt.
    LOCAL targetPeriod IS 2 * CONSTANT:PI * SQRT(targetR^3 / mu).
    LOCAL phaseRatio IS (relayCount - 1) / relayCount.
    LOCAL phasePeriod IS targetPeriod * phaseRatio.
    LOCAL phaseSma IS (mu * (phasePeriod / (2 * CONSTANT:PI))^2)^(1/3).
    LOCAL phasePeR IS 2 * phaseSma - targetR.
    LOCAL phasePeAlt IS phasePeR - bodyR.

    LOCAL floorAlt IS 5000.
    IF targetBody:ATM:EXISTS { SET floorAlt TO targetBody:ATM:HEIGHT + 5000. }
    IF phasePeAlt < floorAlt {
        mLogError("Resonant phasing Pe would be unsafe: "
            + ROUND(phasePeAlt/1000,1) + "km < floor "
            + ROUND(floorAlt/1000,1) + "km.").
        RETURN FALSE.
    }

    mLogWarn("STATS relay-phase setup targetAltKm=" + ROUND(targetAlt/1000,1)
        + " phasePeKm=" + ROUND(phasePeAlt/1000,1)
        + " targetPeriod=" + ROUND(targetPeriod,0)
        + " phasePeriod=" + ROUND(phasePeriod,0)
        + " afterRelay=" + afterRelayIdx).

    IF NOT _relayPhaseInserted(afterRelayIdx) {
        IF _looksLikePhasingOrbit(targetAlt, phasePeAlt) {
            mLog("Carrier is already in relay " + afterRelayIdx
                + " phasing orbit; marking insertion complete.").
            stateSet("relay_" + afterRelayIdx + "_phase_inserted", TIME:SECONDS).
        } ELSE {
            IF NOT _burnToPhasingOrbit(targetR, phaseSma, targetBody) {
                RETURN FALSE.
            }
            stateSet("relay_" + afterRelayIdx + "_phase_inserted", TIME:SECONDS).
        }
    } ELSE {
        mLog("Resuming relay " + afterRelayIdx + " phasing orbit.").
    }

    IF SHIP:ORBIT:ECCENTRICITY <= CIRCULAR_ECC_LIMIT {
        mLog("Carrier already circular after relay " + afterRelayIdx
            + "; marking phasing complete.").
        stateSet("relay_" + afterRelayIdx + "_phase_complete", TIME:SECONDS).
        RETURN TRUE.
    }

    LOCAL coastEnd IS TIME:SECONDS + MAX(0, ETA:APOAPSIS - 120).
    mLog("Coasting one phasing orbit; next circularize in "
        + ROUND(ETA:APOAPSIS,0) + "s.").
    IF PHASES_HAS_SOLAR { orientForSolar(). }
    LOCAL solarRef IS -1.
    UNTIL TIME:SECONDS >= coastEnd {
        SET solarRef TO trySolarHoldTick(solarRef).
        WAIT MIN(60, MAX(1, coastEnd - TIME:SECONDS)).
    }

    IF NOT _circularizeCarrier() {
        RETURN FALSE.
    }

    stateSet("relay_" + afterRelayIdx + "_phase_complete", TIME:SECONDS).
    mLogWarn("STATS relay-phase result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
        + " afterRelay=" + afterRelayIdx).
    RETURN TRUE.
}

LOCAL FUNCTION _burnToPhasingOrbit {
    PARAMETER targetR.
    PARAMETER phaseSma.
    PARAMETER targetBody.

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL mu IS targetBody:MU.
    LOCAL vNow IS SQRT(mu / targetR).
    LOCAL vPhase IS SQRT(mu * (2 / targetR - 1 / phaseSma)).
    LOCAL dv IS vPhase - vNow.
    LOCAL nd IS NODE(TIME:SECONDS + 60, 0, 0, dv).
    ADD nd.
    mLog("Relay phasing insertion: dV=" + ROUND(dv,1)
        + "m/s  targetPe=" + ROUND((2 * phaseSma - targetR
            - targetBody:RADIUS)/1000,1) + "km.").
    maneuverUiArchiveLog("relay-phase-insert").
    WAIT 1.
    RETURN executeManeuver().
}

LOCAL FUNCTION _circularizeCarrier {
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    planCircularize().
    WAIT 1.
    RETURN executeManeuver().
}

LOCAL FUNCTION _relayReleased {
    PARAMETER relayIdx.
    RETURN stateGet("relay_" + relayIdx + "_released", "") <> "".
}

LOCAL FUNCTION _relayPhaseInserted {
    PARAMETER relayIdx.
    RETURN stateGet("relay_" + relayIdx + "_phase_inserted", "") <> "".
}

LOCAL FUNCTION _relayPhaseComplete {
    PARAMETER relayIdx.
    RETURN stateGet("relay_" + relayIdx + "_phase_complete", "") <> "".
}

LOCAL FUNCTION _countReleasedRelays {
    PARAMETER relayCount.
    LOCAL count IS 0.
    LOCAL idx IS 1.
    UNTIL idx > relayCount {
        IF _relayReleased(idx) { SET count TO count + 1. }
        SET idx TO idx + 1.
    }
    RETURN count.
}

LOCAL FUNCTION _syncRelayDeployedCount {
    PARAMETER relayCount.
    LOCAL count IS _countReleasedRelays(relayCount).
    LOCAL oldCount IS stateGetNum("relay_deployed_count", 0).
    IF count <> oldCount { stateSet("relay_deployed_count", count). }
    RETURN count.
}

LOCAL FUNCTION _firstPendingPhase {
    PARAMETER relayCount.
    LOCAL idx IS 1.
    UNTIL idx >= relayCount {
        IF _relayReleased(idx) AND NOT _relayPhaseComplete(idx) { RETURN idx. }
        SET idx TO idx + 1.
    }
    RETURN 0.
}

LOCAL FUNCTION _ensureCircularBeforeDeploy {
    PARAMETER targetAlt.

    IF SHIP:ORBIT:ECCENTRICITY <= CIRCULAR_ECC_LIMIT { RETURN TRUE. }

    mLogWarn("Relay deploy entry orbit is eccentric (e="
        + ROUND(SHIP:ORBIT:ECCENTRICITY,4)
        + "); circularizing before release.").
    IF NOT _circularizeCarrier() { RETURN FALSE. }

    IF SHIP:ORBIT:ECCENTRICITY > CIRCULAR_ECC_LIMIT {
        mLogWarn("Circularization still eccentric: e="
            + ROUND(SHIP:ORBIT:ECCENTRICITY,4) + ".").
        RETURN FALSE.
    }

    LOCAL altErr IS ABS(SHIP:APOAPSIS - targetAlt).
    LOCAL altTol IS MAX(5000, targetAlt * 0.05).
    IF altErr > altTol {
        mLogWarn("Relay deploy circularized at ApKm="
            + ROUND(SHIP:APOAPSIS/1000,1)
            + " targetKm=" + ROUND(targetAlt/1000,1)
            + "; continuing from live orbit.").
    }
    RETURN TRUE.
}

LOCAL FUNCTION _looksLikePhasingOrbit {
    PARAMETER targetAlt.
    PARAMETER phasePeAlt.

    IF SHIP:ORBIT:ECCENTRICITY <= CIRCULAR_ECC_LIMIT { RETURN FALSE. }
    LOCAL apTol IS MAX(5000, targetAlt * 0.03).
    LOCAL peTol IS MAX(5000, MAX(ABS(phasePeAlt), targetAlt) * 0.05).
    RETURN ABS(SHIP:APOAPSIS - targetAlt) <= apTol
        AND ABS(SHIP:PERIAPSIS - phasePeAlt) <= peTol.
}

LOCAL FUNCTION _activateRelayHardware {
    PARAMETER relayIdx.

    LOCAL antCount IS _activateTaggedParts("relay_" + relayIdx + "_ant",
        "ModuleDeployableAntenna",
        LIST("extend antenna", "Extend Antenna", "Extend", "Deploy")).
    LOCAL solCount IS _activateTaggedParts("relay_" + relayIdx + "_sol",
        "ModuleDeployableSolarPanel",
        LIST("Extend Solar Panel", "extend solar panel", "Extend", "Deploy")).

    IF antCount = 0 {
        mLogWarn("Relay " + relayIdx + ": no tagged deployable antenna "
            + "'relay_" + relayIdx + "_ant' found.").
    }
    IF solCount = 0 {
        mLogWarn("Relay " + relayIdx + ": no tagged deployable solar panel "
            + "'relay_" + relayIdx + "_sol' found.").
    }
    RETURN antCount + solCount.
}

LOCAL FUNCTION _activateTaggedParts {
    PARAMETER tagName.
    PARAMETER moduleName.
    PARAMETER events.

    LOCAL parts IS SHIP:PARTSTAGGED(tagName).
    LOCAL activated IS 0.
    LOCAL unavailable IS 0.

    FOR partRef IN parts {
        IF partRef:HASMODULE(moduleName) {
            LOCAL modu IS partRef:GETMODULE(moduleName).
            LOCAL didEvent IS FALSE.
            FOR eventName IN events {
                IF NOT didEvent AND modu:HASEVENT(eventName) {
                    modu:DOEVENT(eventName).
                    SET didEvent TO TRUE.
                    SET activated TO activated + 1.
                }
            }
            IF NOT didEvent { SET unavailable TO unavailable + 1. }
        } ELSE {
            SET unavailable TO unavailable + 1.
        }
    }

    IF parts:LENGTH > 0 {
        mLog("Relay hardware tag '" + tagName + "': activated="
            + activated + " unavailable=" + unavailable + ".").
    }
    RETURN activated.
}

GLOBAL FUNCTION constellationStatus {
    PARAMETER relayCount.
    mLog("Constellation status:").
    LOCAL idx IS 1.
    UNTIL idx > relayCount {
        LOCAL releaseTime IS stateGet("relay_" + idx + "_released", "").
        IF releaseTime <> "" {
            LOCAL phaseText IS " phase-pending".
            IF _relayPhaseComplete(idx) { SET phaseText TO " phase-complete". }
            IF idx = relayCount { SET phaseText TO " final-slot". }
            mLog("  Relay " + idx + ": released at T+" + ROUND(releaseTime:TONUMBER(0),0) + "s" + phaseText).
        } ELSE {
            mLog("  Relay " + idx + ": not yet released").
        }
        SET idx TO idx + 1.
    }
}
