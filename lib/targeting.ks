// ============================================================
// targeting.ks  —  Precision deorbit targeting  (0:/lib/targeting.ks)
//
// Uses Trajectories addon to find the correct deorbit burn
// timing and Pe to hit a specific lat/lng on an atmospheric
// or airless body from a circular orbit.
//
// Algorithm:
//   1. Scan orbital positions by placing test deorbit nodes
//   2. Check ADDONS:TR:IMPACTPOS after each node
//   3. Converge on the node that puts impact closest to target
//   4. Execute the burn, release probe
//
// Requires: maneuver.ks, logs.ks loaded first.
// Requires: Trajectories mod installed.
// ============================================================

// ── Config defaults ────────────────────────────────────────
// Override in CFG before calling targetedDeorbit()
// CFG["PROBE_TARGET_LAT"]   — target latitude
// CFG["PROBE_TARGET_LNG"]   — target longitude  
// CFG["PROBE_ENTRY_PE"]     — Pe for deorbit trajectory (m above surface)
//                             atmospheric: 25000-35000m for clean entry
//                             airless: -1000m for guaranteed impact
// CFG["PROBE_TARGET_TOL"]   — acceptable miss distance in meters (default 5000)

GLOBAL FUNCTION targetedDeorbit {
    // Main entry — plans and executes a targeted deorbit burn.
    // Call this instead of planLowerPe for precision targeting.
    // After this returns, call _releaseProbe as normal.

    IF NOT ADDONS:TR:AVAILABLE {
        mLogWarn("Trajectories not available — falling back to planLowerPe.").
        planLowerPe(CFG["PROBE_IMPACT_PE"]).
        executeManeuver().
        RETURN.
    }

    LOCAL targetLat IS CFG["PROBE_TARGET_LAT"].
    LOCAL targetLng IS CFG["PROBE_TARGET_LNG"].
    LOCAL entryPe   IS CFG:HASKEY("PROBE_ENTRY_PE") ? CFG["PROBE_ENTRY_PE"] : 30000.
    LOCAL tolerance IS CFG:HASKEY("PROBE_TARGET_TOL") ? CFG["PROBE_TARGET_TOL"] : 5000.

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
        + "  entryPe=" + ROUND(entryPe/1000,1) + "km"
        + "  tolerance=" + ROUND(tolerance/1000,1) + "km").
    HUDTEXT("Searching deorbit window...", 3, 2, 13, CYAN, FALSE).

    // ── Coarse scan — one full orbit in steps ──────────────
    LOCAL period    IS SHIP:ORBIT:PERIOD.
    LOCAL scanStep  IS period / 36.  // 36 steps = 10 degree increments
    LOCAL bestUT    IS -1.
    LOCAL bestDist  IS 999999999.
    LOCAL scanUT    IS TIME:SECONDS + 30.  // start 30s from now
    LOCAL scanEnd   IS TIME:SECONDS + period + 30.

    mLog("Coarse scan: " + ROUND(period/60,1) + " min orbit, " + ROUND(scanStep,0) + "s steps.").

    UNTIL scanUT > scanEnd {
        LOCAL dist IS _testDeorbitNode(scanUT, entryPe, targetLat, targetLng).
        IF dist >= 0 AND dist < bestDist {
            SET bestDist TO dist.
            SET bestUT   TO scanUT.
            mLog("DEBUG coarse: T+" + ROUND(scanUT - TIME:SECONDS,0)
                + "s  dist=" + ROUND(dist/1000,1) + "km").
        }
        SET scanUT TO scanUT + scanStep.
        WAIT 0.1.  // yield to physics
    }

    IF bestUT < 0 {
        mLogError("targetedDeorbit: no valid deorbit window found. Falling back.").
        planLowerPe(CFG["PROBE_IMPACT_PE"]).
        executeManeuver().
        RETURN.
    }

    mLog("Coarse best: T+" + ROUND(bestUT - TIME:SECONDS,0)
        + "s  dist=" + ROUND(bestDist/1000,1) + "km").

    // ── Fine scan — narrow window around best coarse result ─
    LOCAL fineStep IS scanStep / 10.
    LOCAL fineStart IS bestUT - scanStep.
    LOCAL fineEnd   IS bestUT + scanStep.
    LOCAL fineUT    IS fineStart.

    UNTIL fineUT > fineEnd {
        LOCAL dist IS _testDeorbitNode(fineUT, entryPe, targetLat, targetLng).
        IF dist >= 0 AND dist < bestDist {
            SET bestDist TO dist.
            SET bestUT   TO fineUT.
        }
        SET fineUT TO fineUT + fineStep.
        WAIT 0.05.
    }

    mLog("Fine best: T+" + ROUND(bestUT - TIME:SECONDS,0)
        + "s  dist=" + ROUND(bestDist/1000,1) + "km").

    IF bestDist > tolerance {
        mLogWarn("Best solution misses target by " + ROUND(bestDist/1000,1)
            + "km — exceeds tolerance of " + ROUND(tolerance/1000,1) + "km.").
        mLogWarn("Proceeding anyway — check orbital inclination vs target latitude.").
        HUDTEXT("Warning: " + ROUND(bestDist/1000,0) + "km from target", 5, 2, 14, YELLOW, FALSE).
    }

    // ── Clean up test nodes and place real burn node ───────
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }

    LOCAL realNode IS _planDeorbitNode(bestUT, entryPe).
    mLog("Executing deorbit burn at T+" + ROUND(bestUT - TIME:SECONDS,0) + "s.").
    HUDTEXT("Deorbit burn in " + ROUND(bestUT - TIME:SECONDS,0) + "s", 3, 2, 13, CYAN, FALSE).

    executeManeuver().

    // ── Post-burn Trajectories verification ───────────────
    WAIT 2.  // let Trajectories update
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

