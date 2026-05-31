// ============================================================
// molniya.ks  —  Molniya orbit planning library  (0:/lib/molniya.ks)
//
// A Molniya orbit is a highly elliptical orbit (typically e ≈ 0.74)
// with a period that is a fraction of the parent body's rotation
// (classically 12 hours for Earth / 3 hours for Kerbin). The high
// eccentricity means the satellite spends most of its time near
// apoapsis ("dwell time"), providing long coverage windows over
// a specific hemisphere.
//
// The argument of periapsis (AoP) determines which hemisphere
// gets the dwell time:
//   AoP ≈ 270° → apoapsis over the northern hemisphere (Earth standard)
//   AoP ≈ 90°  → apoapsis over the southern hemisphere
//   AoP ≤ 180° → southern dwell
//   AoP > 180° → northern dwell
//
// Real-world Molniya orbits use a critical inclination of 63.4° to
// prevent apsidal precession (rotation of the AoP over time). In KSP,
// there is no J2 oblateness perturbation, so any inclination works and
// the AoP remains constant.
//
// References:
//   https://en.wikipedia.org/wiki/Molniya_orbit
//   https://en.wikipedia.org/wiki/Argument_of_periapsis
//   https://en.wikipedia.org/wiki/Hohmann_transfer_orbit (for the 2-burn method)
//
// Functions:
//   molniyaParams()         — compute orbital elements from config
//   printMolniyaSummary()   — config screen summary block
//   planMolniyaInsert()     — plan 2-burn insertion maneuver
//   phaseMolniyaInsert()    — phase machine entry point
// ============================================================

// molniyaParams — compute the orbital elements of a Molniya orbit.
//
// Accepts up to three constraints; any two are sufficient to define the orbit:
//   - targetPeriod: orbital period in seconds
//   - targetEcc:    eccentricity (0 to 1)
//   - fallbackPeAlt: periapsis altitude in meters (defaults to current periapsis)
//
// The math is basic Keplerian orbital mechanics:
//   Period = 2π √(a³/μ)  →  a = (μ (P/2π)²)^(1/3)    (Kepler's 3rd law)
//   Pe = a(1-e),  Ap = a(1+e)                          (apsides from SMA and ecc)
//   e = (Ap - Pe) / (Ap + Pe)                          (ecc from apsides)
//
// Three modes depending on which inputs are provided:
//   "period+ecc" — both period and eccentricity given → fully constrained
//   "ecc"        — eccentricity given, use Pe to derive period
//   "period"     — period given, use Pe to derive eccentricity
GLOBAL FUNCTION molniyaParams {
    PARAMETER targetPeriod.
    PARAMETER targetEcc.
    PARAMETER fallbackPeAlt IS -1.

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyRadius IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL semiMajorAxis IS 0.
    LOCAL periapsisRadius IS 0.
    LOCAL apoapsisRadius IS 0.
    LOCAL eccentricity IS 0.
    LOCAL period IS 0.
    LOCAL mode IS "period".

    IF targetEcc > 0 AND targetPeriod > 0 {
        // Mode: period+ecc — both constraints given, fully determined.
        // Derive SMA from period via Kepler's third law, then apsides from e.
        SET semiMajorAxis TO (mu * (targetPeriod / (2 * CONSTANT:PI))^2)^(1/3).
        SET periapsisRadius TO semiMajorAxis * (1 - targetEcc).
        SET apoapsisRadius TO 2 * semiMajorAxis - periapsisRadius.
        SET eccentricity TO targetEcc.
        SET period TO targetPeriod.
        SET mode TO "period+ecc".
    } ELSE IF targetEcc > 0 {
        // Mode: ecc — eccentricity given, use periapsis to derive SMA.
        // SMA = Pe / (1 - e), then period from Kepler's third law.
        LOCAL periapsisAlt IS fallbackPeAlt.
        IF periapsisAlt < 0 { SET periapsisAlt TO SHIP:PERIAPSIS. }
        SET periapsisRadius TO bodyRadius + periapsisAlt.
        SET semiMajorAxis TO periapsisRadius / (1 - targetEcc).
        SET apoapsisRadius TO 2 * semiMajorAxis - periapsisRadius.
        SET eccentricity TO targetEcc.
        SET period TO 2 * CONSTANT:PI * SQRT(semiMajorAxis^3 / mu).
        SET mode TO "ecc".
    } ELSE {
        // Mode: period — period given, use periapsis to derive eccentricity.
        // Derive SMA from period, then e = (Ap - Pe) / (Ap + Pe).
        LOCAL periapsisAlt IS fallbackPeAlt.
        IF periapsisAlt < 0 { SET periapsisAlt TO SHIP:PERIAPSIS. }
        SET periapsisRadius TO bodyRadius + periapsisAlt.
        SET semiMajorAxis TO (mu * (targetPeriod / (2 * CONSTANT:PI))^2)^(1/3).
        SET apoapsisRadius TO 2 * semiMajorAxis - periapsisRadius.
        SET eccentricity TO (apoapsisRadius - periapsisRadius)
            / (apoapsisRadius + periapsisRadius).
        SET period TO targetPeriod.
    }

    RETURN LEXICON(
        "SMA", semiMajorAxis,
        "PeR", periapsisRadius,
        "ApR", apoapsisRadius,
        "ecc", eccentricity,
        "period", period,
        "mode", mode,
        "peAlt", periapsisRadius - bodyRadius,
        "apAlt", apoapsisRadius - bodyRadius
    ).
}

