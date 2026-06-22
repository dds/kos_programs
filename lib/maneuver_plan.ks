// ============================================================
// maneuver_plan.ks  —  Single-burn node planners  (0:/lib/maneuver_plan.ks)
//
// Split out of maneuver.ks: these closed-form planners build a
// maneuver node and hand off to executeManeuver (which lives in
// maneuver.ks). Only phases that actually shape an orbit need them
// (CIRC/RAISE/INCLINE/ELLIPTICAL, CAPTURE, launch/ssto circularize,
// Duna entry, relay/payload circularize) — keeping them out of
// maneuver.ks keeps the executor lean for burn-only bands such as
// BPLANE/SHAPE that import maneuver but never plan a single burn.
// ============================================================

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

// Speed at a given radius ON THE SHIP'S CURRENT ORBIT — pure
// vis-viva from the live elements, zero future-state prediction.
// Flight-found (twice): both VELOCITYAT and POSITIONAT-difference
// predictions are contaminated by the parent body's own motion in
// this kOS build (~60-500 m/s at the Mun), which flipped planned
// burns retrograde. Orbit elements cannot lie.
LOCAL FUNCTION _sar {
    PARAMETER rBurn.
    RETURN SQRT(SHIP:BODY:MU
        * (2 / rBurn - 1 / SHIP:ORBIT:SEMIMAJORAXIS)).
}

GLOBAL FUNCTION planCircularize {
    LOCAL ea IS ETA:APOAPSIS.
    LOCAL mu  IS SHIP:ORBIT:BODY:MU.
    LOCAL vc IS SQRT(mu / (SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS)).
    LOCAL vn  IS _sar(SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS).
    LOCAL dv    IS vc - vn.

    LOCAL nd IS NODE(TIME:SECONDS + ea, 0, 0, dv).
    ADD nd.
    mLog("Circularize node: dV=" + ROUND(dv,1) + " m/s at Ap in " + ROUND(ea,0) + "s").
    mLog("STATS circularize plan dv=" + ROUND(dv,1)
        + " eta=" + ROUND(ea,0)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    maneuverUiArchiveLog("circularize").
    RETURN nd.
}

GLOBAL FUNCTION planCapture {
    PARAMETER tb.
    PARAMETER ta.
    LOCAL mu    IS tb:MU.
    LOCAL rp   IS tb:RADIUS + SHIP:PERIAPSIS.
    LOCAL ra   IS tb:RADIUS + ta.
    LOCAL ts  IS (rp + ra) / 2.
    LOCAL vc IS SQRT(mu * (2/rp - 1/ts)).
    LOCAL vp    IS _sar(rp).
    LOCAL dv       IS vc - vp.
    LOCAL nd IS NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, dv).
    ADD nd.
    mLog("Capture node: dV=" + ROUND(dv,1)
        + " m/s at Pe in " + ROUND(ETA:PERIAPSIS,0)
        + "s  targetAp=" + ROUND(ta/1000,1) + "km").
    mLog("STATS capture plan target=" + tb:NAME
        + " dv=" + ROUND(dv,1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " targetApKm=" + ROUND(ta/1000,1)
        + " etaPe=" + ROUND(ETA:PERIAPSIS,0)).
    maneuverUiArchiveLog("capture").
    RETURN nd.
}

GLOBAL FUNCTION planRaisePeNow {
    PARAMETER tp.
    LOCAL mu   IS SHIP:ORBIT:BODY:MU.
    LOCAL rn IS SHIP:ORBIT:BODY:RADIUS + SHIP:ALTITUDE.
    LOCAL rp  IS SHIP:ORBIT:BODY:RADIUS + tp.
    LOCAL vn IS SHIP:VELOCITY:ORBIT:MAG.
    LOCAL ts IS (rn + rp) / 2.
    LOCAL vv IS SQRT(mu * (2/rn - 1/ts)).
    LOCAL dv   IS vv - vn.
    LOCAL lead IS 60.
    IF ABS(dv) > 100 { SET lead TO 90. }
    IF ABS(dv) > 300 { SET lead TO 120. }
    LOCAL nd IS NODE(TIME:SECONDS + lead, 0, 0, dv).
    ADD nd.
    mLog("Raise Pe node: dV=" + ROUND(dv,1)
        + " m/s  targetPe=" + ROUND(tp/1000,1) + "km").
    mLog("STATS raise-pe plan dv=" + ROUND(dv,1)
        + " targetPeKm=" + ROUND(tp/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    maneuverUiArchiveLog("raise-pe").
    RETURN nd.
}

GLOBAL FUNCTION planLowerPe {
    PARAMETER tp.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL br IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL bt IS TIME:SECONDS + ETA:APOAPSIS.
    LOCAL rb IS br + SHIP:APOAPSIS.
    LOCAL rt IS br + tp.
    LOCAL ts IS (rb + rt) / 2.
    LOCAL vn IS _sar(rb).
    LOCAL vv IS SQRT(mu * (2 / rb - 1 / ts)).
    LOCAL nd IS NODE(bt, 0, 0, vv - vn).
    ADD nd.
    mLog("Lower Pe node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPe=" + ROUND(tp/1000,1) + "km").
    mLog("STATS lower-pe plan dv=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPeKm=" + ROUND(tp/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " etaAp=" + ROUND(ETA:APOAPSIS,0)).
    maneuverUiArchiveLog("lower-pe").
    RETURN nd.
}

GLOBAL FUNCTION planAoPChange {
    PARAMETER taop.
    LOCAL caop IS SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    LOCAL da IS taop - caop.
    IF da > 180  { SET da TO da - 360. }
    IF da < -180 { SET da TO da + 360. }
    IF ABS(da) < 2 { RETURN 0. }
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL a  IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL e  IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL h  IS SQRT(mu * a * (1 - e^2)).
    // Exact apsidal rotation: orbits with equal a,e rotated by
    // deltaAoP intersect at ta = deltaAoP/2 (+180). The required
    // radial-out impulse there is -2(mu/h) e sin(deltaAoP/2) —
    // SIGNED by deltaAoP (flight-found: the old hardcoded sign
    // was correct for positive rotations only; a -64 deg rotation
    // burned the wrong way and sent AoP to 17 instead of 269).
    LOCAL dv1 IS -2 * (mu / h) * e * SIN(da / 2).
    LOCAL t1 IS da / 2.
    LOCAL t2 IS t1 + 180.
    LOCAL e1 IS etaToTrueAnomaly(t1).
    LOCAL e2 IS etaToTrueAnomaly(t2).
    LOCAL be IS e1.
    LOCAL dr IS dv1.
    IF e2 < e1 {
        SET be TO e2.
        SET dr TO -dv1.
    }
    LOCAL bu IS TIME:SECONDS + be.
    LOCAL nd IS NODE(bu, dr, 0, 0).
    ADD nd.
    mLog("AoP node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s  targetAoP=" + ROUND(taop,1)
        + " ETA=" + ROUND(be,0) + "s").
    maneuverUiArchiveLog("aop").
    RETURN nd.
}