// ── Place a test node and check Trajectories impact ────────
LOCAL FUNCTION _testDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER targetLat.
    PARAMETER targetLng.

    // Remove any existing test node
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }

    // Plan deorbit node
    LOCAL nd IS _planDeorbitNode(burnUT, entryPe).
    WAIT 0.2.  // let Trajectories update prediction

    IF NOT ADDONS:TR:HASIMPACT {
        REMOVE nd.
        RETURN -1.  // no prediction
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS _geoDistance(impactPos:LAT, impactPos:LNG, targetLat, targetLng).

    REMOVE nd.
    RETURN dist.
}

// ── Plan a deorbit node at a specific UT ──────────────────
LOCAL FUNCTION _planDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.

    LOCAL mu    IS SHIP:ORBIT:BODY:MU.
    LOCAL r     IS SHIP:ORBIT:BODY:RADIUS + SHIP:ORBIT:APOAPSIS. // circular orbit radius
    LOCAL rPe   IS SHIP:ORBIT:BODY:RADIUS + entryPe.
    LOCAL tSMA  IS (r + rPe) / 2.
    LOCAL vCirc IS SQRT(mu / r).
    LOCAL vNew  IS SQRT(mu * (2/r - 1/tSMA)).
    LOCAL dv    IS vNew - vCirc.  // negative = retrograde

    LOCAL nd IS NODE(burnUT, 0, 0, dv).
    ADD nd.
    RETURN nd.
}

// ── Great circle distance between two lat/lng points ──────
LOCAL FUNCTION _geoDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    // Haversine formula
    LOCAL R    IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL dLat IS (lat2 - lat1) * CONSTANT:PI / 180.
    LOCAL dLng IS (lng2 - lng1) * CONSTANT:PI / 180.
    LOCAL a    IS SIN(dLat/2)^2
               + COS(lat1 * CONSTANT:PI/180)
               * COS(lat2 * CONSTANT:PI/180)
               * SIN(dLng/2)^2.
    LOCAL c    IS 2 * ARCSIN(MIN(1, SQRT(a))).
    RETURN R * c * CONSTANT:PI / 180.  // meters
}

// ── Check if target is reachable from current inclination ─
GLOBAL FUNCTION targetReachable {
    PARAMETER targetLat.
    // A target latitude is reachable if it's within the orbital inclination
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    // Handle retrograde orbits
    IF inc > 90 { SET inc TO 180 - inc. }
    RETURN ABS(targetLat) <= inc + 0.5.  // 0.5 degree margin
}
