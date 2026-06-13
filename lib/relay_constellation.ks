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
    mLog("Deploying " + relayCount + " relays at " + ROUND(targetAlt/1000,0)
        + "km around " + targetBody:NAME).

    LOCAL spacing IS 360 / relayCount.
    mLog("Angular spacing: " + ROUND(spacing,1) + "deg").

    LOCAL idx IS 1.
    UNTIL idx > relayCount {
        mLog("Deploying relay " + idx + " of " + relayCount).
        _deployOneRelay(idx, targetAlt, spacing, targetBody).
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
    PARAMETER targetAlt.
    PARAMETER spacing.
    PARAMETER targetBody.

    LOCAL targetTA IS (relayIdx - 1) * spacing.

    IF relayIdx > 1 {
        mLog("Waiting for TA=" + ROUND(targetTA,1) + "deg for relay " + relayIdx).
        HUDTEXT("Waiting for deploy position " + relayIdx, 3, 2, 13, WHITE, FALSE).
        WAIT UNTIL _trueAnomalyDiff(targetTA) < 1.0.
    }

    LOCAL tag IS "relay_" + relayIdx.
    LOCAL parts IS SHIP:PARTSTAGGED(tag).
    IF parts:LENGTH = 0 {
        mLogError("No part tagged '" + tag + "' — skipping relay " + relayIdx + ".").
        RETURN.
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
        RETURN.
    }

    WAIT 1.0.
    mLog("Relay " + relayIdx + " released at TA=" + ROUND(SHIP:ORBIT:TRUEANOMALY,1) + "deg"
        + "  alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km").
    stateSet("relay_" + relayIdx + "_released", TIME:SECONDS).
}

LOCAL FUNCTION _trueAnomalyDiff {
    PARAMETER targetTA.
    LOCAL currentTA IS SHIP:ORBIT:TRUEANOMALY.
    LOCAL diff IS targetTA - currentTA.
    IF diff < 0 { SET diff TO diff + 360. }
    RETURN diff.
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
