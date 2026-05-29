// ============================================================
// orbit.ks  —  Orbit monitoring helpers  (0:/lib/orbit.ks)
// ============================================================

GLOBAL FUNCTION isOrbitCircular {
    // True if eccentricity is below threshold
    PARAMETER threshold IS 0.01.
    RETURN SHIP:ORBIT:ECCENTRICITY < threshold.
}

GLOBAL FUNCTION isOrbitStable {
    // True if Pe and Ap are both above minAlt and orbit is closed
    PARAMETER minAlt IS 70000.  // above atmosphere by default
    RETURN SHIP:PERIAPSIS > minAlt AND SHIP:APOAPSIS > 0 AND SHIP:ORBIT:ECCENTRICITY < 0.05.
}

GLOBAL FUNCTION waitForSOI {
    // Block until ship enters target body's SOI
    PARAMETER targetBody.
    PARAMETER pollInterval IS 5.
    mLog("Waiting for SOI: " + targetBody:NAME).
    UNTIL SHIP:ORBIT:BODY:NAME = targetBody:NAME {
        WAIT pollInterval.
    }
    mLog("SOI entered: " + targetBody:NAME).
}

GLOBAL FUNCTION orbitSummary {
    // Log current orbit parameters
    mLog("Orbit: Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km  Ap=" + ROUND(SHIP:APOAPSIS/1000,1)
        + "km  ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)
        + "  inc=" + ROUND(SHIP:ORBIT:INCLINATION,2) + "°"
        + "  body=" + SHIP:ORBIT:BODY:NAME).
}