// printMolniyaSummary — display Molniya orbit parameters on the config screen.
//
// Called during the pre-launch countdown to show what the Molniya insertion
// will target. Reads from CFG["MOLNIYA_PERIOD"], CFG["MOLNIYA_ECC"],
// CFG["MOLNIYA_AOP"], and CFG["PARKING_ALT"].
GLOBAL FUNCTION printMolniyaSummary {
    LOCAL eccentricity IS -1.
    IF CFG:HASKEY("MOLNIYA_ECC") AND CFG["MOLNIYA_ECC"] > 0 {
        SET eccentricity TO CFG["MOLNIYA_ECC"].
    }
    LOCAL mp IS molniyaParams(CFG["MOLNIYA_PERIOD"], eccentricity, CFG["PARKING_ALT"]).

    // Format the period as hours:minutes:seconds for readability
    LOCAL totalSeconds IS mp["period"].
    LOCAL hours IS FLOOR(totalSeconds / 3600).
    LOCAL minutes IS FLOOR(MOD(totalSeconds, 3600) / 60).
    LOCAL seconds IS ROUND(MOD(totalSeconds, 60), 0).

    // Determine which hemisphere gets the long dwell time based on AoP.
    // AoP > 180° puts periapsis in the southern hemisphere, so apoapsis
    // (where the satellite lingers) is in the north, and vice versa.
    LOCAL dwellHemisphere IS "North".
    IF CFG["MOLNIYA_AOP"] <= 180 { SET dwellHemisphere TO "South". }

    PRINT " ".
    PRINT "  -- MOLNIYA (" + mp["mode"] + ") --".
    PRINT "  PERIOD .... " + hours + "h" + ("" + minutes):PADLEFT(2) + "m"
        + ("" + seconds):PADLEFT(2) + "s".
    PRINT "  AoP ....... " + CFG["MOLNIYA_AOP"] + " deg  (" + dwellHemisphere + " dwell)".
    PRINT "  TARGET Pe . " + ROUND(mp["peAlt"]/1000,0) + " km".
    PRINT "  TARGET Ap . " + ROUND(mp["apAlt"]/1000,0) + " km".
    PRINT "  TARGET ecc  " + ROUND(mp["ecc"],4).
}

