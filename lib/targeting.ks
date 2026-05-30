// ============================================================
// targeting.ks  —  Precision deorbit targeting  (0:/lib/targeting.ks)
// ============================================================

GLOBAL FUNCTION targetedDeorbit {
    IF NOT ADDONS:TR:AVAILABLE {
        mLogWarn("Trajectories not available — falling back to planLowerPe.").
        planLowerPe(CFG["PROBE_ENTRY_PE"]).
        executeManeuver().
        RETURN.
    }

    LOCAL targetLat IS CFG["PROBE_TARGET_LAT"].
    LOCAL targetLng IS CFG["PROBE_TARGET_LNG"].
    LOCAL entryPe   IS 30000.
    IF CFG:HASKEY("PROBE_ENTRY_PE") { SET entryPe TO CFG["PROBE_ENTRY_PE"]. }
    LOCAL tolerance IS 5000.
    IF CFG:HASKEY("PROBE_TARGET_TOL") { SET tolerance TO CFG["PROBE_TARGET_TOL"]. }

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
        + "  entryPe=" + ROUND(entryPe/1000,1) + "km"
        + "  tolerance=" + ROUND(tolerance/1000,1) + "km").
    HUDTEXT("Searching deorbit window...", 3, 2, 13, CYAN, FALSE).

    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL scanStep  IS period / 72.
    LOCAL passes    IS LIST(1.0, 0.1, 0.01, 0.001, 0.0001).

    LOCAL bestUT   IS TIME:SECONDS + 30.
    LOCAL bestDist IS 999999999.

    LOCAL scanUT  IS TIME:SECONDS + 30.
    LOCAL scanEnd IS TIME:SECONDS + period + 30.
    UNTIL scanUT > scanEnd {
        LOCAL dist IS _testDeorbitNode(scanUT, entryPe, targetLat, targetLng).
        IF dist >= 0 AND dist < bestDist {
            SET bestDist TO dist.
            SET bestUT   TO scanUT.
            mLog("DEBUG coarse: T+" + ROUND(scanUT - TIME:SECONDS,0)
                + "s  dist=" + ROUND(dist/1000,1) + "km").
        }
        SET scanUT TO scanUT + scanStep.
        WAIT 0.1.
    }
    mLog("Coarse best: T+" + ROUND(bestUT - TIME:SECONDS,0)
        + "s  dist=" + ROUND(bestDist/1000,1) + "km").

    FOR mult IN passes:SUBLIST(1, passes:LENGTH - 1) {
        LOCAL step    IS scanStep * mult.
        LOCAL winStart IS bestUT - (scanStep * (mult * 10)).
        LOCAL winEnd   IS bestUT + (scanStep * (mult * 10)).
        LOCAL passUT   IS winStart.
        LOCAL passBest IS bestDist.
        LOCAL passBestUT IS bestUT.

        UNTIL passUT > winEnd {
            LOCAL dist IS _testDeorbitNode(passUT, entryPe, targetLat, targetLng).
            IF dist >= 0 AND dist < passBest {
                SET passBest   TO dist.
                SET passBestUT TO passUT.
            }
            SET passUT TO passUT + step.
            WAIT 0.05.
        }

        SET bestDist TO passBest.
        SET bestUT   TO passBestUT.
        mLog("Pass step=" + ROUND(step,2) + "s  best dist=" + ROUND(bestDist,0) + "m"
            + "  T+" + ROUND(bestUT - TIME:SECONDS,0) + "s").

        IF bestDist < tolerance { BREAK. }
    }

    mLog("Fine best: T+" + ROUND(bestUT - TIME:SECONDS,0)
        + "s  dist=" + ROUND(bestDist/1000,1) + "km").

    IF bestDist > tolerance {
        mLogWarn("Best solution misses target by " + ROUND(bestDist/1000,1)
            + "km — exceeds tolerance of " + ROUND(tolerance/1000,1) + "km.").
        mLogWarn("Proceeding anyway — check orbital inclination vs target latitude.").
        HUDTEXT("Warning: " + ROUND(bestDist/1000,0) + "km from target", 5, 2, 14, YELLOW, FALSE).
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }

    LOCAL realNode IS _planDeorbitNode(bestUT, entryPe).
    mLog("Executing deorbit burn at T+" + ROUND(bestUT - TIME:SECONDS,0) + "s.").
    HUDTEXT("Deorbit burn in " + ROUND(bestUT - TIME:SECONDS,0) + "s", 3, 2, 13, CYAN, FALSE).

    executeManeuver().

    WAIT 2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL finalDist IS _geoDistance(impactPos:LAT, impactPos:LNG, targetLat, targetLng).
        mLog("Post-burn impact prediction: "
            + ROUND(impactPos:LAT,4) + "," + ROUND(impactPos:LNG,4)
            + "  dist=" + ROUND(finalDist/1000,1) + "km from target").
        HUDTEXT("Impact predicted " + ROUND(finalDist/1000,1) + "km from target",
            5, 2, 14, GREEN, FALSE).
    } ELSE {
        mLogWarn("Trajectories has no impact prediction post-burn.").
    }
}

LOCAL FUNCTION _testDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER targetLat.
    PARAMETER targetLng.

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }

    LOCAL nd IS _planDeorbitNode(burnUT, entryPe).
    WAIT 0.5.

    IF NOT ADDONS:TR:HASIMPACT {
        REMOVE nd.
        RETURN -1.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS _geoDistance(impactPos:LAT, impactPos:LNG, targetLat, targetLng).

    REMOVE nd.
    RETURN dist.
}

LOCAL FUNCTION _planDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.

    LOCAL mu   IS SHIP:ORBIT:BODY:MU.
    LOCAL oRad IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL rPe  IS SHIP:ORBIT:BODY:RADIUS + entryPe.
    LOCAL tSMA IS (oRad + rPe) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2/oRad - 1/tSMA)).
    LOCAL dv   IS vNew - vNow.

    LOCAL nd IS NODE(burnUT, 0, 0, dv).
    ADD nd.
    RETURN nd.
}

LOCAL FUNCTION _geoDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    LOCAL oRad IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL dLat IS lat2 - lat1.
    LOCAL dLng IS lng2 - lng1.
    LOCAL a    IS SIN(dLat/2)^2
               + COS(lat1) * COS(lat2) * SIN(dLng/2)^2.
    LOCAL c    IS 2 * ARCSIN(MIN(1, SQRT(a))).
    RETURN oRad * c * CONSTANT:PI / 180.
}

GLOBAL FUNCTION targetReachable {
    PARAMETER targetLat.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    IF inc > 90 { SET inc TO 180 - inc. }
    RETURN ABS(targetLat) <= inc + 0.5.
}
