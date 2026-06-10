// ============================================================
// inclination.ks  —  Orbital plane change  (0:/lib/inclination.ks)
// ============================================================

GLOBAL FUNCTION planInclinationChange {
    PARAMETER targetInc.

    LOCAL currentInc IS SHIP:ORBIT:INCLINATION.
    LOCAL deltaInc   IS targetInc - currentInc.

    IF deltaInc >  180 { SET deltaInc TO deltaInc - 360. }
    IF deltaInc < -180 { SET deltaInc TO deltaInc + 360. }

    mLog("Inclination change: current=" + ROUND(currentInc,2)
        + "deg  target=" + ROUND(targetInc,2)
        + "deg  delta=" + ROUND(deltaInc,2) + "deg").

    LOCAL angAN IS angleToBodyAscendingNode().
    IF angAN < 0 { SET angAN TO angAN + 360. }
    LOCAL etaAN IS (angAN / 360) * SHIP:ORBIT:PERIOD.
    LOCAL angDN IS angleToBodyDescendingNode().
    IF angDN < 0 { SET angDN TO angDN + 360. }
    LOCAL etaDN IS (angDN / 360) * SHIP:ORBIT:PERIOD.
    LOCAL etaAp IS ETA:APOAPSIS.

    LOCAL burnETA IS etaAN.
    LOCAL burnNormal IS 1.

    LOCAL anApDiff IS ABS(etaAN - etaAp).
    LOCAL dnApDiff IS ABS(etaDN - etaAp).
    IF dnApDiff < anApDiff {
        SET burnETA TO etaDN.
        SET burnNormal TO -1.
    }

    LOCAL usePe IS ABS(deltaInc) > 45.
    IF usePe {
        SET burnETA TO ETA:PERIAPSIS.
        mLog("Large inclination change — using Pe for combined burn.").
    }

    LOCAL burnUT IS TIME:SECONDS + burnETA.
    LOCAL vAtBurn IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.

    LOCAL dv IS 2 * vAtBurn * SIN(ABS(deltaInc) / 2).

    IF deltaInc < 0 { SET burnNormal TO -1. }

    LOCAL dvPrograde IS 0.
    LOCAL dvNormal   IS dv * burnNormal.

    IF usePe {
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
    mLogWarn("STATS inclination plan current=" + ROUND(currentInc,2)
        + " target=" + ROUND(targetInc,2)
        + " delta=" + ROUND(deltaInc,2)
        + " dv=" + ROUND(nd:DELTAV:MAG,1)
        + " normal=" + ROUND(dvNormal,1)
        + " prograde=" + ROUND(dvPrograde,1)
        + " eta=" + ROUND(burnETA,0)
        + " at=" + whichAt).
    archivePlannedManeuverLog("inclination").
    RETURN nd.
}

GLOBAL FUNCTION resolveTargetInclination {
    LOCAL target IS CFG["TARGET_INCLINATION"].
    IF target >= 0 { RETURN target. }

    LOCAL targetName IS CFG["INCL_MATCH_TARGET"].
    IF targetName = "" {
        mLogWarn("TARGET_INCLINATION=-1 but INCL_MATCH_TARGET is empty — defaulting to 0.").
        RETURN 0.
    }

    FOR ves IN ALLVESSELS() {
        IF ves:NAME = targetName {
            LOCAL inc IS ves:ORBIT:INCLINATION.
            mLog("Matching inclination to " + targetName + ": " + ROUND(inc,2) + "deg").
            RETURN inc.
        }
    }

    mLogWarn("Vessel '" + targetName + "' not found — defaulting to current inclination.").
    RETURN SHIP:ORBIT:INCLINATION.
}

// Seconds until the ship reaches the given true anomaly.
// Kepler-exact: converts both anomalies to MEAN anomaly (which
// does advance linearly in time). The old linear-TA version was
// only correct for circular orbits — flight-found on an ecc 0.58
// Mun ellipse, where it missed the plane-match node by tens of
// degrees and left a 27 deg residual after the burn.
GLOBAL FUNCTION etaToTrueAnomaly {
    PARAMETER targetTA.

    UNTIL targetTA >= 0   { SET targetTA TO targetTA + 360. }
    UNTIL targetTA < 360  { SET targetTA TO targetTA - 360. }

    LOCAL obtEcc IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL period IS SHIP:ORBIT:PERIOD.

    // Hyperbolic/parabolic: no meaningful period; legacy estimate.
    IF obtEcc >= 1 {
        LOCAL taToGo IS targetTA - SHIP:ORBIT:TRUEANOMALY.
        IF taToGo < 0 { SET taToGo TO taToGo + 360. }
        RETURN (taToGo / 360) * period.
    }

    LOCAL mNow IS _meanAnomalyDeg(SHIP:ORBIT:TRUEANOMALY, obtEcc).
    LOCAL mTgt IS _meanAnomalyDeg(targetTA, obtEcc).
    LOCAL dM IS mTgt - mNow.
    UNTIL dM >= 0   { SET dM TO dM + 360. }
    UNTIL dM < 360  { SET dM TO dM - 360. }
    RETURN (dM / 360) * period.
}

// True anomaly -> mean anomaly, degrees, ellipse only.
// tan(E/2) = sqrt((1-e)/(1+e)) tan(ta/2);  M = E - e sinE.
LOCAL FUNCTION _meanAnomalyDeg {
    PARAMETER ta, obtEcc.
    LOCAL eAnom IS 2 * ARCTAN2(
        SQRT(1 - obtEcc) * SIN(ta / 2),
        SQRT(1 + obtEcc) * COS(ta / 2)).
    RETURN eAnom - obtEcc * SIN(eAnom) * CONSTANT:RADTODEG.
}
