// ============================================================
// orbit.ks  —  Orbit monitoring helpers  (0:/lib/orbit.ks)
//
// Utility functions for checking orbital parameters and waiting
// for sphere-of-influence (SOI) transitions. Used by phase
// machines to gate progression (e.g., "don't circularize until
// the orbit is stable").
// ============================================================

// isOrbitCircular — check if the current orbit is nearly circular.
//
// Eccentricity measures how elongated an orbit is:
//   e = 0    → perfect circle
//   0 < e < 1 → ellipse
//   e = 1    → parabolic escape
//   e > 1    → hyperbolic escape
//
// The default threshold of 0.01 means "within 1% of circular",
// which is typical for a parking orbit after circularization.
GLOBAL FUNCTION isOrbitCircular {
    PARAMETER threshold IS 0.01.
    RETURN SHIP:ORBIT:ECCENTRICITY < threshold.
}

// isOrbitStable — check if the orbit is safe from atmospheric drag and decay.
//
// An orbit is considered stable when:
//   1. Periapsis is above the minimum safe altitude (default 70km for Kerbin,
//      which is just above the atmosphere at 69.1km)
//   2. Apoapsis is positive (negative apoapsis means escape trajectory)
//   3. Eccentricity is below 0.05 (reasonably circular — a highly eccentric
//      orbit with low Pe could dip into atmosphere at periapsis)
//
// Note: the minAlt default of 70000m is Kerbin-specific. For other bodies,
// pass the appropriate atmosphere height + margin.
GLOBAL FUNCTION isOrbitStable {
    PARAMETER minAlt IS 70000.
    RETURN SHIP:PERIAPSIS > minAlt AND SHIP:APOAPSIS > 0 AND SHIP:ORBIT:ECCENTRICITY < 0.05.
}

// waitForSOI — block until the ship enters the target body's sphere of influence.
//
// KSP uses a patched-conic approximation for orbital mechanics. Each body has
// a sphere of influence (SOI) — when your trajectory crosses from one body's
// SOI into another, kOS reports a different SHIP:ORBIT:BODY. This function
// polls until that transition happens.
//
// The pollInterval controls how often we check (default 5s). A shorter interval
// catches the transition faster but wastes more CPU. For most transfers this
// doesn't matter since the transition is instantaneous from the game's perspective.
GLOBAL FUNCTION waitForSOI {
    trySolarOrient().
    PARAMETER targetBody.
    PARAMETER pollInterval IS 5.
    mLog("Waiting for SOI: " + targetBody:NAME).

    // Set a KAC alarm at the SOI transition so time warp stops automatically.
    // NEXTPATCHETA gives seconds until the next SOI boundary crossing.
    LOCAL kacAlarmId IS "".
    IF ADDONS:KAC:AVAILABLE AND SHIP:ORBIT:HASNEXTPATCH {
        LOCAL soiUt IS TIME:SECONDS + SHIP:ORBIT:NEXTPATCHETA.
        LOCAL oldTarget IS stateGet("soi_alarm_target", "").
        LOCAL oldUt IS stateGetNum("soi_alarm_ut", 0).
        LOCAL oldId IS stateGet("soi_alarm_id", "").

        IF oldTarget = targetBody:NAME AND oldId <> "" {
            SET kacAlarmId TO oldId.
            mLog("KAC SOI alarm already set for " + targetBody:NAME
                + " in " + ROUND(soiUt - TIME:SECONDS, 0) + "s.").
        } ELSE {
            IF oldId <> "" { DELETEALARM(oldId). }
            LOCAL alm IS ADDALARM("Raw", soiUt, "SOI: " + targetBody:NAME, "Auto-created by waitForSOI").
            SET alm:ACTION TO warpKillAction().
            SET kacAlarmId TO alm:ID.
            stateSet("soi_alarm_id", kacAlarmId).
            stateSet("soi_alarm_target", targetBody:NAME).
            stateSetNum("soi_alarm_ut", soiUt).
            mLog("KAC alarm set for SOI transition in " + ROUND(SHIP:ORBIT:NEXTPATCHETA, 0) + "s.").
        }
    }

    UNTIL SHIP:ORBIT:BODY:NAME = targetBody:NAME {
        WAIT pollInterval.
    }
    mLog("SOI entered: " + targetBody:NAME).

    // Clean up the alarm now that we've arrived.
    IF kacAlarmId <> "" {
        DELETEALARM(kacAlarmId).
    }
    FOR key IN LIST("soi_alarm_id", "soi_alarm_target", "soi_alarm_ut") {
        stateRemove(key).
    }
}

// orbitSummary — log the current orbital parameters.
//
// Logs periapsis (km), apoapsis (km), eccentricity, inclination (degrees),
// and the parent body name. Called at phase transitions and after maneuvers
// so the flight log has a record of the orbit at each stage.
GLOBAL FUNCTION orbitSummary {
    mLog("Orbit: Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km  Ap=" + ROUND(SHIP:APOAPSIS/1000,1)
        + "km  ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)
        + "  inc=" + ROUND(SHIP:ORBIT:INCLINATION,2) + "deg"
        + "  body=" + SHIP:ORBIT:BODY:NAME).
}
