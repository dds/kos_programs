// ============================================================
// Inclination change functions — add to maneuver.ks
// ============================================================

// ── Plan inclination change ────────────────────────────────
// Finds best node (AN or DN, preferring near Ap for efficiency)
// and creates a normal/anti-normal burn node.
// For large changes (>45deg) uses combined burn at Pe.
// Returns the node.

GLOBAL FUNCTION planInclinationChange {
    PARAMETER targetInc.  // degrees

    LOCAL currentInc IS SHIP:ORBIT:INCLINATION.
    LOCAL deltaInc   IS targetInc - currentInc.

    // Normalize delta to -180..180
    IF deltaInc >  180 { SET deltaInc TO deltaInc - 360. }
    IF deltaInc < -180 { SET deltaInc TO deltaInc + 360. }

    mLog("Inclination change: current=" + ROUND(currentInc,2)
        + "deg  target=" + ROUND(targetInc,2)
        + "deg  delta=" + ROUND(deltaInc,2) + "deg").

    // Find AN and DN ETAs
    LOCAL etaAN IS _etaToTrueAnomaly(SHIP:ORBIT:LAN - SHIP:ORBIT:ARGUMENTOFPERIAPSIS).
    LOCAL etaDN IS _etaToTrueAnomaly(SHIP:ORBIT:LAN - SHIP:ORBIT:ARGUMENTOFPERIAPSIS + 180).
    LOCAL etaAp IS ETA:APOAPSIS.

    // Pick node closest to Ap (lowest velocity = cheapest burn)
    LOCAL burnETA IS etaAN.
    LOCAL burnNormal IS 1.  // +1 = normal, -1 = antinormal

    // AN vs DN — pick whichever is closer to Ap
    LOCAL anApDiff IS ABS(etaAN - etaAp).
    LOCAL dnApDiff IS ABS(etaDN - etaAp).
    IF dnApDiff < anApDiff {
        SET burnETA TO etaDN.
    }

    // For large inclination changes use Pe (combined burn more efficient)
    LOCAL usePe IS ABS(deltaInc) > 45.
    IF usePe {
        SET burnETA TO ETA:PERIAPSIS.
        mLog("Large inclination change — using Pe for combined burn.").
    }

    LOCAL burnUT IS TIME:SECONDS + burnETA.
    LOCAL vAtBurn IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.

    // Pure plane change dV = 2 * v * sin(deltaInc/2)
    LOCAL dv IS 2 * vAtBurn * SIN(ABS(deltaInc) / 2).

    // Normal direction: positive = raise inclination, negative = lower
    IF deltaInc < 0 { SET burnNormal TO -1. }

    // For combined burn at Pe, split into prograde + normal components
    LOCAL dvPrograde IS 0.
    LOCAL dvNormal   IS dv * burnNormal.

    IF usePe {
        // Combined: rotate velocity vector by deltaInc degrees
        LOCAL vPe IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG.
        SET dvPrograde TO vPe * (COS(deltaInc) - 1).
        SET dvNormal   TO vPe * SIN(deltaInc).
    }

    LOCAL nd IS NODE(burnUT, 0, dvNormal, dvPrograde).
    ADD nd.

    LOCAL whichAt IS "".
    IF usePe {
        SET whichAt TO "Periapsis".
    } else {
        SET whichAt TO "AN/DN near Apoapsis".
    }
    mLog("Inclination node: dV=" + ROUND(dv,1) + " m/s"
        + "  normal=" + ROUND(dvNormal,1)
        + "  prograde=" + ROUND(dvPrograde,1)
        + "  ETA=" + ROUND(burnETA,0) + "s"
        + "  at=" + whichAt).
    RETURN nd.
}

// ── Resolve target inclination ─────────────────────────────
// Call this in _phaseInclCorrect to get the target inclination
// from config — handles the three cases:
//   CFG["TARGET_INCLINATION"] = -1 → match named vessel
//   CFG["TARGET_INCLINATION"] >= 0 → use that value
GLOBAL FUNCTION resolveTargetInclination {
    LOCAL target IS CFG["TARGET_INCLINATION"].
    IF target >= 0 { RETURN target. }

    // Match named vessel
    LOCAL targetName IS CFG["INCL_MATCH_TARGET"].
    IF targetName = "" {
        mLogWarn("TARGET_INCLINATION=-1 but INCL_MATCH_TARGET is empty — defaulting to 0.").
        RETURN 0.
    }

    // Find vessel by name
    FOR v IN ALLVESSELS() {
        IF v:NAME = targetName {
            LOCAL inc IS v:ORBIT:INCLINATION.
            mLog("Matching inclination to " + targetName + ": " + ROUND(inc,2) + "deg").
            RETURN inc.
        }
    }

    mLogWarn("Vessel '" + targetName + "' not found — defaulting to current inclination.").
    RETURN SHIP:ORBIT:INCLINATION.
}

// ── ETA to a given true anomaly ────────────────────────────
LOCAL FUNCTION _etaToTrueAnomaly {
    PARAMETER targetTA.

    // Normalize targetTA to 0-360
    UNTIL targetTA >= 0   { SET targetTA TO targetTA + 360. }
    UNTIL targetTA < 360  { SET targetTA TO targetTA - 360. }

    LOCAL currentTA IS SHIP:ORBIT:TRUEANOMALY.
    LOCAL taToGo IS targetTA - currentTA.
    IF taToGo < 0 { SET taToGo TO taToGo + 360. }

    // Convert angle to time using mean motion
    LOCAL period IS SHIP:ORBIT:PERIOD.
    RETURN (taToGo / 360) * period.
}
