// ============================================================
// relay_constellation.ks  —  Multi-relay deployment
// (0:/lib/relay_constellation.ks)
// ============================================================

GLOBAL FUNCTION constellationDeploy {
    PARAMETER relayCount.
    PARAMETER targetAlt.
    PARAMETER bodyOverride IS "".

    LOCAL targetBody IS SHIP:ORBIT:BODY.
    IF bodyOverride <> "" { SET targetBody TO BODY(bodyOverride). }

    mLogPhase("CONSTELLATION DEPLOY").
    mLog("Deploying " + relayCount + " resonant relays at "
        + ROUND(targetAlt/1000,0) + "km around " + targetBody:NAME).

    LOCAL spacing IS 360 / relayCount.
    LOCAL phaseRatio IS (relayCount - 1) / relayCount.
    mLog("Angular spacing: " + ROUND(spacing,1)
        + "deg  phasing period ratio=" + ROUND(phaseRatio,3)).

    IF relayCount < 2 {
        mLogError("Constellation deploy requires at least two relays.").
        RETURN.
    }

    LOCAL idx IS 1.
    UNTIL idx > relayCount {
        mLog("Deploying relay " + idx + " of " + relayCount).
        IF NOT _deployOneRelay(idx) {
            mLogError("Relay " + idx + " was not deployed; holding.").
            yieldToPrompt().
            RETURN.
        }
        IF idx < relayCount {
            IF NOT _phaseCarrierOneSlot(relayCount, targetAlt, targetBody) {
                mLogError("Relay phasing failed after relay " + idx
                    + "; holding for operator review.").
                yieldToPrompt().
                RETURN.
            }
        }
        SET idx TO idx + 1.
    }

    mLog("Constellation deployment complete.").
    HUDTEXT("Constellation deployed!", 8, 2, 18, GREEN, FALSE).
}

GLOBAL FUNCTION phaseRelayConstellation {
    LOCAL relayCount IS 3.
    LOCAL targetAlt IS 500000.
    IF CFG:HASKEY("RELAY_COUNT") { SET relayCount TO CFG["RELAY_COUNT"]. }
    IF CFG:HASKEY("RELAY_ALT") { SET targetAlt TO CFG["RELAY_ALT"]. }
    ELSE IF CFG:HASKEY("TARGET_AP") { SET targetAlt TO CFG["TARGET_AP"]. }

    constellationDeploy(relayCount, targetAlt).
    nextPhase(xferSeq).
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
    RETURN TRUE.
}

LOCAL FUNCTION _phaseCarrierOneSlot {
    PARAMETER relayCount.
    PARAMETER targetAlt.
    PARAMETER targetBody.

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
        + " phasePeriod=" + ROUND(phasePeriod,0)).

    IF NOT _burnToPhasingOrbit(targetR, phaseSma, targetBody) {
        RETURN FALSE.
    }

    LOCAL coastEnd IS TIME:SECONDS + MAX(0, ETA:APOAPSIS - 120).
    mLog("Coasting one phasing orbit; next circularize in "
        + ROUND(ETA:APOAPSIS,0) + "s.").
    trySolarOrient().
    LOCAL solarRef IS -1.
    UNTIL TIME:SECONDS >= coastEnd {
        SET solarRef TO trySolarHoldTick(solarRef).
        WAIT MIN(60, MAX(1, coastEnd - TIME:SECONDS)).
    }

    IF NOT _circularizeCarrier() {
        RETURN FALSE.
    }

    mLogWarn("STATS relay-phase result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).
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
    archivePlannedManeuverLog("relay-phase-insert").
    WAIT 1.
    RETURN executeManeuver().
}

LOCAL FUNCTION _circularizeCarrier {
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    planCircularize().
    WAIT 1.
    RETURN executeManeuver().
}

GLOBAL FUNCTION constellationStatus {
    PARAMETER relayCount.
    mLog("Constellation status:").
    LOCAL idx IS 1.
    UNTIL idx > relayCount {
        LOCAL releaseTime IS stateGet("relay_" + idx + "_released", "").
        IF releaseTime <> "" {
            mLog("  Relay " + idx + ": released at T+" + ROUND(releaseTime:TONUMBER(0),0) + "s").
        } ELSE {
            mLog("  Relay " + idx + ": not yet released").
        }
        SET idx TO idx + 1.
    }
}