// planMolniyaInsert — plan a two-burn Hohmann-like insertion into a Molniya orbit.
//
// The insertion uses two burns:
//   Burn 1: At the point in the current orbit corresponding to where periapsis
//           will be in the final Molniya orbit (determined by targetAoP), burn
//           prograde to raise apoapsis to the Molniya apoapsis.
//   Burn 2: At the new apoapsis (half an orbit later), burn prograde to raise
//           periapsis to match the Molniya orbit's periapsis (if needed) and
//           set the correct period.
//
// This is essentially a Hohmann transfer where the "target orbit" is the
// Molniya orbit itself. The burn point is chosen to set the argument of
// periapsis correctly — by burning at the true anomaly where the Molniya's
// periapsis will be, we ensure the final orbit has the desired AoP.
//
// Parameters:
//   targetPeriod — desired orbital period in seconds
//   targetAoP    — desired argument of periapsis in degrees
//   targetEcc    — desired eccentricity (optional, -1 to derive from period + Pe)
GLOBAL FUNCTION planMolniyaInsert {
    PARAMETER targetPeriod.
    PARAMETER targetAoP.
    PARAMETER targetEcc IS -1.

    LOCAL mp IS molniyaParams(targetPeriod, targetEcc).
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL targetSMA IS mp["SMA"].
    LOCAL targetPeR IS mp["PeR"].
    LOCAL targetApR IS mp["ApR"].

    mLog("Molniya target: pe=" + ROUND(mp["peAlt"]/1000,0) + "km  ap="
        + ROUND(mp["apAlt"]/1000,0) + "km  ecc=" + ROUND(mp["ecc"],4)
        + "  period=" + ROUND(mp["period"],0) + "s").

    // Compute the true anomaly where we need to burn.
    // The burn point is where periapsis will be in the final orbit — this is
    // at a true anomaly offset from the current periapsis by the difference
    // between the desired AoP and the current AoP.
    // (True anomaly is measured from periapsis, AoP is periapsis location
    // measured from the ascending node.)
    LOCAL burnTrueAnomaly IS targetAoP - SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    UNTIL burnTrueAnomaly >= 0  { SET burnTrueAnomaly TO burnTrueAnomaly + 360. }
    UNTIL burnTrueAnomaly < 360 { SET burnTrueAnomaly TO burnTrueAnomaly - 360. }

    // Find the time until the ship reaches the burn point
    LOCAL burnETA IS etaToTrueAnomaly(burnTrueAnomaly).
    LOCAL burnUT IS TIME:SECONDS + burnETA.

    // Get the orbital radius at the burn point (distance from body center)
    LOCAL burnRadius IS (POSITIONAT(SHIP, burnUT) - SHIP:BODY:POSITION):MAG.

    mLog("burnR=" + ROUND(burnRadius/1000,1) + "km  targetPeR="
        + ROUND(targetPeR/1000,1) + "km  ETA=" + ROUND(burnETA,0) + "s").

    // --- BURN 1: Raise apoapsis to target ---
    // We're at burnRadius; we want an intermediate orbit that reaches targetApR.
    // The intermediate orbit has SMA = (burnRadius + targetApR) / 2.
    // Using the vis-viva equation: v = √(μ(2/r - 1/a))
    LOCAL intermediarySMA IS (burnRadius + targetApR) / 2.
    LOCAL velocityNeeded1 IS SQRT(mu * (2/burnRadius - 1/intermediarySMA)).
    LOCAL velocityCurrent1 IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL deltaV1 IS velocityNeeded1 - velocityCurrent1.
    LOCAL node1 IS NODE(burnUT, 0, 0, deltaV1).
    ADD node1.

    // --- BURN 2: Adjust period at apoapsis ---
    // Coast to apoapsis of the intermediate orbit (half a period later).
    // At apoapsis (targetApR), burn to achieve the final Molniya SMA.
    LOCAL intermediaryPeriod IS 2 * CONSTANT:PI * SQRT(intermediarySMA^3 / mu).
    LOCAL burnUT2 IS burnUT + intermediaryPeriod / 2.
    LOCAL velocityCurrent2 IS SQRT(mu * (2/targetApR - 1/intermediarySMA)).
    LOCAL velocityNeeded2 IS SQRT(mu * (2/targetApR - 1/targetSMA)).
    LOCAL deltaV2 IS velocityNeeded2 - velocityCurrent2.
    LOCAL node2 IS NODE(burnUT2, 0, 0, deltaV2).
    ADD node2.

    mLog("Molniya 2-burn: dV1=" + ROUND(deltaV1,1) + "m/s  dV2=" + ROUND(deltaV2,1)
        + "m/s  coast=" + ROUND(intermediaryPeriod/2,0) + "s").
    RETURN LIST(node1, node2).
}

// phaseMolniyaInsert — phase machine entry point for Molniya orbit insertion.
//
// Reads configuration from the global CFG lexicon, plans the two-burn
// insertion, executes both burns, and advances to the next phase.
// Retries up to 5 times if a burn window is missed (e.g., due to
// misalignment or staging delays).
GLOBAL FUNCTION phaseMolniyaInsert {
    LOCAL targetPeriod IS CFG["MOLNIYA_PERIOD"].
    LOCAL targetAoP IS CFG["MOLNIYA_AOP"].
    LOCAL targetEcc IS -1.
    IF CFG:HASKEY("MOLNIYA_ECC") AND CFG["MOLNIYA_ECC"] > 0 {
        SET targetEcc TO CFG["MOLNIYA_ECC"].
        mLog("Molniya mode: period=" + targetPeriod + "s  ecc=" + targetEcc).
    }
    orbitSummary().

    // Retry loop — if a burn is missed (executeManeuver returns FALSE),
    // clear all nodes and replan from scratch. This handles cases where
    // the ship couldn't align in time or staging interrupted the burn.
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planMolniyaInsert(targetPeriod, targetAoP, targetEcc).
        LOCAL allOk IS TRUE.
        UNTIL NOT HASNODE OR NOT allOk {
            IF NOT executeManeuver() { SET allOk TO FALSE. }
        }
        SET success TO allOk.
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Molniya burn missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= 5 {
                mLogError("Molniya insert failed after " + retries + " attempts.").
                RETURN.
            }
            WAIT 10.
        }
    }

    // Log the achieved orbit for comparison against targets
    mLog("Molniya result: ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)
        + "  AoP=" + ROUND(SHIP:ORBIT:ARGUMENTOFPERIAPSIS,1)
        + "  period=" + ROUND(SHIP:ORBIT:PERIOD,0)
        + "s  inc=" + ROUND(SHIP:ORBIT:INCLINATION,2) + "deg").
    orbitSummary().
    nextPhase(xferSeq).
}
